use axum::{
    extract::{Path, State},
    http::{header::SET_COOKIE, HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::Utc;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, RwLock};
use uuid::Uuid;

#[derive(Clone, Serialize, Deserialize)]
struct User {
    id: u32,
    username: String,
    #[serde(skip)]
    password: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Todo {
    id: u32,
    #[serde(skip)]
    user_id: u32,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone)]
struct AppState {
    users: Arc<RwLock<HashMap<u32, User>>>,
    next_user_id: Arc<Mutex<u32>>,
    todos: Arc<RwLock<HashMap<u32, Todo>>>,
    next_todo_id: Arc<Mutex<u32>>,
    sessions: Arc<RwLock<HashMap<String, u32>>>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            users: Arc::new(RwLock::new(HashMap::new())),
            next_user_id: Arc::new(Mutex::new(1)),
            todos: Arc::new(RwLock::new(HashMap::new())),
            next_todo_id: Arc::new(Mutex::new(1)),
            sessions: Arc::new(RwLock::new(HashMap::new())),
        }
    }
}

fn get_session_id(headers: &HeaderMap) -> Option<String> {
    let cookie_header = headers.get("cookie")?.to_str().ok()?;
    let cookies: HashMap<&str, &str> = cookie_header
        .split(';')
        .filter_map(|c| {
            let mut parts = c.splitn(2, '=');
            Some((parts.next()?.trim(), parts.next()?.trim()))
        })
        .collect();
    cookies.get("session_id").map(|s| s.to_string())
}

fn get_session_user_id(headers: &HeaderMap, state: &AppState) -> Option<u32> {
    let sid = get_session_id(headers)?;
    state.sessions.read().unwrap().get(&sid).copied()
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn register(
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> impl IntoResponse {
    let username = match &req.username {
        Some(u) => u,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "Invalid username"})),
            )
        }
    };
    let password = match &req.password {
        Some(p) => p,
        None => {
            return (
                StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "Password too short"})),
            )
        }
    };

    if username.len() < 3 || username.len() > 50 {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "Invalid username"})),
        );
    }
    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    if !re.is_match(username) {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "Invalid username"})),
        );
    }
    if password.len() < 8 {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "Password too short"})),
        );
    }

    let mut users = state.users.write().unwrap();
    let exists = users.values().any(|u| u.username == *username);
    if exists {
        return (
            StatusCode::CONFLICT,
            Json(serde_json::json!({"error": "Username already exists"})),
        );
    }

    let new_id = {
        let mut next_id = state.next_user_id.lock().unwrap();
        let id = *next_id;
        *next_id += 1;
        id
    };

    let user = User {
        id: new_id,
        username: username.clone(),
        password: password.clone(),
    };
    users.insert(new_id, user.clone());

    (
        StatusCode::CREATED,
        Json(serde_json::json!({"id": new_id, "username": username})),
    )
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
) -> impl IntoResponse {
    let users = state.users.read().unwrap();
    let user = users
        .values()
        .find(|u| u.username == req.username && u.password == req.password);

    match user {
        Some(u) => {
            let session_id = Uuid::new_v4().to_string();
            state.sessions.write().unwrap().insert(session_id.clone(), u.id);

            let mut headers = HeaderMap::new();
            headers.insert(
                SET_COOKIE,
                format!("session_id={}; Path=/; HttpOnly", session_id)
                    .parse()
                    .unwrap(),
            );

            let body: Value = serde_json::json!({"id": u.id, "username": u.username});
            (StatusCode::OK, headers, Json(body)).into_response()
        }
        None => {
            let body: Value = serde_json::json!({"error": "Invalid credentials"});
            (StatusCode::UNAUTHORIZED, HeaderMap::new(), Json(body)).into_response()
        }
    }
}

async fn logout(
    headers: HeaderMap,
    State(state): State<AppState>,
) -> impl IntoResponse {
    if let Some(_user_id) = get_session_user_id(&headers, &state) {
        if let Some(sid) = get_session_id(&headers) {
            state.sessions.write().unwrap().remove(&sid);
        }
        let body: Value = serde_json::json!({});
        (StatusCode::OK, Json(body)).into_response()
    } else {
        let body: Value = serde_json::json!({"error": "Authentication required"});
        (StatusCode::UNAUTHORIZED, Json(body)).into_response()
    }
}

