use axum::{
    extract::{Path, State},
    http::{HeaderMap, HeaderName, HeaderValue, StatusCode},
    response::IntoResponse,
    routing::*,
    Router, Json,
};
use chrono::{prelude::*, Utc};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, RwLock},
};
use uuid::Uuid;

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

#[derive(Serialize, Debug)]
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

#[derive(Clone)]
struct AppState {
    users: Arc<RwLock<HashMap<u32, User>>>,
    passwords: Arc<RwLock<HashMap<u32, String>>>,
    todos: Arc<RwLock<HashMap<u32, Todo>>>,
    user_todos: Arc<RwLock<HashMap<u32, Vec<u32>>>>,
    sessions: Arc<RwLock<HashMap<String, u32>>>,
    next_user_id: Arc<RwLock<u32>>,
    next_todo_id: Arc<RwLock<u32>>,
}

fn get_current_timestamp() -> DateTime<Utc> {
    Utc::now().trunc_subsecs(0) // Truncate to second precision
}

fn find_session_user_id(headers: &HeaderMap, sessions: &HashMap<String, u32>) -> Option<u32> {
    if let Some(cookie_header) = headers.get("cookie") {
        if let Ok(cookie_str) = cookie_header.to_str() {
            for cookie in cookie_str.split(';') {
                let trimed_cookie = cookie.trim();
                if let Some(pos) = trimed_cookie.find('=') {
                    let (key, value) = trimed_cookie.split_at(pos);
                    if key.trim() == "session_id" {
                        let session_id = value[1..].trim(); // Skip '=' character and strip whitespace
                        return sessions.get(session_id).copied();
                    }
                }
            }
        }
    }
    None
}

async fn register(
    State(state): State<AppState>, 
    Json(payload): Json<RegisterRequest>
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    // Validate username
    if payload.username.len() < 3 || payload.username.len() > 50 {
        return Err((StatusCode::BAD_REQUEST, Json(ErrorResponse { 
            error: "Invalid username".to_string() 
        })));
    }

    // Check if username contains only alphanumeric and underscores
    if !payload.username.chars().all(|c| c.is_alphanumeric() || c == '_') {
        return Err((StatusCode::BAD_REQUEST, Json(ErrorResponse { 
            error: "Invalid username".to_string() 
        })));
    }

    // Validate password
    if payload.password.len() < 8 {
        return Err((StatusCode::BAD_REQUEST, Json(ErrorResponse { 
            error: "Password too short".to_string() 
        })));
    }

    // Check if username already exists
    let users_read = state.users.read().map_err(|_| {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        }))
    })?;
    
    for user in users_read.values() {
        if user.username == payload.username {
            drop(users_read);
            return Err((StatusCode::CONFLICT, Json(ErrorResponse { 
                error: "Username already exists".to_string() 
            })));
        }
    }
    drop(users_read);

    let mut next_id = state.next_user_id.write().map_err(|_| {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        }))
    })?;
    *next_id += 1;
    let user_id = *next_id;
    drop(next_id);

    let user = User {
        id: user_id,
        username: payload.username.clone(),
    };

    {
        let mut users = state.users.write().map_err(|_| {
            (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                error: "Internal server error".to_string() 
            }))
        })?;
        let mut passwords = state.passwords.write().map_err(|_| {
            (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                error: "Internal server error".to_string() 
            }))
        })?;
        users.insert(user_id, user.clone());
        passwords.insert(user_id, payload.password);
    }

    // Initialize user's todo list
    {
        let mut user_todos = state.user_todos.write().map_err(|_| {
            (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                error: "Internal server error".to_string() 
            }))
        })?;
        user_todos.insert(user_id, vec![]);
    }

    Ok((
        StatusCode::CREATED,
        [(HeaderName::from_static("content-type"), HeaderValue::from_static("application/json"))],
        Json(User { id: user.id, username: user.username }),
    ))
}

