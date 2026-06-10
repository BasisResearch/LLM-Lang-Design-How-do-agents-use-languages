use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router,
};
use chrono::Utc;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, OnceLock};
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: u32,
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Todo {
    pub id: u32,
    pub user_id: u32,
    pub title: String,
    pub description: String,
    pub completed: bool,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone)]
pub struct AppState {
    pub users: Arc<RwLock<HashMap<u32, User>>>,
    pub sessions: Arc<RwLock<HashMap<String, u32>>>,
    pub todos: Arc<RwLock<HashMap<u32, Todo>>>,
    pub next_user_id: Arc<AtomicU32>,
    pub next_todo_id: Arc<AtomicU32>,
}

fn username_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap())
}

async fn require_auth(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<u32, Response> {
    let cookie_header = headers.get(header::COOKIE).and_then(|v| v.to_str().ok());
    let session_id = cookie_header
        .and_then(|c| {
            c.split(';')
                .find(|p| p.trim().starts_with("session_id="))
                .map(|p| p.trim().trim_start_matches("session_id=").to_string())
        });
    
    if let Some(sid) = session_id {
        let sessions = state.sessions.read().await;
        if let Some(&user_id) = sessions.get(&sid) {
            return Ok(user_id);
        }
    }
    Err((
        StatusCode::UNAUTHORIZED,
        Json(json!({"error": "Authentication required"})),
    ).into_response())
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn register(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegisterRequest>,
) -> impl IntoResponse {
    let username = match req.username {
        Some(u) if username_re().is_match(&u) => u,
        _ => return (StatusCode::BAD_REQUEST, Json(json!({"error": "Invalid username"}))).into_response(),
    };
    
    let password = match req.password {
        Some(p) if p.len() >= 8 => p,
        _ => return (StatusCode::BAD_REQUEST, Json(json!({"error": "Password too short"}))).into_response(),
    };

    let mut users = state.users.write().await;
    if users.values().any(|u| u.username == username) {
        return (StatusCode::CONFLICT, Json(json!({"error": "Username already exists"}))).into_response();
    }

    let user_id = state.next_user_id.fetch_add(1, Ordering::SeqCst);
    users.insert(user_id, User {
        id: user_id,
        username: username.clone(),
        password,
    });

    (StatusCode::CREATED, Json(json!({"id": user_id, "username": username}))).into_response()
}

#[derive(Deserialize)]
struct LoginRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn login(
    State(state): State<Arc<AppState>>,
    Json(req): Json<LoginRequest>,
) -> impl IntoResponse {
    let username = req.username.unwrap_or_default();
    let password = req.password.unwrap_or_default();

    let user_id = {
        let users = state.users.read().await;
        users.values().find(|u| u.username == username && u.password == password).map(|u| u.id)
    };

    let user_id = match user_id {
        Some(id) => id,
        None => return (StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))).into_response(),
    };

    let session_id = Uuid::new_v4().to_string();
    {
        let mut sessions = state.sessions.write().await;
        sessions.insert(session_id.clone(), user_id);
    }

    let users = state.users.read().await;
    let user = users.get(&user_id).unwrap();

    let mut headers = HeaderMap::new();
    let cookie_val = format!("session_id={}; Path=/; HttpOnly", session_id);
    headers.insert(header::SET_COOKIE, cookie_val.parse().unwrap());

    (StatusCode::OK, headers, Json(json!({"id": user.id, "username": user.username}))).into_response()
}

async fn logout(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let _ = require_auth(&state, &headers).await; // Just to verify auth

    let cookie_header = headers.get(header::COOKIE).and_then(|v| v.to_str().ok());
    if let Some(sid) = cookie_header.and_then(|c| {
        c.split(';')
            .find(|p| p.trim().starts_with("session_id="))
            .map(|p| p.trim().trim_start_matches("session_id=").to_string())
    }) {
        let mut sessions = state.sessions.write().await;
        sessions.remove(&sid);
    }

    (StatusCode::OK, Json(json!({}))).into_response()
}

async fn me(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let user_id = match require_auth(&state, &headers).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let users = state.users.read().await;
    if let Some(user) = users.get(&user_id) {
        (StatusCode::OK, Json(json!({"id": user.id, "username": user.username}))).into_response()
    } else {
        (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))).into_response()
    }
}

