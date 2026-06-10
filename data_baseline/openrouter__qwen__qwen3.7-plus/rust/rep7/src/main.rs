use axum::{
    extract::{Json, Path, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{delete, get, post, put},
    Router,
};
use bcrypt::{hash, verify, DEFAULT_COST};
use chrono::Utc;
use clap::Parser;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

#[derive(Parser)]
#[command(name = "todo_app")]
#[command(about = "A REST API server for managing personal todo items")]
struct Cli {
    #[arg(long, default_value_t = 8080)]
    port: u16,
}

#[derive(Clone)]
struct AppState {
    users: Arc<Mutex<HashMap<u64, User>>>,
    todos: Arc<Mutex<HashMap<u64, Todo>>>,
    sessions: Arc<Mutex<HashMap<String, u64>>>,
    username_to_id: Arc<Mutex<HashMap<String, u64>>>,
    next_user_id: Arc<Mutex<u64>>,
    next_todo_id: Arc<Mutex<u64>>,
}

#[derive(Clone, Serialize, Deserialize)]
struct User {
    id: u64,
    username: String,
    password_hash: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Todo {
    id: u64,
    user_id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

impl AppState {
    fn new() -> Self {
        Self {
            users: Arc::new(Mutex::new(HashMap::new())),
            todos: Arc::new(Mutex::new(HashMap::new())),
            sessions: Arc::new(Mutex::new(HashMap::new())),
            username_to_id: Arc::new(Mutex::new(HashMap::new())),
            next_user_id: Arc::new(Mutex::new(1)),
            next_todo_id: Arc::new(Mutex::new(1)),
        }
    }
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

fn is_valid_username(username: &str) -> bool {
    if username.len() < 3 || username.len() > 50 {
        return false;
    }
    username.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

type AppResult<T> = Result<T, (StatusCode, Json<serde_json::Value>)>;

#[derive(Deserialize)]
struct RegisterRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn register(
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> AppResult<impl IntoResponse> {
    let username = req.username.ok_or_else(|| (StatusCode::BAD_REQUEST, Json(json!({"error": "Invalid username"}))))?;
    let password = req.password.ok_or_else(|| (StatusCode::BAD_REQUEST, Json(json!({"error": "Password too short"}))))?;

    if !is_valid_username(&username) {
        return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Invalid username"}))));
    }
    if password.len() < 8 {
        return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Password too short"}))));
    }

    let mut username_to_id = state.username_to_id.lock().unwrap();
    if username_to_id.contains_key(&username) {
        return Err((StatusCode::CONFLICT, Json(json!({"error": "Username already exists"}))));
    }

    let mut users = state.users.lock().unwrap();
    let mut next_user_id = state.next_user_id.lock().unwrap();
    
    let id = *next_user_id;
    *next_user_id += 1;
    
    let password_hash = hash(&password, DEFAULT_COST)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Internal server error"}))))?;

    let user = User {
        id,
        username: username.clone(),
        password_hash,
    };

    users.insert(id, user);
    username_to_id.insert(username.clone(), id);

    Ok((StatusCode::CREATED, Json(json!({"id": id, "username": username}))))
}

#[derive(Deserialize)]
struct LoginRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
) -> AppResult<(StatusCode, HeaderMap, Json<serde_json::Value>)> {
    let username = req.username.unwrap_or_default();
    let password = req.password.unwrap_or_default();

    let username_to_id = state.username_to_id.lock().unwrap();
    let user_id = *username_to_id.get(&username).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))))?;
    
    let users = state.users.lock().unwrap();
    let user = users.get(&user_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))))?;

    let valid = verify(&password, &user.password_hash)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Internal server error"}))))?;
    
    if !valid {
        return Err((StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))));
    }

    let session_id = Uuid::new_v4().to_string();
    let mut sessions = state.sessions.lock().unwrap();
    sessions.insert(session_id.clone(), user_id);

    let cookie = format!("session_id={}; Path=/; HttpOnly", session_id);
    let mut headers = HeaderMap::new();
    headers.insert(
        axum::http::header::SET_COOKIE,
        axum::http::HeaderValue::from_str(&cookie).unwrap(),
    );

    Ok((StatusCode::OK, headers, Json(json!({"id": user.id, "username": user.username}))))
}

async fn logout(
    headers: HeaderMap,
    State(state): State<AppState>,
) -> AppResult<impl IntoResponse> {
    let session_id = get_session_id(&headers).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let mut sessions = state.sessions.lock().unwrap();
    sessions.remove(&session_id);

    Ok((StatusCode::OK, Json(json!({}))))
}

