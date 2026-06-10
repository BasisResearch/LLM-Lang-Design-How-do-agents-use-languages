use axum::{
    extract::{Path, State},
    http::{header::SET_COOKIE, HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post, put, delete},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::signal;
use uuid::Uuid;
use chrono::{DateTime, Utc};
use regex::Regex;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct User {
    id: u32,
    username: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Todo {
    id: u32,
    title: String,
    description: String,
    completed: bool,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: String,
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
struct ChangePasswordRequest {
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

struct UserData {
    user: User,
    password_hash: String,  // In production, we'd use proper hashing
    session_tokens: HashMap<String, ()>,
    todos: HashMap<u32, Todo>,
    next_todo_id: u32,
}

struct AppState {
    users: Arc<Mutex<HashMap<String, UserData>>>,  // Map username -> UserData
    session_to_user: Arc<Mutex<HashMap<String, String>>>,  // Map session_token -> username
    next_user_id: Arc<Mutex<u32>>,
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    
    let mut port = 8000; // default port
    
    for i in 0..args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse::<u16>().expect("Port must be a valid number");
            break;
        }
    }

    let state = Arc::new(AppState {
        users: Arc::new(Mutex::new(HashMap::new())),
        session_to_user: Arc::new(Mutex::new(HashMap::new())),
        next_user_id: Arc::new(Mutex::new(1)),
    });

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(get_todos).post(create_todo))
        .route("/todos/:id", get(get_todo_by_id).put(update_todo).delete(delete_todo))
        .with_state(state);

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port))
        .await
        .unwrap();

    println!("Server running on http://0.0.0.0:{}", port);

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install signal handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}

fn validate_username(username: &str) -> Result<(), String> {
    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    if username.len() < 3 || username.len() > 50 {
        return Err("Invalid username".to_string());
    }
    if !re.is_match(username) {
        return Err("Invalid username".to_string());
    }
    Ok(())
}

fn validate_password(password: &str) -> Result<(), String> {
    if password.len() < 8 {
        return Err("Password too short".to_string());
    }
    Ok(())
}

async fn register(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<RegisterRequest>,
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    validate_username(&payload.username).map_err(|msg| {
        (
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse { error: msg }),
        )
    })?;
    
    validate_password(&payload.password).map_err(|msg| {
        (
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse { error: msg }),
        )
    })?;

    let mut users = state.users.lock().unwrap();
    
    if users.contains_key(&payload.username) {
        return Err((
            StatusCode::CONFLICT,
            Json(ErrorResponse {
                error: "Username already exists".to_string(),
            }),
        ));
    }

    let user_id = {
        let mut next_id = state.next_user_id.lock().unwrap();
        let id = *next_id;
        *next_id += 1;
        id
    };

    // Keep username around after move by cloning it 
    let username_clone = payload.username.clone();

    let user = User {
        id: user_id,
        username: username_clone.clone(),
    };
    
    let user_data = UserData {
        user,
        password_hash: payload.password, // In real app, this would be hashed
        session_tokens: HashMap::new(),
        todos: HashMap::new(),
        next_todo_id: 1,
    };

    users.insert(payload.username, user_data);

    let response = User {
        id: user_id,
        username: username_clone,
    };

    Ok((StatusCode::CREATED, Json(response)))
}

async fn login(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<LoginRequest>,
) -> impl IntoResponse {
    let users = state.users.lock().unwrap();
    
    match users.get(&payload.username) {
        Some(user_data) => {
            if user_data.password_hash != payload.password {
                return (
                    StatusCode::UNAUTHORIZED,
                    Json(ErrorResponse {
                        error: "Invalid credentials".to_string(),
                    })
                ).into_response();
            }
            
            // Generate a session token
            let session_token = Uuid::new_v4().to_string();
            
            // Get a copy of the user before dropping the lock
            let user = user_data.user.clone();
            
            drop(users);  // Release the lock
            
            // Add the session token to both places
            {
                let mut users = state.users.lock().unwrap();
                if let Some(mut_user_data) = users.get_mut(&payload.username) {
                    mut_user_data.session_tokens.insert(session_token.clone(), ());
                } else {
                    return (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ErrorResponse {
                            error: "Error updating sessions".to_string(),
                        })
                    ).into_response();
                }
            }
            
            {
                let mut session_to_user = state.session_to_user.lock().unwrap();
                session_to_user.insert(session_token.clone(), payload.username.clone());
            }
            
            let mut response = (StatusCode::OK, Json(user)).into_response();
            let cookie_value = format!("session_id={}; Path=/; HttpOnly", session_token);
            response.headers_mut().insert(SET_COOKIE, cookie_value.parse().unwrap());
            
            response
        }
        None => (
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "Invalid credentials".to_string(),
            })
        ).into_response(),
    }
}

