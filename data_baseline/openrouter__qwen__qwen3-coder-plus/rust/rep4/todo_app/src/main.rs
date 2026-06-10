use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::*,
    Json, Router, body::Body,
};
use chrono::{DateTime, Utc, SubsecRound};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio;
use uuid::Uuid;
use axum_extra::extract::cookie::{Cookie};

// Data structures
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: u32,
    pub username: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Todo {
    pub id: u32,
    pub title: String,
    pub description: String,
    pub completed: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Deserialize)]
pub struct CreateUserRequest {
    pub username: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

#[derive(Deserialize)]
pub struct UpdatePasswordRequest {
    pub old_password: String,
    pub new_password: String,
}

#[derive(Deserialize)]
pub struct CreateTodoRequest {
    pub title: String,
    pub description: String,
}

#[derive(Deserialize)]
pub struct UpdateTodoRequest {
    pub title: Option<String>,
    pub description: Option<String>,
    pub completed: Option<bool>,
}

#[derive(Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

// Application state
#[derive(Clone)]
struct AppState {
    users: Arc<Mutex<HashMap<u32, User>>>,
    passwords: Arc<Mutex<HashMap<u32, String>>>, // In a real app, these would be hashes
    user_id_counter: Arc<Mutex<u32>>,
    todos: Arc<Mutex<HashMap<u32, HashMap<u32, Todo>>>>, // user_id -> {todo_id -> todo}
    todo_id_counter: Arc<Mutex<u32>>,
    sessions: Arc<Mutex<HashMap<String, u32>>>, // session_token -> user_id
}

impl AppState {
    fn new() -> Self {
        Self {
            users: Arc::new(Mutex::new(HashMap::new())),
            passwords: Arc::new(Mutex::new(HashMap::new())),
            user_id_counter: Arc::new(Mutex::new(0)),
            todos: Arc::new(Mutex::new(HashMap::new())),
            todo_id_counter: Arc::new(Mutex::new(0)),
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn get_user_by_session(&self, session_id: &str) -> Option<User> {
        let sessions = self.sessions.lock().unwrap();
        if let Some(user_id) = sessions.get(session_id).copied() {
            let users = self.users.lock().unwrap();
            users.get(&user_id).cloned()
        } else {
            None
        }
    }

    fn authenticate_user(&self, username: &str, password: &str) -> Option<User> {
        let users = self.users.lock().unwrap();
        let passwords = self.passwords.lock().unwrap();
        
        for (&user_id, user) in &*users {
            if user.username == username {
                if let Some(stored_password) = passwords.get(&user_id) {
                    if stored_password == password {
                        return Some(user.clone());
                    }
                }
            }
        }
        None
    }
}

async fn extract_session_id(headers: &HeaderMap) -> Option<String> {
    if let Some(cookie_header) = headers.get("cookie") {
        let cookies = cookie_header.to_str().ok()?;
        let session_cookie = "session_id=";
        
        for cookie in cookies.split(';') {
            let cookie = cookie.trim();
            if cookie.starts_with(session_cookie) {
                return Some(cookie[session_cookie.len()..].to_string());
            }
        }
    }
    None
}

fn is_valid_username(username: &str) -> bool {
    if username.len() < 3 || username.len() > 50 {
        return false;
    }
    regex::Regex::new(r"^[a-zA-Z0-9_]+$").unwrap().is_match(username)
}

fn now() -> DateTime<Utc> {
    Utc::now().trunc_subsecs(0) // Truncate to seconds to achieve second precision
}

// Common error response function
async fn auth_required_response() -> Response {
    (
        StatusCode::UNAUTHORIZED,
        Json(ErrorResponse {
            error: "Authentication required".to_string(),
        }),
    ).into_response()
}

// Route handlers
async fn register(State(state): State<AppState>, Json(req): Json<CreateUserRequest>) -> Response {
    if !is_valid_username(&req.username) {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                error: "Invalid username".to_string(),
            }),
        ).into_response();
    }

    if req.password.len() < 8 {
        return (
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                error: "Password too short".to_string(),
            }),
        ).into_response();
    }

    {
        let users = state.users.lock().unwrap();
        for (_, user) in users.iter() {
            if user.username == req.username {
                return (
                    StatusCode::CONFLICT,
                    Json(ErrorResponse {
                        error: "Username already exists".to_string(),
                    }),
                ).into_response();
            }
        }
    }

    let mut user_id_counter = state.user_id_counter.lock().unwrap();
    *user_id_counter += 1;
    let user_id = *user_id_counter;
    
    let user = User {
        id: user_id,
        username: req.username.clone(),
    };

    {
        let mut users = state.users.lock().unwrap();
        let mut passwords = state.passwords.lock().unwrap();
        
        users.insert(user_id, user.clone());
        passwords.insert(user_id, req.password);
    }

    // Create an empty todo collection for this user
    let mut todos = state.todos.lock().unwrap();
    todos.insert(user_id, HashMap::new());

    (StatusCode::CREATED, Json(user)).into_response()
}

