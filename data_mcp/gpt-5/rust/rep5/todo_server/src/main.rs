use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::{Timelike, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    env,
    net::SocketAddr,
    sync::Arc,
};
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Clone, Debug, Serialize)]
struct UserOut {
    id: i64,
    username: String,
}

#[derive(Clone, Debug)]
struct User {
    id: i64,
    username: String,
    password: String,
}

#[derive(Clone, Debug, Serialize)]
struct TodoOut {
    id: i64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone, Debug)]
struct TodoInternal {
    id: i64,
    user_id: i64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

impl From<&TodoInternal> for TodoOut {
    fn from(t: &TodoInternal) -> Self {
        Self {
            id: t.id,
            title: t.title.clone(),
            description: t.description.clone(),
            completed: t.completed,
            created_at: t.created_at.clone(),
            updated_at: t.updated_at.clone(),
        }
    }
}

#[derive(Default)]
struct Store {
    next_user_id: i64,
    next_todo_id: i64,
    users: HashMap<i64, User>,
    username_index: HashMap<String, i64>,
    sessions: HashMap<String, i64>, // token -> user_id
    todos: HashMap<i64, TodoInternal>,
}

#[derive(Clone, Default)]
struct AppState {
    store: Arc<RwLock<Store>>,
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct PasswordChangeRequest {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize, Default)]
struct CreateTodoRequest {
    title: String,
    #[serde(default)]
    description: String,
}

#[derive(Deserialize, Default)]
struct UpdateTodoRequest {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    completed: Option<bool>,
}

fn now_iso8601_utc_seconds() -> String {
    let now = Utc::now().with_nanosecond(0).unwrap();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn json_error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({"error": message})) ).into_response()
}

fn extract_session_id(headers: &HeaderMap) -> Option<String> {
    // There can be multiple Cookie headers; iterate all
    let cookies = headers.get_all(header::COOKIE);
    for val in cookies.iter() {
        if let Ok(s) = val.to_str() {
            for part in s.split(';') {
                let p = part.trim();
                if let Some(rest) = p.strip_prefix("session_id=") {
                    return Some(rest.to_string());
                }
            }
        }
    }
    None
}

