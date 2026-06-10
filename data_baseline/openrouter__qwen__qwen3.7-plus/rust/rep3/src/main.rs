use axum::{
    extract::{FromRef, FromRequestParts, Json, Path, State},
    http::{header, request::Parts, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Router,
};
use axum::async_trait;
use axum_extra::extract::CookieJar;
use chrono::Utc;
use clap::Parser;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Parser, Debug)]
#[command(name = "todo_app")]
#[command(about = "A REST API server for managing personal todo items")]
struct Args {
    #[arg(long)]
    port: u16,
}

#[derive(Clone)]
pub struct AppState {
    pub users: Arc<RwLock<HashMap<i32, User>>>,
    pub todos: Arc<RwLock<HashMap<i32, Todo>>>,
    pub sessions: Arc<RwLock<HashMap<String, i32>>>,
    pub next_user_id: Arc<RwLock<i32>>,
    pub next_todo_id: Arc<RwLock<i32>>,
}

pub struct User {
    pub id: i32,
    pub username: String,
    pub password: String,
}

#[derive(Serialize, Clone, Deserialize)]
pub struct Todo {
    pub id: i32,
    pub title: String,
    pub description: String,
    pub completed: bool,
    pub created_at: String,
    pub updated_at: String,
    #[serde(skip_serializing)]
    pub user_id: i32,
}

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub username: String,
    pub password: String,
}

#[derive(Serialize)]
pub struct UserResponse {
    pub id: i32,
    pub username: String,
}

#[derive(Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct PasswordRequest {
    pub old_password: String,
    pub new_password: String,
}

#[derive(Deserialize)]
pub struct TodoRequest {
    pub title: Option<String>,
    pub description: Option<String>,
}

#[derive(Deserialize)]
pub struct TodoUpdateRequest {
    pub title: Option<String>,
    pub description: Option<String>,
    pub completed: Option<bool>,
}

pub enum AppError {
    BadRequest(String),
    NotFound(String),
    Unauthorized(String),
    Conflict(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            AppError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            AppError::NotFound(msg) => (StatusCode::NOT_FOUND, msg),
            AppError::Unauthorized(msg) => (StatusCode::UNAUTHORIZED, msg),
            AppError::Conflict(msg) => (StatusCode::CONFLICT, msg),
        };
        (status, axum::Json(serde_json::json!({"error": message}))).into_response()
    }
}

pub struct AuthUser(pub i32);

#[async_trait]
impl<S> FromRequestParts<S> for AuthUser
where
    S: Send + Sync,
    AppState: FromRef<S>,
{
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let app_state = AppState::from_ref(state);
        let cookie_jar = CookieJar::from_headers(&parts.headers);
        
        if let Some(cookie) = cookie_jar.get("session_id") {
            let sessions = app_state.sessions.read().await;
            if let Some(&user_id) = sessions.get(cookie.value()) {
                return Ok(AuthUser(user_id));
            }
        }
        Err(AppError::Unauthorized("Authentication required".to_string()))
    }
}

async fn register(
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> impl IntoResponse {
    let username_re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    if !username_re.is_match(&req.username) || req.username.len() < 3 || req.username.len() > 50 {
        return AppError::BadRequest("Invalid username".to_string()).into_response();
    }
    if req.password.len() < 8 {
        return AppError::BadRequest("Password too short".to_string()).into_response();
    }
    
    let mut users = state.users.write().await;
    for user in users.values() {
        if user.username == req.username {
            return AppError::Conflict("Username already exists".to_string()).into_response();
        }
    }
    
    let mut next_id = state.next_user_id.write().await;
    let id = *next_id;
    *next_id += 1;
    
    users.insert(id, User {
        id,
        username: req.username.clone(),
        password: req.password.clone(),
    });
    
    (StatusCode::CREATED, axum::Json(UserResponse { id, username: req.username })).into_response()
}

async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
) -> impl IntoResponse {
    let users = state.users.read().await;
    if let Some(user) = users.values().find(|u| u.username == req.username && u.password == req.password) {
        let session_id = Uuid::new_v4().to_string();
        state.sessions.write().await.insert(session_id.clone(), user.id);
        
        let mut headers = HeaderMap::new();
        let cookie_val = format!("session_id={}; Path=/; HttpOnly", session_id);
        headers.insert(header::SET_COOKIE, HeaderValue::from_str(&cookie_val).unwrap());
        
        (
            StatusCode::OK,
            headers,
            axum::Json(UserResponse { id: user.id, username: user.username.clone() })
        ).into_response()
    } else {
        AppError::Unauthorized("Invalid credentials".to_string()).into_response()
    }
}