async fn me(
    headers: HeaderMap,
    State(state): State<AppState>,
) -> impl IntoResponse {
    if let Some(user_id) = get_session_user_id(&headers, &state) {
        let users = state.users.read().unwrap();
        if let Some(u) = users.get(&user_id) {
            let body: Value = serde_json::json!({"id": u.id, "username": u.username});
            (StatusCode::OK, Json(body)).into_response()
        } else {
            let body: Value = serde_json::json!({"error": "Authentication required"});
            (StatusCode::UNAUTHORIZED, Json(body)).into_response()
        }
    } else {
        let body: Value = serde_json::json!({"error": "Authentication required"});
        (StatusCode::UNAUTHORIZED, Json(body)).into_response()
    }
}

#[derive(Deserialize)]
struct PasswordRequest {
    old_password: Option<String>,
    new_password: Option<String>,
}

async fn update_password(
    headers: HeaderMap,
    State(state): State<AppState>,
    Json(req): Json<PasswordRequest>,
) -> impl IntoResponse {
    let user_id = match get_session_user_id(&headers, &state) {
        Some(id) => id,
        None => {
            let body: Value = serde_json::json!({"error": "Authentication required"});
            return (StatusCode::UNAUTHORIZED, Json(body)).into_response();
        }
    };

    let old_password = req.old_password.unwrap_or_default();
    let new_password = req.new_password.unwrap_or_default();

    let mut users = state.users.write().unwrap();
    if let Some(u) = users.get_mut(&user_id) {
        if u.password != old_password {
            let body: Value = serde_json::json!({"error": "Invalid credentials"});
            return (StatusCode::UNAUTHORIZED, Json(body)).into_response();
        }
        if new_password.len() < 8 {
            let body: Value = serde_json::json!({"error": "Password too short"});
            return (StatusCode::BAD_REQUEST, Json(body)).into_response();
        }
        u.password = new_password;
        let body: Value = serde_json::json!({});
        (StatusCode::OK, Json(body)).into_response()
    } else {
        let body: Value = serde_json::json!({"error": "Authentication required"});
        (StatusCode::UNAUTHORIZED, Json(body)).into_response()
    }
}

async fn list_todos(
    headers: HeaderMap,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let user_id = match get_session_user_id(&headers, &state) {
        Some(id) => id,
        None => {
            let body: Value = serde_json::json!({"error": "Authentication required"});
            return (StatusCode::UNAUTHORIZED, Json(body)).into_response();
        }
    };

    let todos = state.todos.read().unwrap();
    let mut user_todos: Vec<_> = todos
        .values()
        .filter(|t| t.user_id == user_id)
        .cloned()
        .collect();

    user_todos.sort_by_key(|t| t.id);

    let body: Value = serde_json::to_value(user_todos).unwrap();
    (StatusCode::OK, Json(body)).into_response()
}

#[derive(Deserialize)]
struct CreateTodoRequest {
    title: Option<String>,
    description: Option<String>,
}

async fn create_todo(
    headers: HeaderMap,
    State(state): State<AppState>,
    Json(req): Json<CreateTodoRequest>,
) -> impl IntoResponse {
    let user_id = match get_session_user_id(&headers, &state) {
        Some(id) => id,
        None => {
            let body: Value = serde_json::json!({"error": "Authentication required"});
            return (StatusCode::UNAUTHORIZED, Json(body)).into_response();
        }
    };

    let title = match req.title {
        Some(t) if !t.is_empty() => t,
        _ => {
            let body: Value = serde_json::json!({"error": "Title is required"});
            return (StatusCode::BAD_REQUEST, Json(body)).into_response();
        }
    };

    let description = req.description.unwrap_or_default();
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let new_id = {
        let mut next_id = state.next_todo_id.lock().unwrap();
        let id = *next_id;
        *next_id += 1;
        id
    };

    let todo = Todo {
        id: new_id,
        user_id,
        title,
        description,
        completed: false,
        created_at: now.clone(),
        updated_at: now,
    };

    state.todos.write().unwrap().insert(new_id, todo.clone());

    let body: Value = serde_json::to_value(todo).unwrap();
    (StatusCode::CREATED, Json(body)).into_response()
}

