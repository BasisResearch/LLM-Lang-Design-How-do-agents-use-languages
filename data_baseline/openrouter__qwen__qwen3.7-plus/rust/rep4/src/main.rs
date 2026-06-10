use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode, header::SET_COOKIE},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Router,
};
use clap::Parser;
use chrono::Utc;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use uuid::Uuid;

#[derive(Parser)]
struct Cli {
    #[clap(long)]
    port: u16,
}

#[derive(Clone, Debug)]
struct User {
    id: i32,
    username: String,
    password: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Todo {
    id: i32,
    #[serde(skip)]
    user_id: i32,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone)]
struct AppState {
    users: Arc<RwLock<HashMap<String, User>>>,
    todos: Arc<RwLock<HashMap<i32, Todo>>>,
    sessions: Arc<RwLock<HashMap<String, i32>>>,
    next_user_id: Arc<RwLock<i32>>,
    next_todo_id: Arc<RwLock<i32>>,
}

impl AppState {
    fn new() -> Self {
        Self {
            users: Arc::new(RwLock::new(HashMap::new())),
            todos: Arc::new(RwLock::new(HashMap::new())),
            sessions: Arc::new(RwLock::new(HashMap::new())),
            next_user_id: Arc::new(RwLock::new(1)),
            next_todo_id: Arc::new(RwLock::new(1)),
        }
    }
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: Option<String>,
    password: Option<String>,
}

#[derive(Deserialize)]
struct LoginRequest {
    username: Option<String>,
    password: Option<String>,
}

#[derive(Deserialize)]
struct PasswordRequest {
    old_password: Option<String>,
    new_password: Option<String>,
}