async fn login(
    State(state): State<AppState>, 
    Json(payload): Json<LoginRequest>
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    let users = state.users.read().map_err(|_| {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        }))
    })?;
    
    let passwords = state.passwords.read().map_err(|_| {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        }))
    })?;

    // Find the user with the given username
    let mut user_id = None;
    for (&id, user) in users.iter() {
        if user.username == payload.username {
            if let Some(stored_password) = passwords.get(&id) {
                if stored_password == &payload.password {
                    user_id = Some(id);
                    break;
                }
            }
        }
    }

    let user_id = user_id.ok_or_else(|| (StatusCode::UNAUTHORIZED, Json(ErrorResponse { 
        error: "Invalid credentials".to_string() 
    })))?;
    
    let user = users.get(&user_id).cloned().ok_or_else(|| {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        }))
    })?;
    
    drop(users);
    drop(passwords);

    // Generate a new session ID
    let session_id = Uuid::new_v4().to_string();

    {
        let mut sessions = state.sessions.write().map_err(|_| {
            (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                error: "Internal server error".to_string() 
            }))
        })?;
        sessions.insert(session_id.clone(), user_id);
    }

    // Create response with Set-Cookie header
    Ok((
        StatusCode::OK,
        [
            (HeaderName::from_static("set-cookie"), HeaderValue::from_str(&format!("session_id={}; Path=/; HttpOnly", session_id)).unwrap()),
            (HeaderName::from_static("content-type"), HeaderValue::from_static("application/json")),
        ],
        Json(serde_json::json!({"id": user.id, "username": user.username})),
    ))
}

async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, (StatusCode, Json<ErrorResponse>)> {
    // Extract session_id from cookies  
    if let Some(cookie_header) = headers.get("cookie") {
        if let Ok(cookie_str) = cookie_header.to_str() {
            for cookie in cookie_str.split(';') {
                let parts: Vec<&str> = cookie.trim().split('=').collect();
                if parts.len() == 2 && parts[0].trim() == "session_id" {
                    let session_id = parts[1].trim();
                    
                    let mut sessions = state.sessions.write().map_err(|_| {
                        (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                            error: "Internal server error".to_string() 
                        }))
                    })?;
                    sessions.remove(session_id);
                    break;
                }
            }
        }
    }
    
    Ok((
        StatusCode::OK,
        [(HeaderName::from_static("content-type"), HeaderValue::from_static("application/json"))],
        Json(serde_json::json!({})),
    ))
}

async fn validate_authentication(
    headers: &HeaderMap,
    state: &AppState
) -> Result<u32, (StatusCode, Json<ErrorResponse>)> {
    let sessions = state.sessions.read().map_err(|_| {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        }))
    })?;

    match find_session_user_id(headers, &*sessions) {
        Some(user_id) => Ok(user_id),
        None => Err((StatusCode::UNAUTHORIZED, Json(ErrorResponse { 
            error: "Authentication required".to_string() 
        }))),
    }
}

async fn get_me(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    // Check authentication
    let user_id_res = validate_authentication(&headers, &state).await;
    let user_id = match user_id_res {
        Ok(uid) => uid,
        Err(err_resp) => return err_resp,
    };

    match state.users.read() {
        Ok(users) => {
            match users.get(&user_id) {
                Some(user) => (
                    StatusCode::OK,
                    [(HeaderName::from_static("content-type"), HeaderValue::from_static("application/json"))],
                    Json(User { id: user.id, username: user.username.clone() }),
                ),
                None => (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                    error: "User not found".to_string() 
                })),
            }
        },
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    }
}

async fn change_password(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ChangePasswordRequest>
) -> impl IntoResponse {
    // Check authentication
    let user_id_res = validate_authentication(&headers, &state).await;
    let user_id = match user_id_res {
        Ok(uid) => uid,
        Err(err_resp) => return err_resp,
    };

    // Validate new password length
    if payload.new_password.len() < 8 {
        return (StatusCode::BAD_REQUEST, Json(ErrorResponse { 
            error: "Password too short".to_string() 
        }));
    }

    // Verify old password
    let passwords_read_res = state.passwords.read();
    let passwords_read = match passwords_read_res {
        Ok(passwords) => passwords,
        Err(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                error: "Internal server error".to_string() 
            }));
        }
    };
    
    let stored_password = match passwords_read.get(&user_id) {
        Some(password) => password,
        None => {
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                error: "User not found".to_string() 
            }));
        }
    };
    
    if stored_password != &payload.old_password {
        return (StatusCode::UNAUTHORIZED, Json(ErrorResponse { 
            error: "Invalid credentials".to_string() 
        }));
    }

    drop(passwords_read);

    // Update the password
    let passwords_write_res = state.passwords.write();
    let mut passwords_write = match passwords_write_res {
        Ok(passwords) => passwords,
        Err(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                error: "Internal server error".to_string() 
            }));
        }
    };
    passwords_write.insert(user_id, payload.new_password);

    (
        StatusCode::OK,
        [(HeaderName::from_static("content-type"), HeaderValue::from_static("application/json"))],
        Json(serde_json::json!({})),
    )
}