async fn get_todo(
    headers: HeaderMap,
    State(state): State<AppState>,
    Path(todo_id): Path<u32>,
) -> impl IntoResponse {
    let user_id = match get_session_user_id(&headers, &state) {
        Some(id) => id,
        None => {
            let body: Value = serde_json::json!({"error": "Authentication required"});
            return (StatusCode::UNAUTHORIZED, Json(body)).into_response();
        }
    };

    let todos = state.todos.read().unwrap();
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id == user_id {
            let body: Value = serde_json::to_value(todo.clone()).unwrap();
            (StatusCode::OK, Json(body)).into_response()
        } else {
            let body: Value = serde_json::json!({"error": "Todo not found"});
            (StatusCode::NOT_FOUND, Json(body)).into_response()
        }
    } else {
        let body: Value = serde_json::json!({"error": "Todo not found"});
        (StatusCode::NOT_FOUND, Json(body)).into_response()
    }
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

async fn update_todo(
    headers: HeaderMap,
    State(state): State<AppState>,
    Path(todo_id): Path<u32>,
    Json(req): Json<UpdateTodoRequest>,
) -> impl IntoResponse {
    let user_id = match get_session_user_id(&headers, &state) {
        Some(id) => id,
        None => {
            let body: Value = serde_json::json!({"error": "Authentication required"});
            return (StatusCode::UNAUTHORIZED, Json(body)).into_response();
        }
    };

    let mut todos = state.todos.write().unwrap();
    if let Some(todo) = todos.get_mut(&todo_id) {
        if todo.user_id != user_id {
            let body: Value = serde_json::json!({"error": "Todo not found"});
            return (StatusCode::NOT_FOUND, Json(body)).into_response();
        }

        if let Some(title) = req.title {
            if title.is_empty() {
                let body: Value = serde_json::json!({"error": "Title is required"});
                return (StatusCode::BAD_REQUEST, Json(body)).into_response();
            }
            todo.title = title;
        }
        if let Some(desc) = req.description {
            todo.description = desc;
        }
        if let Some(completed) = req.completed {
            todo.completed = completed;
        }

        todo.updated_at = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

        let body: Value = serde_json::to_value(todo.clone()).unwrap();
        (StatusCode::OK, Json(body)).into_response()
    } else {
        let body: Value = serde_json::json!({"error": "Todo not found"});
        (StatusCode::NOT_FOUND, Json(body)).into_response()
    }
}

async fn delete_todo(
    headers: HeaderMap,
    State(state): State<AppState>,
    Path(todo_id): Path<u32>,
) -> impl IntoResponse {
    let user_id = match get_session_user_id(&headers, &state) {
        Some(id) => id,
        None => {
            let body: Value = serde_json::json!({"error": "Authentication required"});
            return (StatusCode::UNAUTHORIZED, Json(body)).into_response();
        }
    };

    let mut todos = state.todos.write().unwrap();
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id == user_id {
            todos.remove(&todo_id);
            (StatusCode::NO_CONTENT, ()).into_response()
        } else {
            let body: Value = serde_json::json!({"error": "Todo not found"});
            (StatusCode::NOT_FOUND, Json(body)).into_response()
        }
    } else {
        let body: Value = serde_json::json!({"error": "Todo not found"});
        (StatusCode::NOT_FOUND, Json(body)).into_response()
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut port = 3000;
    for i in 0..args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse().unwrap_or(3000);
        }
    }

    let state = AppState::default();

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(update_password))
        .route("/todos", get(list_todos))
        .route("/todos", post(create_todo))
        .route("/todos/:id", get(get_todo))
        .route("/todos/:id", put(update_todo))
        .route("/todos/:id", delete(delete_todo))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", port);
    println!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
