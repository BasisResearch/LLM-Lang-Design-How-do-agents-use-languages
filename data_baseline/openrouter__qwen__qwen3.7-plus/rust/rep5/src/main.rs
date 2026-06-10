use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router,
};
use chrono::Utc;
use regex::Regex;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

#[derive(Clone)]
struct User {
    id: u64,
    username: String,
    password_hash: String,
}

#[derive(Clone)]
struct Todo {
    id: u64,
    user_id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone)]
struct AppState {
    users: Arc<Mutex<HashMap<u64, User>>>,
    user_id_counter: Arc<Mutex<u64>>,
    todos: Arc<Mutex<HashMap<u64, Todo>>>,
    todo_id_counter: Arc<Mutex<u64>>,
    sessions: Arc<Mutex<HashMap<String, u64>>>,
    username_to_id: Arc<Mutex<HashMap<String, u64>>>,
}

impl AppState {
    fn new() -> Self {
        Self {
            users: Arc::new(Mutex::new(HashMap::new())),
            user_id_counter: Arc::new(Mutex::new(0)),
            todos: Arc::new(Mutex::new(HashMap::new())),
            todo_id_counter: Arc::new(Mutex::new(0)),
            sessions: Arc::new(Mutex::new(HashMap::new())),
            username_to_id: Arc::new(Mutex::new(HashMap::new())),
        }
    }
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

#[derive(Serialize, Clone)]
struct UserResponse {
    id: u64,
    username: String,
}

#[derive(Serialize, Clone)]
struct TodoResponse {
    id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

impl From<Todo> for TodoResponse {
    fn from(todo: Todo) -> Self {
        Self {
            id: todo.id,
            title: todo.title,
            description: todo.description,
            completed: todo.completed,
            created_at: todo.created_at,
            updated_at: todo.updated_at,
        }
    }
}

#[derive(Debug)]
enum AppError {
    BadRequest(String),
    Unauthorized(String),
    Conflict(String),
    NotFound(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, error_message) = match self {
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            AppError::Unauthorized(msg) => (StatusCode::UNAUTHORIZED, msg),
            AppError::Conflict(msg) => (StatusCode::CONFLICT, msg),
            AppError::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
        };
        
        let body = Json(serde_json::json!({
            "error": error_message
        }));
        