async fn logout(
    AuthUser(_user_id): AuthUser,
    cookie_jar: CookieJar,
    State(state): State<AppState>,
) -> impl IntoResponse {
    if let Some(cookie) = cookie_jar.get("session_id") {
        let mut sessions = state.sessions.write().await;
        sessions.remove(cookie.value());
    }
    let cookie_jar = cookie_jar.remove("session_id");
    (StatusCode::OK, cookie_jar, axum::Json(serde_json::json!({}))).into_response()
}

async fn me(
    AuthUser(user_id): AuthUser,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let users = state.users.read().await;
    if let Some(user) = users.get(&user_id) {
        (StatusCode::OK, axum::Json(UserResponse { id: user.id, username: user.username.clone() })).into_response()
    } else {
        AppError::Unauthorized("Authentication required".to_string()).into_response()
    }
}

async fn update_password(
    AuthUser(user_id): AuthUser,
    State(state): State<AppState>,
    Json(req): Json<PasswordRequest>,
) -> impl IntoResponse {
    if req.new_password.len() < 8 {
        return AppError::BadRequest("Password too short".to_string()).into_response();
    }
    
    let mut users = state.users.write().await;
    if let Some(user) = users.get_mut(&user_id) {
        if user.password != req.old_password {
            return AppError::Unauthorized("Invalid credentials".to_string()).into_response();
        }
        user.password = req.new_password;
        (StatusCode::OK, axum::Json(serde_json::json!({}))).into_response()
    } else {
        AppError::Unauthorized("Authentication required".to_string()).into_response()
    }
}

async fn list_todos(
    AuthUser(user_id): AuthUser,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let todos = state.todos.read().await;
    let mut user_todos: Vec<Todo> = todos.values()
        .filter(|t| t.user_id == user_id)
        .cloned()
        .collect();
    user_todos.sort_by_key(|t| t.id);
    
    (StatusCode::OK, axum::Json(user_todos)).into_response()
}

async fn create_todo(
    AuthUser(user_id): AuthUser,
    State(state): State<AppState>,
    Json(req): Json<TodoRequest>,
) -> impl IntoResponse {
    let title = match req.title {
        Some(t) if !t.is_empty() => t,
        _ => return AppError::BadRequest("Title is required".to_string()).into_response(),
    };
    
    let description = req.description.unwrap_or_default();
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    
    let mut next_id = state.next_todo_id.write().await;
    let id = *next_id;
    *next_id += 1;
    
    let todo = Todo {
        id,
        user_id,
        title,
        description,
        completed: false,
        created_at: now.clone(),
        updated_at: now,
    };
    
    state.todos.write().await.insert(id, todo.clone());
    
    (StatusCode::CREATED, axum::Json(todo)).into_response()
}

async fn get_todo(
    AuthUser(user_id): AuthUser,
    Path(todo_id): Path<i32>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let todos = state.todos.read().await;
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id == user_id {
            (StatusCode::OK, axum::Json(todo.clone())).into_response()
        } else {
            AppError::NotFound("Todo not found".to_string()).into_response()
        }
    } else {
        AppError::NotFound("Todo not found".to_string()).into_response()
    }
}

async fn update_todo(
    AuthUser(user_id): AuthUser,
    Path(todo_id): Path<i32>,
    State(state): State<AppState>,
    Json(req): Json<TodoUpdateRequest>,
) -> impl IntoResponse {
    let mut todos = state.todos.write().await;
    if let Some(todo) = todos.get_mut(&todo_id) {
        if todo.user_id != user_id {
            return AppError::NotFound("Todo not found".to_string()).into_response();
        }
        
        if let Some(title) = req.title {
            if title.is_empty() {
                return AppError::BadRequest("Title is required".to_string()).into_response();
            }
            todo.title = title;
        }
        if let Some(description) = req.description {
            todo.description = description;
        }
        if let Some(completed) = req.completed {
            todo.completed = completed;
        }
        todo.updated_at = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        
        (StatusCode::OK, axum::Json(todo.clone())).into_response()
    } else {
        AppError::NotFound("Todo not found".to_string()).into_response()
    }
}

async fn delete_todo(
    AuthUser(user_id): AuthUser,
    Path(todo_id): Path<i32>,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let mut todos = state.todos.write().await;
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id != user_id {
            return AppError::NotFound("Todo not found".to_string()).into_response();
        }
        todos.remove(&todo_id);
        StatusCode::NO_CONTENT.into_response()
    } else {
        AppError::NotFound("Todo not found".to_string()).into_response()
    }
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let addr = format!("0.0.0.0:{}", args.port);
    println!("Listening on {}", addr);
    
    let state = AppState {
        users: Arc::new(RwLock::new(HashMap::new())),
        todos: Arc::new(RwLock::new(HashMap::new())),
        sessions: Arc::new(RwLock::new(HashMap::new())),
        next_user_id: Arc::new(RwLock::new(1)),
        next_todo_id: Arc::new(RwLock::new(1)),
    };

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(update_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(axum::routing::delete(delete_todo)))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}