async fn login(State(state): State<AppState>, Json(req): Json<LoginRequest>) -> Response {
    let authenticated_user = state.authenticate_user(&req.username, &req.password);
    
    if let Some(user) = authenticated_user {
        let session_token = Uuid::new_v4().to_string();
        
        {
            let mut sessions = state.sessions.lock().unwrap();
            sessions.insert(session_token.clone(), user.id);
        }
        
        // Create response and add cookie header
        let body = serde_json::to_vec(&user).unwrap();
        let mut response = Response::builder()
            .status(StatusCode::OK)
            .header("Content-Type", "application/json")
            .header("Date", chrono::Utc::now().to_rfc2822()) // This helps handle CORS issues
            .body(Body::from(body))
            .unwrap();
            
        // Add session cookie to response
        let mut cookie = Cookie::new("session_id", &session_token);
        cookie.set_path("/");
        cookie.set_http_only(true);
        // Add session cookie to response
        let headers = response.headers_mut();
        headers.append(
            http::header::SET_COOKIE,
            format!("{}", cookie).parse().unwrap()
        );

        response
    } else {
        (
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "Invalid credentials".to_string(),
            }),
        ).into_response()
    }
}

async fn logout(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let session_id = extract_session_id(&headers).await;
    
    match session_id {
        Some(token) => {
            let mut sessions = state.sessions.lock().unwrap();
            sessions.remove(&token);
            (StatusCode::OK, Json(serde_json::json!({}))).into_response()
        },
        None => auth_required_response().await,
    }
}

async fn get_current_user(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let session_id = extract_session_id(&headers).await;
    
    match session_id {
        Some(token) => {
            if let Some(user) = state.get_user_by_session(&token) {
                (StatusCode::OK, Json(user)).into_response()
            } else {
                auth_required_response().await
            }
        },
        None => auth_required_response().await,
    }
}

async fn update_password(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<UpdatePasswordRequest>,
) -> Response {
    let session_id = extract_session_id(&headers).await;
    
    match session_id {
        Some(token) => {
            if let Some(user) = state.get_user_by_session(&token) {
                // Verify old password
                let passwords = state.passwords.lock().unwrap();
                if let Some(stored_password) = passwords.get(&user.id) {
                    if stored_password != &req.old_password {
                        return (
                            StatusCode::UNAUTHORIZED,
                            Json(ErrorResponse {
                                error: "Invalid credentials".to_string(),
                            }),
                        ).into_response();
                    }
                } else {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ErrorResponse {
                            error: "Server error".to_string(),
                        }),
                    ).into_response();
                }
                
                drop(passwords); // Release the lock
                
                if req.new_password.len() < 8 {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(ErrorResponse {
                            error: "Password too short".to_string(),
                        }),
                    ).into_response();
                }
                
                // Update the password
                let mut passwords = state.passwords.lock().unwrap();
                passwords.insert(user.id, req.new_password);
                
                (StatusCode::OK, Json(serde_json::json!({}))).into_response()
            } else {
                auth_required_response().await
            }
        },
        None => auth_required_response().await,
    }
}

async fn get_todos(State(state): State<AppState>, headers: HeaderMap) -> Response {
    let session_id = extract_session_id(&headers).await;
    
    match session_id {
        Some(token) => {
            if let Some(user) = state.get_user_by_session(&token) {
                let todos = state.todos.lock().unwrap();
                if let Some(user_todos) = todos.get(&user.id) {
                    let mut todo_list: Vec<Todo> = user_todos.values().cloned().collect();
                    // Order by ID ascending
                    todo_list.sort_by(|a, b| a.id.cmp(&b.id));
                    
                    (StatusCode::OK, Json(todo_list)).into_response()
                } else {
                    (StatusCode::OK, Json(Vec::<Todo>::new())).into_response()
                }
            } else {
                auth_required_response().await
            }
        },
        None => auth_required_response().await,
    }
}

async fn create_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<CreateTodoRequest>,
) -> Response {
    let session_id = extract_session_id(&headers).await;
    
    match session_id {
        Some(token) => {
            if let Some(user) = state.get_user_by_session(&token) {
                if req.title.is_empty() {
                    return (
                        StatusCode::BAD_REQUEST,
                        Json(ErrorResponse {
                            error: "Title is required".to_string(),
                        }),
                    ).into_response();
                }
                
                let mut todo_id_counter = state.todo_id_counter.lock().unwrap();
                *todo_id_counter += 1;
                let todo_id = *todo_id_counter;
                
                let now_time = now();
                let todo = Todo {
                    id: todo_id,
                    title: req.title,
                    description: req.description,
                    completed: false,
                    created_at: now_time,
                    updated_at: now_time,
                };
                
                {
                    let mut todos = state.todos.lock().unwrap();
                    todos.entry(user.id).or_insert(HashMap::new()).insert(todo_id, todo.clone());
                }
                
                (StatusCode::CREATED, Json(todo)).into_response()
            } else {
                auth_required_response().await
            }
        },
        None => auth_required_response().await,
    }
}

