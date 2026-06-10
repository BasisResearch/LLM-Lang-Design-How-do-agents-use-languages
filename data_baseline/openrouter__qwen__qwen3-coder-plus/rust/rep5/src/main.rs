use axum::{
    extract::{FromRequestParts, Path, State},
    http::{header::COOKIE, HeaderMap, StatusCode, HeaderValue},
    response::{IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router, 
};
use chrono::{DateTime, Utc};
use lazy_static::lazy_static;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use tokio::signal;
use uuid::Uuid;

// Data Structures
#[derive(Debug, Clone, Serialize)]
pub struct User {
    pub id: i32,
    pub username: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Todo {
    pub id: i32,
    pub title: String,
    pub description: String,
    pub completed: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

// Authentication extractor
#[derive(Debug, Clone)]
pub struct AuthenticatedUser {
    pub user_id: i32,
    pub username: String,
}

#[async_trait::async_trait]
impl<S> FromRequestParts<S> for AuthenticatedUser
where
    S: Send + Sync,
{
    type Rejection = (StatusCode, Json<serde_json::Value>);

    async fn from_request_parts(parts: &mut axum::http::request::Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let headers = &parts.headers;
        
        if let Some(session_id) = extract_session_id(headers) {
            // Get state from extensions or look for a better way to access it
            // Since we're inside the handler chain, we get the state differently
            // Let's implement differently by checking state availability directly
            
            // For the middleware pattern, we would need to set up state properly in extensions, 
            // but axum makes this tricky. So instead, let's modify it so the function receives state in each route
            // Instead of having a true extractor, I'll implement direct verification in protected endpoints
            
            // Just return placeholder error to indicate the issue, actually we need to implement a proper solution
            return Err((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "Authentication required"}))));
        }
        
        Err((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "Authentication required"}))))
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
struct UpdatePasswordRequest {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize)]
struct CreateTodoRequest {
    title: String,
    description: Option<String>,
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

#[derive(Debug, Clone)]
struct Session {
    user_id: i32,
}

#[derive(Clone)]
struct AppState {
    users: Arc<RwLock<HashMap<i32, User>>>,
    passwords: Arc<RwLock<HashMap<i32, String>>>, // Simple implementation, real apps should hash
    todos: Arc<RwLock<HashMap<i32, HashMap<i32, Todo>>>>, // user_id -> {todo_id -> todo}
    sessions: Arc<RwLock<HashMap<String, Session>>>,
    next_user_id: Arc<RwLock<i32>>,
    next_todo_id: Arc<RwLock<i32>>,
}

impl AppState {
    fn new() -> Self {
        Self {
            users: Arc::new(RwLock::new(HashMap::new())),
            passwords: Arc::new(RwLock::new(HashMap::new())),
            todos: Arc::new(RwLock::new(HashMap::new())),
            sessions: Arc::new(RwLock::new(HashMap::new())),
            next_user_id: Arc::new(RwLock::new(1)),
            next_todo_id: Arc::new(RwLock::new(1)),
        }
    }

    fn validate_username(username: &str) -> bool {
        lazy_static! {
            static ref USERNAME_REGEX: Regex = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
        }
        USERNAME_REGEX.is_match(username)
    }

    async fn register_user(&self, req: RegisterRequest) -> Result<User, (StatusCode, String)> {
        if !Self::validate_username(&req.username) {
            return Err((StatusCode::BAD_REQUEST, "Invalid username".to_string()));
        }
        
        if req.password.len() < 8 {
            return Err((StatusCode::BAD_REQUEST, "Password too short".to_string()));
        }

        let mut users = self.users.write().unwrap();
        for user in users.values() {
            if user.username == req.username {
                return Err((StatusCode::CONFLICT, "Username already exists".to_string()));
            }
        }

        let user_id = *self.next_user_id.write().unwrap();
        *self.next_user_id.write().unwrap() += 1;

        let user = User {
            id: user_id,
            username: req.username.clone(),
        };

        users.insert(user_id, user.clone());
        drop(users);
        
        let mut passwords = self.passwords.write().unwrap();
        passwords.insert(user_id, req.password);

        Ok(user)
    }