#[derive(Deserialize)]
struct CreateTodoRequest {
    title: Option<String>,
    description: Option<String>,
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

fn get_timestamp() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn json_error(status: StatusCode, message: &str) -> Response {
    (status, axum::Json(serde_json::json!({"error": message}))).into_response()
}

fn get_session_id(headers: &HeaderMap) -> Option<String> {
    let cookie_header = headers.get(axum::http::header::COOKIE)?.to_str().ok()?;
    for cookie in cookie_header.split(';') {
        let cookie = cookie.trim();
        if let Some((name, value)) = cookie.split_once('=') {
            if name == "session_id" {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn require_auth(headers: &HeaderMap, state: &AppState) -> Result<i32, Response> {
    if let Some(sid) = get_session_id(headers) {
        let sessions = state.sessions.read().unwrap();
        if let Some(&user_id) = sessions.get(&sid) {
            return Ok(user_id);
        }
    }
    Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required"))
}

async fn register(
    State(state): State<Arc<AppState>>,
    axum::Json(req): axum::Json<RegisterRequest>,
) -> impl IntoResponse {
    let username = req.username.unwrap_or_default();
    let password = req.password.unwrap_or_default();

    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    if username.len() < 3 || username.len() > 50 || !re.is_match(&username) {
        return json_error(StatusCode::BAD_REQUEST, "Invalid username");
    }

    if password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut users = state.users.write().unwrap();
    if users.contains_key(&username) {
        return json_error(StatusCode::CONFLICT, "Username already exists");
    }

    let user_id = {
        let mut next_id = state.next_user_id.write().unwrap();
        let id = *next_id;
        *next_id += 1;
        id
    };

    let user = User {
        id: user_id,
        username: username.clone(),
        password: password.clone(),
    };
    users.insert(username.clone(), user);

    (
        StatusCode::CREATED,
        axum::Json(serde_json::json!({
            "id": user_id,
            "username": username
        })),
    )
        .into_response()
}

async fn login(
    State(state): State<Arc<AppState>>,
    axum::Json(req): axum::Json<LoginRequest>,
) -> impl IntoResponse {
    let username = req.username.unwrap_or_default();
    let password = req.password.unwrap_or_default();

    let users = state.users.read().unwrap();
    let user = users.get(&username);

    if let Some(u) = user {
        if u.password == password {
            let session_token = Uuid::new_v4().to_string();
            state.sessions.write().unwrap().insert(session_token.clone(), u.id);

            let cookie_header = format!("session_id={}; Path=/; HttpOnly", session_token);
            return (
                [(SET_COOKIE, cookie_header)],
                axum::Json(serde_json::json!({
                    "id": u.id,
                    "username": u.username.clone()
                })),
            )
                .into_response();
        }
    }

    json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")
}

async fn logout(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if let Ok(_user_id) = require_auth(&headers, &state) {
        if let Some(sid) = get_session_id(&headers) {
            state.sessions.write().unwrap().remove(&sid);
        }
        let cookie_header = "session_id=; Path=/; HttpOnly; Max-Age=0".to_string();
        return (
            [(SET_COOKIE, cookie_header)],
            axum::Json(serde_json::json!({})),
        )
            .into_response();
    }
    json_error(StatusCode::UNAUTHORIZED, "Authentication required")
}

async fn get_me(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let user_id = match require_auth(&headers, &state) {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let users = state.users.read().unwrap();
    let user = users.values().find(|u| u.id == user_id).unwrap();

    axum::Json(serde_json::json!({
        "id": user.id,
        "username": user.username.clone()
    }))
    .into_response()
}

async fn update_password(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    axum::Json(req): axum::Json<PasswordRequest>,
) -> impl IntoResponse {
    let user_id = match require_auth(&headers, &state) {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let old_password = req.old_password.unwrap_or_default();
    let new_password = req.new_password.unwrap_or_default();

    if new_password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut users = state.users.write().unwrap();
    if let Some(user) = users.values_mut().find(|u| u.id == user_id) {
        if user.password != old_password {
            return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
        }
        user.password = new_password;
        return axum::Json(serde_json::json!({})).into_response();
    }

    json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")
}

async fn get_todos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let user_id = match require_auth(&headers, &state) {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let todos = state.todos.read().unwrap();
    let mut user_todos: Vec<_> = todos
        .values()
        .filter(|t| t.user_id == user_id)
        .cloned()
        .collect();

    user_todos.sort_by_key(|t| t.id);

    axum::Json(user_todos).into_response()
}

async fn create_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    axum::Json(req): axum::Json<CreateTodoRequest>,
) -> impl IntoResponse {
    let user_id = match require_auth(&headers, &state) {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let title = req.title.unwrap_or_default();
    if title.is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "Title is required");
    }

    let description = req.description.unwrap_or_default();

    let todo_id = {
        let mut next_id = state.next_todo_id.write().unwrap();
        let id = *next_id;
        *next_id += 1;
        id
    };

    let now = get_timestamp();
    let todo = Todo {
        id: todo_id,
        user_id,
        title,
        description,
        completed: false,
        created_at: now.clone(),
        updated_at: now,
    };

    state.todos.write().unwrap().insert(todo_id, todo.clone());

    (StatusCode::CREATED, axum::Json(todo)).into_response()
}

async fn get_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<i32>,
) -> impl IntoResponse {
    let user_id = match require_auth(&headers, &state) {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let todos = state.todos.read().unwrap();
    if let Some(todo) = todos.get(&id) {
        if todo.user_id == user_id {
            return axum::Json(todo.clone()).into_response();
        }
    }

    json_error(StatusCode::NOT_FOUND, "Todo not found")
}

async fn update_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<i32>,
    axum::Json(req): axum::Json<UpdateTodoRequest>,
) -> impl IntoResponse {
    let user_id = match require_auth(&headers, &state) {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let mut todos = state.todos.write().unwrap();
    if let Some(todo) = todos.get_mut(&id) {
        if todo.user_id != user_id {
            return json_error(StatusCode::NOT_FOUND, "Todo not found");
        }

        if let Some(title) = &req.title {
            if title.is_empty() {
                return json_error(StatusCode::BAD_REQUEST, "Title is required");
            }
            todo.title = title.clone();
        }
        if let Some(description) = &req.description {
            todo.description = description.clone();
        }
        if let Some(completed) = req.completed {
            todo.completed = completed;
        }
        todo.updated_at = get_timestamp();

        return axum::Json(todo.clone()).into_response();
    }

    json_error(StatusCode::NOT_FOUND, "Todo not found")
}

async fn delete_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<i32>,
) -> impl IntoResponse {
    let user_id = match require_auth(&headers, &state) {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let mut todos = state.todos.write().unwrap();
    if let Some(todo) = todos.get(&id) {
        if todo.user_id == user_id {
            todos.remove(&id);
            return StatusCode::NO_CONTENT.into_response();
        }
    }

    json_error(StatusCode::NOT_FOUND, "Todo not found")
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let state = Arc::new(AppState::new());

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(get_me))
        .route("/password", put(update_password))
        .route("/todos", get(get_todos))
        .route("/todos", post(create_todo))
        .route("/todos/:id", get(get_todo))
        .route("/todos/:id", put(update_todo))
        .route("/todos/:id", delete(delete_todo))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", cli.port);
    println!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}