        (status, body).into_response()
    }
}

struct Auth {
    user_id: u64,
    token: String,
}

fn get_auth(headers: &HeaderMap, state: &Arc<AppState>) -> Result<Auth, AppError> {
    let cookies = headers.get(header::COOKIE);
    let session_token = if let Some(cookie_header) = cookies {
        let cookie_str = cookie_header.to_str().unwrap_or("");
        cookie_str
            .split(';')
            .find_map(|c| {
                let c = c.trim();
                if c.starts_with("session_id=") {
                    Some(c["session_id=".len()..].to_string())
                } else {
                    None
                }
            })
    } else {
        None
    };
    
    if let Some(token) = session_token {
        let sessions = state.sessions.lock().unwrap();
        if let Some(&user_id) = sessions.get(&token) {
            return Ok(Auth { user_id, token });
        }
    }
    
    Err(AppError::Unauthorized("Authentication required".to_string()))
}

fn hash_password(password: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(password.as_bytes());
    format!("{:x}", hasher.finalize())
}

async fn register(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegisterRequest>,
) -> Result<(StatusCode, Json<UserResponse>), AppError> {
    let username_re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !username_re.is_match(&req.username) {
        return Err(AppError::BadRequest("Invalid username".to_string()));
    }
    
    if req.password.len() < 8 {
        return Err(AppError::BadRequest("Password too short".to_string()));
    }
    
    let mut username_to_id = state.username_to_id.lock().unwrap();
    if username_to_id.contains_key(&req.username) {
        return Err(AppError::Conflict("Username already exists".to_string()));
    }
    
    let mut users = state.users.lock().unwrap();
    let mut counter = state.user_id_counter.lock().unwrap();
    *counter += 1;
    let new_id = *counter;
    
    let new_user = User {
        id: new_id,
        username: req.username.clone(),
        password_hash: hash_password(&req.password),
    };
    users.insert(new_id, new_user.clone());
    username_to_id.insert(req.username.clone(), new_id);
    
    Ok((
        StatusCode::CREATED,
        Json(UserResponse {
            id: new_id,
            username: req.username,
        }),
    ))
}

async fn login(
    State(state): State<Arc<AppState>>,
    Json(req): Json<LoginRequest>,
) -> Result<(HeaderMap, Json<UserResponse>), AppError> {
    let username_to_id = state.username_to_id.lock().unwrap();
    let user_id = *username_to_id
        .get(&req.username)
        .ok_or_else(|| AppError::Unauthorized("Invalid credentials".to_string()))?;
    
    let users = state.users.lock().unwrap();
    let user = users
        .get(&user_id)
        .ok_or_else(|| AppError::Unauthorized("Invalid credentials".to_string()))?;
    
    if user.password_hash != hash_password(&req.password) {
        return Err(AppError::Unauthorized("Invalid credentials".to_string()));
    }
    
    let token = Uuid::new_v4().to_string();
    state.sessions.lock().unwrap().insert(token.clone(), user_id);
    
    let mut headers = HeaderMap::new();
    headers.insert(
        header::SET_COOKIE,
        HeaderValue::from_str(&format!("session_id={}; Path=/; HttpOnly", token)).unwrap(),
    );
    
    Ok((
        headers,
        Json(UserResponse {
            id: user.id,
            username: user.username.clone(),
        }),
    ))
}

async fn logout(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, AppError> {
    let auth = get_auth(&headers, &state)?;
    state.sessions.lock().unwrap().remove(&auth.token);
    Ok(Json(serde_json::json!({})))
}

async fn get_me(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<UserResponse>, AppError> {
    let auth = get_auth(&headers, &state)?;
    let users = state.users.lock().unwrap();
    let user = users
        .get(&auth.user_id)
        .ok_or_else(|| AppError::Unauthorized("Authentication required".to_string()))?;
    Ok(Json(UserResponse {
        id: user.id,
        username: user.username.clone(),
    }))
}

async fn change_password(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<PasswordChangeRequest>,
) -> Result<Json<serde_json::Value>, AppError> {
    let auth = get_auth(&headers, &state)?;
    if req.new_password.len() < 8 {
        return Err(AppError::BadRequest("Password too short".to_string()));
    }
    
    let mut users = state.users.lock().unwrap();
    let user = users
        .get_mut(&auth.user_id)
        .ok_or_else(|| AppError::Unauthorized("Authentication required".to_string()))?;
    
    if user.password_hash != hash_password(&req.old_password) {
        return Err(AppError::Unauthorized("Invalid credentials".to_string()));
    }
    
    user.password_hash = hash_password(&req.new_password);
    Ok(Json(serde_json::json!({})))
}

async fn get_todos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Vec<TodoResponse>>, AppError> {
    let auth = get_auth(&headers, &state)?;
    let todos = state.todos.lock().unwrap();
    let mut user_todos: Vec<TodoResponse> = todos
        .values()
        .filter(|t| t.user_id == auth.user_id)
        .map(|t| TodoResponse::from(t.clone()))
        .collect();
    
    user_todos.sort_by_key(|t| t.id);
    Ok(Json(user_todos))
}

async fn create_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<CreateTodoRequest>,
) -> Result<(StatusCode, Json<TodoResponse>), AppError> {
    let auth = get_auth(&headers, &state)?;
    let title = req.title.unwrap_or_default();
    if title.trim().is_empty() {
        return Err(AppError::BadRequest("Title is required".to_string()));
    }
    
    let description = req.description.unwrap_or_default();
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    
    let mut todos = state.todos.lock().unwrap();
    let mut counter = state.todo_id_counter.lock().unwrap();
    *counter += 1;
    let new_id = *counter;
    
    let new_todo = Todo {
        id: new_id,
        user_id: auth.user_id,
        title,
        description,
        completed: false,
        created_at: now.clone(),
        updated_at: now,
    };
    todos.insert(new_id, new_todo.clone());
    
    Ok((StatusCode::CREATED, Json(TodoResponse::from(new_todo))))
}

async fn get_todo(
    Path(todo_id): Path<u64>,
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<TodoResponse>, AppError> {
    let auth = get_auth(&headers, &state)?;
    let todos = state.todos.lock().unwrap();
    let todo = todos
        .get(&todo_id)
        .ok_or_else(|| AppError::NotFound("Todo not found".to_string()))?;
    
    if todo.user_id != auth.user_id {
        return Err(AppError::NotFound("Todo not found".to_string()));
    }
    
    Ok(Json(TodoResponse::from(todo.clone())))
}

async fn update_todo(
    Path(todo_id): Path<u64>,
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<UpdateTodoRequest>,
) -> Result<Json<TodoResponse>, AppError> {
    let auth = get_auth(&headers, &state)?;
    let mut todos = state.todos.lock().unwrap();
    let todo = todos
        .get_mut(&todo_id)
        .ok_or_else(|| AppError::NotFound("Todo not found".to_string()))?;
    
    if todo.user_id != auth.user_id {
        return Err(AppError::NotFound("Todo not found".to_string()));
    }
    
    if let Some(ref title) = req.title {
        if title.trim().is_empty() {
            return Err(AppError::BadRequest("Title is required".to_string()));
        }
        todo.title = title.clone();
    }
    
    if let Some(description) = req.description {
        todo.description = description;
    }
    
    if let Some(completed) = req.completed {
        todo.completed = completed;
    }
    
    todo.updated_at = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    
    Ok(Json(TodoResponse::from(todo.clone())))
}

async fn delete_todo(
    Path(todo_id): Path<u64>,
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<StatusCode, AppError> {
    let auth = get_auth(&headers, &state)?;
    let mut todos = state.todos.lock().unwrap();
    let todo = todos
        .get(&todo_id)
        .ok_or_else(|| AppError::NotFound("Todo not found".to_string()))?;
    
    if todo.user_id != auth.user_id {
        return Err(AppError::NotFound("Todo not found".to_string()));
    }
    
    todos.remove(&todo_id);
    Ok(StatusCode::NO_CONTENT)
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut port = 8080;
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse().expect("Invalid port number");
            i += 2;
        } else {
            i += 1;
        }
    }

    let state = Arc::new(AppState::new());

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(get_me))
        .route("/password", put(change_password))
        .route("/todos", get(get_todos))
        .route("/todos", post(create_todo))
        .route("/todos/:id", get(get_todo))
        .route("/todos/:id", put(update_todo))
        .route("/todos/:id", delete(delete_todo))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", port);
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    println!("Listening on {}", addr);
    axum::serve(listener, app).await.unwrap();
}