    async fn authenticate_user(&self, username: &str, password: &str) -> Option<i32> {
        let users = self.users.read().unwrap();
        let mut target_user_id = None;
        for (user_id, user) in users.iter() {
            if user.username == username {
                target_user_id = Some(*user_id);
                break;
            }
        }

        match target_user_id {
            Some(user_id) => {
                let passwords = self.passwords.read().unwrap();
                if let Some(stored_password) = passwords.get(&user_id) {
                    if *stored_password == password {
                        Some(user_id)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            None => None,
        }
    }

    async fn create_session(&self, user_id: i32) -> String {
        let session_id = Uuid::new_v4().to_string();
        let session = Session { user_id };
        
        let mut sessions = self.sessions.write().unwrap();
        sessions.insert(session_id.clone(), session);
        
        session_id
    }

    async fn get_user_from_session(&self, session_id: &str) -> Option<(i32, User)> {
        let sessions = self.sessions.read().unwrap();
        if let Some(session) = sessions.get(session_id) {
            let users = self.users.read().unwrap();
            if let Some(user) = users.get(&session.user_id).cloned() {
                Some((session.user_id, user))
            } else {
                None
            }
        } else {
            None
        }
    }

    async fn invalidate_session(&self, session_id: &str) -> bool {
        let mut sessions = self.sessions.write().unwrap();
        sessions.remove(session_id).is_some()
    }

    async fn change_password(&self, user_id: i32, old_password: &str, new_password: &str) -> Result<(), (StatusCode, String)> {
        let passwords = self.passwords.read().unwrap();
        if let Some(current_password) = passwords.get(&user_id) {
            if *current_password != old_password {
                return Err((StatusCode::UNAUTHORIZED, "Invalid credentials".to_string()));
            }
        } else {
            return Err((StatusCode::UNAUTHORIZED, "Invalid credentials".to_string()));
        }
        
        if new_password.len() < 8 {
            return Err((StatusCode::BAD_REQUEST, "Password too short".to_string()));
        }

        drop(passwords);
        let mut passwords = self.passwords.write().unwrap();
        passwords.insert(user_id, new_password.to_string());
        Ok(())
    }

    async fn create_todo(&self, user_id: i32, req: CreateTodoRequest) -> Result<Todo, (StatusCode, String)> {
        if req.title.is_empty() {
            return Err((StatusCode::BAD_REQUEST, "Title is required".to_string()));
        }

        let todo_id = *self.next_todo_id.write().unwrap();
        *self.next_todo_id.write().unwrap() += 1;

        let now = Utc::now();
        let todo = Todo {
            id: todo_id,
            title: req.title,
            description: req.description.unwrap_or_default(),
            completed: false,
            created_at: now,
            updated_at: now,
        };

        let mut todos = self.todos.write().unwrap();
        let user_todos = todos.entry(user_id).or_insert_with(HashMap::new);
        user_todos.insert(todo_id, todo.clone());

        Ok(todo)
    }

    async fn get_todos_for_user(&self, user_id: i32) -> Vec<Todo> {
        let todos = self.todos.read().unwrap();
        if let Some(user_todos) = todos.get(&user_id) {
            let mut result: Vec<Todo> = user_todos.values().cloned().collect();
            result.sort_by_key(|t| t.id); // Sort by ID ascending
            result
        } else {
            vec![]
        }
    }

    async fn get_todo_for_user(&self, user_id: i32, todo_id: i32) -> Option<Todo> {
        let todos = self.todos.read().unwrap();
        if let Some(user_todos) = todos.get(&user_id) {
            user_todos.get(&todo_id).cloned()
        } else {
            None
        }
    }

    async fn update_todo(&self, user_id: i32, todo_id: i32, req: UpdateTodoRequest) -> Result<Todo, (StatusCode, String)> {
        let mut todos = self.todos.write().unwrap();
        let user_todos = todos.get_mut(&user_id);
        if user_todos.is_none() {
            return Err((StatusCode::NOT_FOUND, "Todo not found".to_string()));
        }
        let user_todos = user_todos.unwrap();

        let todo = user_todos.get_mut(&todo_id);
        if todo.is_none() {
            return Err((StatusCode::NOT_FOUND, "Todo not found".to_string()));
        }
        let todo = todo.unwrap();

        // Validate title if provided
        if let Some(ref title) = req.title {
            if title.is_empty() {
                return Err((StatusCode::BAD_REQUEST, "Title is required".to_string()));
            }
            todo.title = title.clone();
        }

        // Update other fields if provided
        if let Some(description) = req.description {
            todo.description = description;
        }
        if let Some(completed) = req.completed {
            todo.completed = completed;
        }

        todo.updated_at = Utc::now();

        Ok(todo.clone())
    }

    async fn delete_todo(&self, user_id: i32, todo_id: i32) -> bool {
        let mut todos = self.todos.write().unwrap();
        if let Some(user_todos) = todos.get_mut(&user_id) {
            user_todos.remove(&todo_id).is_some()
        } else {
            false
        }
    }
}

// Helper function to extract session ID from cookies
fn extract_session_id(headers: &HeaderMap) -> Option<String> {
    if let Some(cookie_header) = headers.get(COOKIE) {
        if let Ok(cookie_str) = cookie_header.to_str() {
            for cookie in cookie_str.split(';') {
                let cookie = cookie.trim();
                if cookie.starts_with("session_id=") {
                    return Some(cookie[11..].to_string()); // Remove "session_id=" prefix
                }
            }
        }
    }
    None
}

async fn check_authentication(headers: &HeaderMap, state: &AppState) -> Option<(i32, User)> {
    if let Some(session_id) = extract_session_id(headers) {
        return state.get_user_from_session(&session_id).await;
    }
    None
}

// Error response helper
fn error_response(status: StatusCode, message: &str) -> Response {
    (
        status,
        Json(serde_json::json!({"error": message}))
    ).into_response()
}

// Route handlers
async fn register(
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> Result<impl IntoResponse, Response> {
    match state.register_user(req).await {
        Ok(user) => Ok((StatusCode::CREATED, Json(user))),
        Err((status, error_msg)) => Err(error_response(status, &error_msg)),
    }
}

async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
) -> Result<Response, Response> {
    match state.authenticate_user(&req.username, &req.password).await {
        Some(user_id) => {
            let session_id = state.create_session(user_id).await;
            
            let users = state.users.read().unwrap();
            let user = users.get(&user_id).unwrap().clone();
            drop(users);

            // Create response with custom headers
            let mut resp = Response::builder()
                .status(StatusCode::OK)
                .header("Content-Type", "application/json");

            let body = serde_json::to_vec(&user).unwrap();
            
            let res = resp
                .body(axum::body::Body::from(body))
                .map_err(|_| error_response(StatusCode::INTERNAL_SERVER_ERROR, "Failed to create response"))?;

            // We need to set the cookie in the actual response's headers
            let mut result_resp = res;
            if let Ok(set_cookie_value) = HeaderValue::from_str(&format!(
                "session_id={}; Path=/; HttpOnly",
                session_id
            )) {
                result_resp.headers_mut().insert(axum::http::header::SET_COOKIE, set_cookie_value);
            }
            
            Ok(result_resp)
        },
        None => Err(error_response(StatusCode::UNAUTHORIZED, "Invalid credentials"))
    }
}

async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, Response> {
    if let Some(session_id) = extract_session_id(&headers) {
        state.invalidate_session(&session_id).await;
    }
    
    Ok((StatusCode::OK, Json(serde_json::json!({}))))
}

async fn get_me(
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, Response> {
    if let Some((user_id, user)) = check_authentication(&headers, &state).await {
        Ok(Json(user))
    } else {
        Err(error_response(StatusCode::UNAUTHORIZED, "Authentication required"))
    }
}

async fn update_password(
    headers: HeaderMap,
    State(state): State<AppState>,
    Json(req): Json<UpdatePasswordRequest>,
) -> Result<impl IntoResponse, Response> {
    if let Some((user_id, _)) = check_authentication(&headers, &state).await {
        match state.change_password(user_id, &req.old_password, &req.new_password).await {
            Ok(()) => Ok((StatusCode::OK, Json(serde_json::json!({})), )),
            Err((status, error_msg)) => Err(error_response(status, &error_msg)), 
        }
    } else {
        Err(error_response(StatusCode::UNAUTHORIZED, "Authentication required"))
    }
}

async fn get_todos(
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, Response> {
    if let Some((user_id, _)) = check_authentication(&headers, &state).await {
        let todos = state.get_todos_for_user(user_id).await;
        Ok(Json(todos))
    } else {
        Err(error_response(StatusCode::UNAUTHORIZED, "Authentication required"))
    }
}

async fn create_todo(
    headers: HeaderMap,
    State(state): State<AppState>,
    Json(req): Json<CreateTodoRequest>,
) -> Result<impl IntoResponse, Response> {
    if let Some((user_id, _)) = check_authentication(&headers, &state).await {
        match state.create_todo(user_id, req).await {
            Ok(todo) => Ok((StatusCode::CREATED, Json(todo))),
            Err((status, error_msg)) => Err(error_response(status, &error_msg)), 
        }
    } else {
        Err(error_response(StatusCode::UNAUTHORIZED, "Authentication required"))
    }
}

async fn get_todo_by_id(
    headers: HeaderMap,
    State(state): State<AppState>,
    Path(todo_id): Path<i32>,
) -> Result<impl IntoResponse, Response> {
    if let Some((user_id, _)) = check_authentication(&headers, &state).await {
        if let Some(todo) = state.get_todo_for_user(user_id, todo_id).await {
            Ok(Json(todo))
        } else {
            Err(error_response(StatusCode::NOT_FOUND, "Todo not found"))
        }
    } else {
        Err(error_response(StatusCode::UNAUTHORIZED, "Authentication required"))
    }
}

async fn update_todo_by_id(
    headers: HeaderMap,
    State(state): State<AppState>,
    Path(todo_id): Path<i32>,
    Json(req): Json<UpdateTodoRequest>,
) -> Result<impl IntoResponse, Response> {
    if let Some((user_id, _)) = check_authentication(&headers, &state).await {
        match state.update_todo(user_id, todo_id, req).await {
            Ok(updated_todo) => Ok(Json(updated_todo)),
            Err((status, error_msg)) => Err(error_response(status, &error_msg)),
        }
    } else {
        Err(error_response(StatusCode::UNAUTHORIZED, "Authentication required"))
    }
}

async fn delete_todo_by_id(
    headers: HeaderMap,
    State(state): State<AppState>,
    Path(todo_id): Path<i32>,
) -> Result<impl IntoResponse, Response> {
    if let Some((user_id, _)) = check_authentication(&headers, &state).await {
        if state.delete_todo(user_id, todo_id).await {
            Ok(StatusCode::NO_CONTENT.into_response())
        } else {
            Err(error_response(StatusCode::NOT_FOUND, "Todo not found"))
        }
    } else {
        Err(error_response(StatusCode::UNAUTHORIZED, "Authentication required"))
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut port = 8080;
    
    for i in 0..args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse().expect("--port argument must be a valid number");
        }
    }
    
    println!("Starting server on port {}", port);

    let state = AppState::new();
    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(get_me))
        .route("/password", put(update_password))
        .route("/todos", get(get_todos).post(create_todo))
        .route("/todos/:id", get(get_todo_by_id).put(update_todo_by_id).delete(delete_todo_by_id))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port))
        .await
        .unwrap();
        
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("Failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("Failed to install signal handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    
    println!("Shutting down gracefully...");
}