async fn get_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(todo_id): Path<u32>,
) -> Response {
    let session_id = extract_session_id(&headers).await;
    
    match session_id {
        Some(token) => {
            if let Some(user) = state.get_user_by_session(&token) {
                let todos = state.todos.lock().unwrap();
                
                if let Some(user_todos) = todos.get(&user.id) {
                    if let Some(todo) = user_todos.get(&todo_id) {
                        (StatusCode::OK, Json(todo.clone())).into_response()
                    } else {
                        (
                            StatusCode::NOT_FOUND,
                            Json(ErrorResponse {
                                error: "Todo not found".to_string(),
                            }),
                        ).into_response()
                    }
                } else {
                    (
                        StatusCode::NOT_FOUND,
                        Json(ErrorResponse {
                            error: "Todo not found".to_string(),
                        }),
                    ).into_response()
                }
            } else {
                auth_required_response().await
            }
        },
        None => auth_required_response().await,
    }
}

async fn update_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(todo_id): Path<u32>,
    Json(req): Json<UpdateTodoRequest>,
) -> Response {
    let session_id = extract_session_id(&headers).await;
    
    match session_id {
        Some(token) => {
            if let Some(user) = state.get_user_by_session(&token) {
                let mut todos = state.todos.lock().unwrap();
                
                if let Some(user_todos) = todos.get_mut(&user.id) {
                    if let Some(mut todo) = user_todos.get(&todo_id).cloned() {
                        // Validate title if present
                        if let Some(ref title) = req.title {
                            if title.is_empty() {
                                return (
                                    StatusCode::BAD_REQUEST,
                                    Json(ErrorResponse {
                                        error: "Title is required".to_string(),
                                    }),
                                ).into_response();
                            }
                        }
                        
                        // Update the fields based on what was provided
                        if let Some(title) = req.title {
                            todo.title = title;
                        }
                        if let Some(description) = req.description {
                            todo.description = description;
                        }
                        if let Some(completed) = req.completed {
                            todo.completed = completed;
                        }
                        
                        todo.updated_at = now(); // Update the timestamp
                        
                        // Put the updated todo back
                        user_todos.insert(todo_id, todo.clone());
                        
                        (StatusCode::OK, Json(todo)).into_response()
                    } else {
                        (
                            StatusCode::NOT_FOUND,
                            Json(ErrorResponse {
                                error: "Todo not found".to_string(),
                            }),
                        ).into_response()
                    }
                } else {
                    (
                        StatusCode::NOT_FOUND,
                        Json(ErrorResponse {
                            error: "Todo not found".to_string(),
                        }),
                    ).into_response()
                }
            } else {
                auth_required_response().await
            }
        },
        None => auth_required_response().await,
    }
}

async fn delete_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(todo_id): Path<u32>,
) -> Response {
    let session_id = extract_session_id(&headers).await;
    
    match session_id {
        Some(token) => {
            if let Some(user) = state.get_user_by_session(&token) {
                let mut todos = state.todos.lock().unwrap();
                
                if let Some(user_todos) = todos.get_mut(&user.id) {
                    if user_todos.contains_key(&todo_id) {
                        user_todos.remove(&todo_id);
                        // Return 204 No Content with empty response
                        Response::builder()
                            .status(StatusCode::NO_CONTENT)
                            .body(Body::empty())
                            .unwrap()
                    } else {
                        (
                            StatusCode::NOT_FOUND,
                            Json(ErrorResponse {
                                error: "Todo not found".to_string(),
                            }),
                        ).into_response()
                    }
                } else {
                    (
                        StatusCode::NOT_FOUND,
                        Json(ErrorResponse {
                            error: "Todo not found".to_string(),
                        }),
                    ).into_response()
                }
            } else {
                auth_required_response().await
            }
        },
        None => auth_required_response().await,
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    
    let port = if let Some(port_arg) = args.iter().position(|arg| arg == "--port") {
        args[port_arg + 1].parse::<u16>().expect("--port value must be a number")
    } else {
        8000
    };
    
    let state = AppState::new();
    
    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(get_current_user))
        .route("/password", put(update_password))
        .route("/todos", get(get_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))  // This is the correct format
        .with_state(state)
        // Enable CORS for easier testing
        .layer(tower_http::cors::CorsLayer::permissive());

    let addr: std::net::SocketAddr = format!("0.0.0.0:{}", port).parse().unwrap();

    println!("Server running on {}", addr);

    axum::serve(
        tokio::net::TcpListener::bind(addr).await.unwrap(),
        app.into_make_service()
    )
    .await
    .unwrap();
}