#[derive(Deserialize)]
struct PasswordRequest {
    old_password: Option<String>,
    new_password: Option<String>,
}

async fn change_password(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<PasswordRequest>,
) -> impl IntoResponse {
    let user_id = match require_auth(&state, &headers).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let old_password = req.old_password.unwrap_or_default();
    let new_password = req.new_password.unwrap_or_default();

    if new_password.len() < 8 {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": "Password too short"}))).into_response();
    }

    let mut users = state.users.write().await;
    if let Some(user) = users.get_mut(&user_id) {
        if user.password != old_password {
            return (StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))).into_response();
        }
        user.password = new_password;
        (StatusCode::OK, Json(json!({}))).into_response()
    } else {
        (StatusCode::UNAUTHORIZED, Json(json!({"error": "Authentication required"}))).into_response()
    }
}

async fn list_todos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let user_id = match require_auth(&state, &headers).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let todos = state.todos.read().await;
    let mut user_todos: Vec<_> = todos.values()
        .filter(|t| t.user_id == user_id)
        .collect();
    
    user_todos.sort_by_key(|t| t.id);
    
    (StatusCode::OK, Json(user_todos)).into_response()
}

#[derive(Deserialize)]
struct CreateTodoRequest {
    title: Option<String>,
    description: Option<String>,
}

async fn create_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<CreateTodoRequest>,
) -> impl IntoResponse {
    let user_id = match require_auth(&state, &headers).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let title = match req.title {
        Some(t) if !t.is_empty() => t,
        _ => return (StatusCode::BAD_REQUEST, Json(json!({"error": "Title is required"}))).into_response(),
    };

    let description = req.description.unwrap_or_default();
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let todo_id = state.next_todo_id.fetch_add(1, Ordering::SeqCst);

    let todo = Todo {
        id: todo_id,
        user_id,
        title,
        description,
        completed: false,
        created_at: now.clone(),
        updated_at: now,
    };

    state.todos.write().await.insert(todo_id, todo.clone());
    (StatusCode::CREATED, Json(todo)).into_response()
}

async fn get_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(todo_id): Path<u32>,
) -> impl IntoResponse {
    let user_id = match require_auth(&state, &headers).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let todos = state.todos.read().await;
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id == user_id {
            return (StatusCode::OK, Json(todo.clone())).into_response();
        }
    }
    (StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))).into_response()
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

async fn update_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(todo_id): Path<u32>,
    Json(req): Json<UpdateTodoRequest>,
) -> impl IntoResponse {
    let user_id = match require_auth(&state, &headers).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let mut todos = state.todos.write().await;
    if let Some(todo) = todos.get_mut(&todo_id) {
        if todo.user_id != user_id {
            return (StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))).into_response();
        }

        if let Some(title) = req.title {
            if title.is_empty() {
                return (StatusCode::BAD_REQUEST, Json(json!({"error": "Title is required"}))).into_response();
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
        
        return (StatusCode::OK, Json(todo.clone())).into_response();
    }
    (StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))).into_response()
}

async fn delete_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(todo_id): Path<u32>,
) -> impl IntoResponse {
    let user_id = match require_auth(&state, &headers).await {
        Ok(id) => id,
        Err(resp) => return resp,
    };

    let mut todos = state.todos.write().await;
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id != user_id {
            return (StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))).into_response();
        }
        todos.remove(&todo_id);
        return StatusCode::NO_CONTENT.into_response();
    }
    (StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"}))).into_response()
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut port = 3000;
    
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse().expect("Invalid port number");
            i += 2;
        } else {
            i += 1;
        }
    }

    let state = Arc::new(AppState {
        users: Arc::new(RwLock::new(HashMap::new())),
        sessions: Arc::new(RwLock::new(HashMap::new())),
        todos: Arc::new(RwLock::new(HashMap::new())),
        next_user_id: Arc::new(AtomicU32::new(1)),
        next_todo_id: Arc::new(AtomicU32::new(1)),
    });

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos))
        .route("/todos", post(create_todo))
        .route("/todos/{id}", get(get_todo))
        .route("/todos/{id}", put(update_todo))
        .route("/todos/{id}", delete(delete_todo))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", port);
    println!("Starting server on {}", addr);
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