async fn logout(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    let cookie_header = headers.get("cookie")
        .ok_or_else(|| {
            (
                StatusCode::UNAUTHORIZED,
                Json(ErrorResponse {
                    error: "Authentication required".to_string(),
                }),
            )
        })?
        .to_str()
        .map_err(|_| {
            (
                StatusCode::UNAUTHORIZED,
                Json(ErrorResponse {
                    error: "Authentication required".to_string(),
                }),
            )
        })?;
    
    let session_token = extract_session_token(cookie_header).ok_or_else(|| {
        (
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "Authentication required".to_string(),
            }),
        )
    })?;
    
    {
        let mut session_to_user = state.session_to_user.lock().unwrap();
        match session_to_user.remove(&session_token) {
            Some(username) => {
                let mut users = state.users.lock().unwrap();
                if let Some(mut_user_data) = users.get_mut(&username) {
                    mut_user_data.session_tokens.remove(&session_token);
                }
            }
            None => {
                return Err((
                    StatusCode::UNAUTHORIZED,
                    Json(ErrorResponse {
                        error: "Authentication required".to_string(),
                    }),
                ));
            }
        }
    }
    
    Ok((StatusCode::OK, Json(serde_json::Value::Object(serde_json::Map::new()))))
}

fn extract_session_token(cookie_header: &str) -> Option<String> {
    for cookie in cookie_header.split(';') {
        let cookie = cookie.trim();
        if cookie.starts_with("session_id=") {
            return Some(cookie[11..].to_string());
        }
    }
    None
}

async fn get_authenticated_user(
    headers: &HeaderMap,
    state: &Arc<AppState>,
) -> Result<User, (StatusCode, Json<ErrorResponse>)> {
    let cookie_header = headers.get("cookie")
        .ok_or_else(|| {
            (
                StatusCode::UNAUTHORIZED,
                Json(ErrorResponse {
                    error: "Authentication required".to_string(),
                }),
            )
        })?
        .to_str()
        .map_err(|_| {
            (
                StatusCode::UNAUTHORIZED,
                Json(ErrorResponse {
                    error: "Authentication required".to_string(),
                }),
            )
        })?;
    
    let session_token = extract_session_token(cookie_header).ok_or_else(|| {
        (
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "Authentication required".to_string(),
            }),
        )
    })?;
    
    let session_to_user = state.session_to_user.lock().unwrap();
    let username = session_to_user.get(&session_token).cloned().ok_or_else(|| {
        (
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "Authentication required".to_string(),
            }),
        )
    })?;
    
    let users = state.users.lock().unwrap();
    let user_data = users.get(&username).ok_or_else(|| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: "Authentication issue".to_string(),
            }),
        )
    })?;
    
    Ok(user_data.user.clone())
}

async fn me(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    let user = get_authenticated_user(&headers, &state).await?;
    Ok((StatusCode::OK, Json(user)))
}

async fn change_password(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<ChangePasswordRequest>,
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    let username = {
        let cookie_header = headers.get("cookie")
            .ok_or_else(|| {
                (
                    StatusCode::UNAUTHORIZED,
                    Json(ErrorResponse {
                        error: "Authentication required".to_string(),
                    }),
                )
            })?
            .to_str()
            .map_err(|_| {
                (
                    StatusCode::UNAUTHORIZED,
                    Json(ErrorResponse {
                        error: "Authentication required".to_string(),
                    }),
                )
            })?;
        
        let session_token = extract_session_token(cookie_header).ok_or_else(|| {
            (
                StatusCode::UNAUTHORIZED,
                Json(ErrorResponse {
                    error: "Authentication required".to_string(),
                }),
            )
        })?;
        
        let session_to_user = state.session_to_user.lock().unwrap();
        session_to_user.get(&session_token).ok_or_else(|| {
            (
                StatusCode::UNAUTHORIZED,
                Json(ErrorResponse {
                    error: "Authentication required".to_string(),
                }),
            )
        })?.clone()
    };
    
    let users = state.users.lock().unwrap();
    let user_data = users.get(&username).ok_or_else(|| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: "Authentication issue".to_string(),
            }),
        )
    })?;
    
    if user_data.password_hash != payload.old_password {
        return Err((
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "Invalid credentials".to_string(),
            }),
        ));
    }
    
    drop(users);  // Release lock
    
    if payload.new_password.len() < 8 {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                error: "Password too short".to_string(),
            }),
        ));
    }
    
    {
        let mut users = state.users.lock().unwrap();
        if let Some(mut_user_data) = users.get_mut(&username) {
            mut_user_data.password_hash = payload.new_password;
        } else {
            return Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrorResponse {
                    error: "User was not found during password update".to_string(),
                }),
            ));
        }
    }
    
    Ok((StatusCode::OK, Json(serde_json::Value::Object(serde_json::Map::new()))))
}