async fn get_todos(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    // Check authentication
    let user_id_res = validate_authentication(&headers, &state).await;
    let user_id = match user_id_res {
        Ok(uid) => uid,
        Err(err_resp) => return err_resp,
    };

    let todo_ids = match state.user_todos.read() {
        Ok(user_todos) => {
            user_todos.get(&user_id).map(|ids| ids.iter().cloned().collect()).unwrap_or_else(|| vec![])
        },
        Err(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                error: "Internal server error".to_string() 
            }));
        }
    };

    let todos = match state.todos.read() {
        Ok(todos_guard) => {
            let mut user_todos_vec: Vec<Todo> = Vec::new();
            
            // Filter todos to only include those for the current user
            for &todo_id in &todo_ids {
                if let Some(todo) = todos_guard.get(&todo_id) {
                    user_todos_vec.push(todo.clone());
                }
            }
            
            // Sort by ID ascending
            user_todos_vec.sort_by_key(|t| t.id);
            
            user_todos_vec
        },
        Err(_) => {
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
                error: "Internal server error".to_string() 
            }));
        }
    };

    (
        StatusCode::OK,
        [(HeaderName::from_static("content-type"), HeaderValue::from_static("application/json"))],
        Json(todos),
    )
}

async fn create_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<CreateTodoRequest>
) -> impl IntoResponse {
    // Check authentication
    let user_id_res = validate_authentication(&headers, &state).await;
    let user_id = match user_id_res {
        Ok(uid) => uid,
        Err(err_resp) => return err_resp,
    };

    // Validate title
    if payload.title.trim().is_empty() {
        return (StatusCode::BAD_REQUEST, Json(ErrorResponse { 
            error: "Title is required".to_string() 
        }));
    }

    let todo_id = match state.next_todo_id.write() {
        Ok(mut next_id) => {
            *next_id += 1;
            *next_id
        },
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    };

    let timestamp = get_current_timestamp();

    let todo = Todo {
        id: todo_id,
        title: payload.title,
        description: payload.description.unwrap_or_default(),
        completed: false,
        created_at: timestamp,
        updated_at: timestamp,
    };

    // Add todo to the central todos map
    match state.todos.write() {
        Ok(mut todos) => {
            todos.insert(todo_id, todo.clone());
        },
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    }

    // Add the todo ID to the user's todo list
    match state.user_todos.write() {
        Ok(mut user_todos) => {
            if let Some(todo_list) = user_todos.get_mut(&user_id) {
                todo_list.push(todo_id);
            }
        },
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    }

    (
        StatusCode::CREATED,
        [(HeaderName::from_static("content-type"), HeaderValue::from_static("application/json"))],
        Json(todo),
    )
}