async fn get_me(
    headers: HeaderMap,
    State(state): State<AppState>,
) -> AppResult<impl IntoResponse> {
    let session_id = get_session_id(&headers).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let sessions = state.sessions.lock().unwrap();
    let user_id = *sessions.get(&session_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let users = state.users.lock().unwrap();
    let user = users.get(&user_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;

    Ok((StatusCode::OK, Json(json!({"id": user.id, "username": user.username}))))
}

#[derive(Deserialize)]
struct UpdatePasswordRequest {
    old_password: Option<String>,
    new_password: Option<String>,
}

async fn update_password(
    headers: HeaderMap,
    State(state): State<AppState>,
    Json(req): Json<UpdatePasswordRequest>,
) -> AppResult<impl IntoResponse> {
    let session_id = get_session_id(&headers).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let sessions = state.sessions.lock().unwrap();
    let user_id = *sessions.get(&session_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;

    let old_password = req.old_password.unwrap_or_default();
    let new_password = req.new_password.unwrap_or_default();

    if new_password.len() < 8 {
        return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Password too short"}))));
    }

    let mut users = state.users.lock().unwrap();
    let user = users.get_mut(&user_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))))?;

    let valid = verify(&old_password, &user.password_hash)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Internal server error"}))))?;
    
    if !valid {
        return Err((StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))));
    }

    let new_hash = hash(&new_password, DEFAULT_COST)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Internal server error"}))))?;
    
    user.password_hash = new_hash;

    Ok((StatusCode::OK, Json(json!({}))))
}

async fn get_todos(
    headers: HeaderMap,
    State(state): State<AppState>,
) -> AppResult<impl IntoResponse> {
    let session_id = get_session_id(&headers).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let sessions = state.sessions.lock().unwrap();
    let user_id = *sessions.get(&session_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let todos = state.todos.lock().unwrap();
    let mut user_todos: Vec<_> = todos.values()
        .filter(|t| t.user_id == user_id)
        .cloned()
        .collect();
    
    user_todos.sort_by_key(|t| t.id);
    
    let response_todos: Vec<serde_json::Value> = user_todos.into_iter().map(|t| json!({
        "id": t.id,
        "title": t.title,
        "description": t.description,
        "completed": t.completed,
        "created_at": t.created_at,
        "updated_at": t.updated_at,
    })).collect();
    
    Ok((StatusCode::OK, Json(serde_json::Value::Array(response_todos))))
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
) -> AppResult<impl IntoResponse> {
    let session_id = get_session_id(&headers).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let sessions = state.sessions.lock().unwrap();
    let user_id = *sessions.get(&session_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;

    let title = req.title.ok_or_else(|| (StatusCode::BAD_REQUEST, Json(json!({"error": "Title is required"}))))?;
    if title.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Title is required"}))));
    }
    
    let description = req.description.unwrap_or_default();

    let mut todos = state.todos.lock().unwrap();
    let mut next_todo_id = state.next_todo_id.lock().unwrap();
    
    let id = *next_todo_id;
    *next_todo_id += 1;
    
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    
    let todo = Todo {
        id,
        user_id,
        title: title.clone(),
        description: description.clone(),
        completed: false,
        created_at: now.clone(),
        updated_at: now.clone(),
    };
    
    todos.insert(id, todo.clone());
    
    Ok((StatusCode::CREATED, Json(json!({
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at,
    }))))
}

async fn get_todo(
    headers: HeaderMap,
    Path(todo_id): Path<u64>,
    State(state): State<AppState>,
) -> AppResult<impl IntoResponse> {
    let session_id = get_session_id(&headers).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let sessions = state.sessions.lock().unwrap();
    let user_id = *sessions.get(&session_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;

    let todos = state.todos.lock().unwrap();
    let todo = todos.get(&todo_id).ok_or_else(|| (StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))))?;
    
    if todo.user_id != user_id {
        return Err((StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))));
    }
    
    Ok((StatusCode::OK, Json(json!({
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at,
    }))))
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

async fn update_todo(
    headers: HeaderMap,
    Path(todo_id): Path<u64>,
    State(state): State<AppState>,
    Json(req): Json<UpdateTodoRequest>,
) -> AppResult<impl IntoResponse> {
    let session_id = get_session_id(&headers).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let sessions = state.sessions.lock().unwrap();
    let user_id = *sessions.get(&session_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;

    let mut todos = state.todos.lock().unwrap();
    let todo = todos.get_mut(&todo_id).ok_or_else(|| (StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))))?;
    
    if todo.user_id != user_id {
        return Err((StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))));
    }

    if let Some(ref title) = req.title {
        if title.trim().is_empty() {
            return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Title is required"}))));
        }
        todo.title = title.clone();
    }
    
    if let Some(ref description) = req.description {
        todo.description = description.clone();
    }
    
    if let Some(completed) = req.completed {
        todo.completed = completed;
    }
    
    todo.updated_at = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    
    Ok((StatusCode::OK, Json(json!({
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at,
    }))))
}

async fn delete_todo(
    headers: HeaderMap,
    Path(todo_id): Path<u64>,
    State(state): State<AppState>,
) -> AppResult<impl IntoResponse> {
    let session_id = get_session_id(&headers).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;
    
    let sessions = state.sessions.lock().unwrap();
    let user_id = *sessions.get(&session_id).ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))))?;

    let mut todos = state.todos.lock().unwrap();
    let todo = todos.get(&todo_id).ok_or_else(|| (StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))))?;
    
    if todo.user_id != user_id {
        return Err((StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))));
    }

    todos.remove(&todo_id);
    
    Ok(StatusCode::NO_CONTENT)
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let state = AppState::new();
    
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
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    println!("Listening on {}", addr);
    axum::serve(listener, app).await.unwrap();
}