async fn get_todos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    let user = get_authenticated_user(&headers, &state).await?;
    
    let users = state.users.lock().unwrap();
    let user_data = users.get(&user.username).ok_or_else(|| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: "Authentication issue".to_string(),
            }),
        )
    })?;
    
    let mut todos: Vec<Todo> = user_data.todos.values().cloned().collect();
    todos.sort_by(|a, b| a.id.cmp(&b.id));  // Sort by ID ascending
    
    Ok((StatusCode::OK, Json(todos)))
}

async fn create_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<CreateTodoRequest>,
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    if payload.title.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                error: "Title is required".to_string(),
            }),
        ));
    }
    
    let user = get_authenticated_user(&headers, &state).await?;
    
    let now = Utc::now();
    let todo = Todo {
        id: 0, // Will be assigned when inserting
        title: payload.title,
        description: payload.description.unwrap_or_default(),
        completed: false,
        created_at: now,
        updated_at: now,
    };
    
    {
        let mut users = state.users.lock().unwrap();
        if let Some(mut_user_data) = users.get_mut(&user.username) {
            let todo_id = mut_user_data.next_todo_id;
            mut_user_data.next_todo_id += 1;
            
            let mut todo = todo;
            todo.id = todo_id;
            
            mut_user_data.todos.insert(todo_id, todo.clone());
            
            Ok((StatusCode::CREATED, Json(todo)))
        } else {
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrorResponse {
                    error: "User not found during todo creation".to_string(),
                }),
            ))
        }
    }
}

async fn get_todo_by_id(
    Path(id): Path<u32>,
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    let user = get_authenticated_user(&headers, &state).await?;
    
    let users = state.users.lock().unwrap();
    let user_data = users.get(&user.username).ok_or_else(|| {
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: "Authentication issue".to_string(),
            }),
        )
    })?;
    
    match user_data.todos.get(&id) {
        Some(todo) => Ok((StatusCode::OK, Json(todo.clone()))),
        None => Err((
            StatusCode::NOT_FOUND,
            Json(ErrorResponse {
                error: "Todo not found".to_string(),
            }),
        )),
    }
}

async fn update_todo(
    Path(id): Path<u32>,
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<UpdateTodoRequest>,
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    // Validate if title exists and is empty
    if let Some(title) = &payload.title {
        if title.is_empty() {
            return Err((
                StatusCode::BAD_REQUEST,
                Json(ErrorResponse {
                    error: "Title is required".to_string(),
                }),
            ));
        }
    }
    
    let user = get_authenticated_user(&headers, &state).await?;
    
    {
        let mut users = state.users.lock().unwrap();
        let user_data = users.get_mut(&user.username).ok_or_else(|| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrorResponse {
                    error: "Authentication issue".to_string(),
                }),
            )
        })?;
        
        let todo = user_data.todos.get_mut(&id).ok_or_else(|| {
            (
                StatusCode::NOT_FOUND,
                Json(ErrorResponse {
                    error: "Todo not found".to_string(),
                }),
            )
        })?;
        
        if let Some(title) = payload.title {
            todo.title = title;
        }
        
        if let Some(description) = payload.description {
            todo.description = description;
        }
        
        if let Some(completed) = payload.completed {
            todo.completed = completed;
        }
        
        todo.updated_at = Utc::now();
        
        Ok((StatusCode::OK, Json(todo.clone())))
    }
}

async fn delete_todo(
    Path(id): Path<u32>,
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    let user = get_authenticated_user(&headers, &state).await?;
    
    {
        let mut users = state.users.lock().unwrap();
        let user_data = users.get_mut(&user.username).ok_or_else(|| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(ErrorResponse {
                    error: "Authentication issue".to_string(),
                }),
            )
        })?;
        
        if !user_data.todos.contains_key(&id) {
            return Err((
                StatusCode::NOT_FOUND,
                Json(ErrorResponse {
                    error: "Todo not found".to_string(),
                }),
            ));
        }
        
        user_data.todos.remove(&id);
        
        Ok(StatusCode::NO_CONTENT)
    }
}