async fn get_todo_by_id(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(todo_id): Path<u32>,
) -> impl IntoResponse {
    // Check authentication
    let user_id_res = validate_authentication(&headers, &state).await;
    let user_id = match user_id_res {
        Ok(uid) => uid,
        Err(err_resp) => return err_resp,
    };

    // Verify that the user owns this todo
    let user_has_access = match state.user_todos.read() {
        Ok(user_todos) => {
            user_todos.get(&user_id).map(|todos| todos.contains(&todo_id)).unwrap_or(false)
        },
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    };

    if !user_has_access {
        return (StatusCode::NOT_FOUND, Json(ErrorResponse { 
            error: "Todo not found".to_string() 
        }));
    }

    // Get the todo
    match state.todos.read() {
        Ok(todos) => {
            match todos.get(&todo_id) {
                Some(todo) => (
                    StatusCode::OK,
                    [(HeaderName::from_static("content-type"), HeaderValue::from_static("application/json"))],
                    Json(todo.clone()),
                ),
                None => (StatusCode::NOT_FOUND, Json(ErrorResponse { 
                    error: "Todo not found".to_string() 
                })),
            }
        },
        Err(_) => (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    }
}

async fn update_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(todo_id): Path<u32>,
    Json(payload): Json<UpdateTodoRequest>
) -> impl IntoResponse {
    // Check authentication
    let user_id_res = validate_authentication(&headers, &state).await;
    let user_id = match user_id_res {
        Ok(uid) => uid,
        Err(err_resp) => return err_resp,
    };

    // Verify that the user owns this todo
    let user_has_access = match state.user_todos.read() {
        Ok(user_todos) => {
            user_todos.get(&user_id).map(|todos| todos.contains(&todo_id)).unwrap_or(false)
        },
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    };

    if !user_has_access {
        return (StatusCode::NOT_FOUND, Json(ErrorResponse { 
            error: "Todo not found".to_string() 
        }));
    }

    // Get the existing todo
    let todo = match state.todos.read() {
        Ok(todos_read) => {
            match todos_read.get(&todo_id) {
                Some(todo) => todo.clone(),
                None => return (StatusCode::NOT_FOUND, Json(ErrorResponse { 
                    error: "Todo not found".to_string() 
                })),
            }
        },
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    };

    // Validate title if provided
    if let Some(ref title) = payload.title {
        if title.trim().is_empty() {
            return (StatusCode::BAD_REQUEST, Json(ErrorResponse { 
                error: "Title is required".to_string() 
            }));
        }
    }

    // Create updated todo
    let updated_todo = Todo {
        id: todo.id,
        title: payload.title.unwrap_or_else(|| todo.title.clone()),
        description: payload.description.unwrap_or_else(|| todo.description.clone()),
        completed: payload.completed.unwrap_or(todo.completed),
        created_at: todo.created_at,
        updated_at: get_current_timestamp(),
    };

    // Update the todo
    match state.todos.write() {
        Ok(mut todos) => {
            todos.insert(todo_id, updated_todo.clone());
        },
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    };

    (
        StatusCode::OK,
        [(HeaderName::from_static("content-type"), HeaderValue::from_static("application/json"))],
        Json(updated_todo),
    )
}

async fn delete_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(todo_id): Path<u32>,
) -> impl IntoResponse {
    // Check authentication
    let user_id_res = validate_authentication(&headers, &state).await;
    let user_id = match user_id_res {
        Ok(uid) => uid,
        Err(err_resp) => return err_resp,
    };

    // Verify that the user owns this todo
    let mut user_todos_write = match state.user_todos.write() {
        Ok(guard) => guard,
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    };
    
    let user_has_access = user_todos_write.get(&user_id)
        .map(|todos| todos.contains(&todo_id))
        .unwrap_or(false);

    if !user_has_access {
        drop(user_todos_write);
        return (StatusCode::NOT_FOUND, Json(ErrorResponse { 
            error: "Todo not found".to_string() 
        }));
    }

    // Check if todo exists in central todos
    if !match state.todos.read() {
        Ok(todos_read) => todos_read.contains_key(&todo_id),
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    } {
        return (StatusCode::NOT_FOUND, Json(ErrorResponse { 
            error: "Todo not found".to_string() 
        }));
    }

    // Remove todo from both maps
    match state.todos.write() {
        Ok(mut todos_write) => {
            // Remove from the central todos map
            todos_write.remove(&todo_id);
        },
        Err(_) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { 
            error: "Internal server error".to_string() 
        })),
    };

    // Remove from the user's list
    if let Some(todo_list) = user_todos_write.get_mut(&user_id) {
        todo_list.retain(|&id| id != todo_id);
    }

    // Return 204 No Content without a body
    StatusCode::NO_CONTENT
}

#[tokio::main]
async fn main() {
    use std::env;

    let args: Vec<String> = env::args().collect();
    let port = args.iter().position(|arg| arg == "--port")
        .and_then(|i| args.get(i + 1))
        .unwrap_or(&"8080".to_string())
        .parse()
        .expect("Port must be a valid integer");

    let initial_state = AppState {
        users: Arc::new(RwLock::new(HashMap::new())),
        passwords: Arc::new(RwLock::new(HashMap::new())),
        todos: Arc::new(RwLock::new(HashMap::new())),
        user_todos: Arc::new(RwLock::new(HashMap::new())),
        sessions: Arc::new(RwLock::new(HashMap::new())),
        next_user_id: Arc::new(RwLock::new(0)),
        next_todo_id: Arc::new(RwLock::new(0)),
    };

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(get_me))
        .route("/password", put(change_password))
        .route("/todos", get(get_todos))
        .route("/todos", post(create_todo))
        .route("/todos/:id", get(get_todo_by_id))
        .route("/todos/:id", put(update_todo))
        .route("/todos/:id", delete(delete_todo))
        .with_state(initial_state);

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await.unwrap();
    println!("Server running on port {}", port);
    axum::serve(listener, app).await.unwrap();
}