async fn get_authenticated_user(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(i64, UserOut, String), Response> {
    let token = match extract_session_id(headers) {
        Some(t) => t,
        None => return Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required")),
    };
    let store = state.store.read().await;
    let user_id = match store.sessions.get(&token) {
        Some(uid) => *uid,
        None => return Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required")),
    };
    let user = store.users.get(&user_id).expect("User id in session must exist");
    Ok((user_id, UserOut { id: user.id, username: user.username.clone() }, token))
}

#[tokio::main]
async fn main() {
    // Parse --port PORT
    let mut args = env::args().skip(1);
    let mut port: u16 = 3000;
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(p) = args.next() {
                match p.parse::<u16>() {
                    Ok(num) => port = num,
                    Err(_) => {
                        eprintln!("Invalid port: {}", p);
                        std::process::exit(1);
                    }
                }
            } else {
                eprintln!("--port requires a value");
                std::process::exit(1);
            }
        }
    }

    let state = AppState { store: Arc::new(RwLock::new(Store::default())) };

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(state);

    let addr: SocketAddr = format!("0.0.0.0:{}", port).parse().unwrap();
    println!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn register(State(state): State<AppState>, Json(payload): Json<RegisterRequest>) -> Response {
    // Validate username and password
    let username = payload.username.trim();
    let password = payload.password;
    let username_re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !username_re.is_match(username) {
        return json_error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut store = state.store.write().await;
    if store.username_index.contains_key(username) {
        return json_error(StatusCode::CONFLICT, "Username already exists");
    }

    store.next_user_id += 1;
    let user = User {
        id: store.next_user_id,
        username: username.to_string(),
        password,
    };
    store.username_index.insert(user.username.clone(), user.id);
    store.users.insert(user.id, user.clone());

    let out = UserOut { id: user.id, username: user.username };
    (StatusCode::CREATED, Json(out)).into_response()
}

async fn login(State(state): State<AppState>, Json(payload): Json<LoginRequest>) -> Response {
    let username = payload.username;
    let password = payload.password;

    let mut headers = HeaderMap::new();
    let user_out = {
        let store = state.store.read().await;
        match store.username_index.get(&username).and_then(|id| store.users.get(id)) {
            Some(user) if user.password == password => UserOut { id: user.id, username: user.username.clone() },
            _ => return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials"),
        }
    };

    // Create session
    let token = Uuid::new_v4().to_string();
    {
        let mut store = state.store.write().await;
        store.sessions.insert(token.clone(), user_out.id);
    }

    // Set-Cookie header
    let cookie_val = format!("session_id={}; Path=/; HttpOnly", token);
    headers.insert(header::SET_COOKIE, cookie_val.parse().unwrap());

    (StatusCode::OK, headers, Json(user_out)).into_response()
}

async fn logout(State(state): State<AppState>, headers: HeaderMap) -> Response {
    // Auth required: retrieve session and invalidate
    let token = match extract_session_id(&headers) {
        Some(t) => t,
        None => return json_error(StatusCode::UNAUTHORIZED, "Authentication required"),
    };
    let mut store = state.store.write().await;
    if store.sessions.remove(&token).is_none() {
        return json_error(StatusCode::UNAUTHORIZED, "Authentication required");
    }
    (StatusCode::OK, Json(json!({}))).into_response()
}

async fn me(State(state): State<AppState>, headers: HeaderMap) -> Response {
    match get_authenticated_user(&state, &headers).await {
        Ok((_uid, user_out, _token)) => (StatusCode::OK, Json(user_out)).into_response(),
        Err(e) => e,
    }
}

async fn change_password(State(state): State<AppState>, headers: HeaderMap, Json(payload): Json<PasswordChangeRequest>) -> Response {
    let (user_id, _user_out, _token) = match get_authenticated_user(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };

    if payload.new_password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut store = state.store.write().await;
    let user = store.users.get_mut(&user_id).expect("user must exist");
    if user.password != payload.old_password {
        return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
    }
    user.password = payload.new_password;

    (StatusCode::OK, Json(json!({}))).into_response()
}

async fn list_todos(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let (user_id, _user_out, _token) = match get_authenticated_user(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };

    let store = state.store.read().await;
    let mut todos: Vec<TodoOut> = store
        .todos
        .values()
        .filter(|t| t.user_id == user_id)
        .map(|t| TodoOut::from(t))
        .collect();
    todos.sort_by_key(|t| t.id);
    (StatusCode::OK, Json(todos)).into_response()
}

async fn create_todo(State(state): State<AppState>, headers: HeaderMap, Json(payload): Json<CreateTodoRequest>) -> Response {
    let (user_id, _user_out, _token) = match get_authenticated_user(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };

    if payload.title.trim().is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "Title is required");
    }

    let now = now_iso8601_utc_seconds();
    let mut store = state.store.write().await;
    store.next_todo_id += 1;
    let todo = TodoInternal {
        id: store.next_todo_id,
        user_id,
        title: payload.title.trim().to_string(),
        description: payload.description.clone(),
        completed: false,
        created_at: now.clone(),
        updated_at: now.clone(),
    };
    store.todos.insert(todo.id, todo.clone());

    (StatusCode::CREATED, Json(TodoOut::from(&todo))).into_response()
}

async fn get_todo(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<i64>) -> Response {
    let (user_id, _user_out, _token) = match get_authenticated_user(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };

    let store = state.store.read().await;
    match store.todos.get(&id) {
        Some(todo) if todo.user_id == user_id => (StatusCode::OK, Json(TodoOut::from(todo))).into_response(),
        _ => json_error(StatusCode::NOT_FOUND, "Todo not found"),
    }
}

async fn update_todo(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<i64>, Json(payload): Json<UpdateTodoRequest>) -> Response {
    let (user_id, _user_out, _token) = match get_authenticated_user(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };

    if let Some(title) = &payload.title {
        if title.trim().is_empty() {
            return json_error(StatusCode::BAD_REQUEST, "Title is required");
        }
    }

    let mut store = state.store.write().await;
    match store.todos.get_mut(&id) {
        Some(todo) if todo.user_id == user_id => {
            if let Some(title) = payload.title { todo.title = title.trim().to_string(); }
            if let Some(desc) = payload.description { todo.description = desc; }
            if let Some(comp) = payload.completed { todo.completed = comp; }
            todo.updated_at = now_iso8601_utc_seconds();
            (StatusCode::OK, Json(TodoOut::from(&*todo))).into_response()
        }
        _ => json_error(StatusCode::NOT_FOUND, "Todo not found"),
    }
}

async fn delete_todo(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<i64>) -> Response {
    let (user_id, _user_out, _token) = match get_authenticated_user(&state, &headers).await {
        Ok(v) => v,
        Err(e) => return e,
    };

    let mut store = state.store.write().await;
    match store.todos.get(&id) {
        Some(todo) if todo.user_id == user_id => {
            store.todos.remove(&id);
            StatusCode::NO_CONTENT.into_response()
        }
        _ => json_error(StatusCode::NOT_FOUND, "Todo not found"),
    }
}
