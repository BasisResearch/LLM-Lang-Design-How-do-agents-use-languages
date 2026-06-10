use axum::{
    extract::{Path, State, Json},
    http::{header::SET_COOKIE, StatusCode, HeaderMap},
    routing::{get, post, put, delete},
    Router,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::{Arc, RwLock}};
use uuid::Uuid;
use argon2::{
    password_hash::{
        rand_core::OsRng,
        PasswordHash, PasswordHasher, PasswordVerifier, SaltString
    },
    Argon2
};

struct AppState {
    users: RwLock<HashMap<u32, User>>,
    next_user_id: RwLock<u32>,
    sessions: RwLock<HashMap<String, u32>>,
    todos: RwLock<HashMap<u32, Todo>>,
    next_todo_id: RwLock<u32>,
}

#[derive(Clone, Serialize, Deserialize)]
struct User {
    id: u32,
    username: String,
    password_hash: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct UserResponse {
    id: u32,
    username: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Todo {
    id: u32,
    #[serde(skip)]
    user_id: u32,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Serialize)]
struct ErrorResponse {
    error: String,
}

fn bad_request_error(error: &str) -> (StatusCode, Json<ErrorResponse>) {
    (StatusCode::BAD_REQUEST, Json(ErrorResponse { error: error.to_string() }))
}

fn unauthorized_error(error: &str) -> (StatusCode, Json<ErrorResponse>) {
    (StatusCode::UNAUTHORIZED, Json(ErrorResponse { error: error.to_string() }))
}

fn not_found_error(error: &str) -> (StatusCode, Json<ErrorResponse>) {
    (StatusCode::NOT_FOUND, Json(ErrorResponse { error: error.to_string() }))
}

fn conflict_error(error: &str) -> (StatusCode, Json<ErrorResponse>) {
    (StatusCode::CONFLICT, Json(ErrorResponse { error: error.to_string() }))
}

fn get_current_user(state: &Arc<AppState>, headers: &HeaderMap) -> Option<User> {
    let cookie = headers.get("cookie")
        .and_then(|c| c.to_str().ok())
        .and_then(|c| c.split(';').find_map(|part| {
            let part = part.trim();
            if part.starts_with("session_id=") {
                Some(part["session_id=".len()..].to_string())
            } else {
                None
            }
        }));

    if let Some(session_id) = cookie {
        let sessions = state.sessions.read().unwrap();
        if let Some(&user_id) = sessions.get(&session_id) {
            let users = state.users.read().unwrap();
            if let Some(user) = users.get(&user_id) {
                return Some(user.clone());
            }
        }
    }
    None
}

fn get_current_time() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn register(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegisterRequest>,
) -> Result<(StatusCode, Json<UserResponse>), (StatusCode, Json<ErrorResponse>)> {
    let username = req.username.ok_or_else(|| bad_request_error("Invalid username"))?;
    let password = req.password.ok_or_else(|| bad_request_error("Password too short"))?;

    if username.len() < 3 || username.len() > 50 || !username.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err(bad_request_error("Invalid username"));
    }

    if password.len() < 8 {
        return Err(bad_request_error("Password too short"));
    }

    {
        let users = state.users.read().unwrap();
        for user in users.values() {
            if user.username == username {
                return Err(conflict_error("Username already exists"));
            }
        }
    }

    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    let password_hash = argon2.hash_password(password.as_bytes(), &salt)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { error: "Internal server error".to_string() })))?
        .to_string();

    let mut users = state.users.write().unwrap();
    let mut next_user_id = state.next_user_id.write().unwrap();

    for user in users.values() {
        if user.username == username {
            return Err(conflict_error("Username already exists"));
        }
    }

    let user_id = *next_user_id;
    *next_user_id += 1;

    let user = User {
        id: user_id,
        username: username.clone(),
        password_hash,
    };

    users.insert(user_id, user.clone());

    Ok((StatusCode::CREATED, Json(UserResponse { id: user_id, username })))
}

#[derive(Deserialize)]
struct LoginRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn login(
    State(state): State<Arc<AppState>>,
    Json(req): Json<LoginRequest>,
) -> Result<(StatusCode, HeaderMap, Json<UserResponse>), (StatusCode, Json<ErrorResponse>)> {
    let username = req.username.ok_or_else(|| unauthorized_error("Invalid credentials"))?;
    let password = req.password.ok_or_else(|| unauthorized_error("Invalid credentials"))?;

    let user_opt = {
        let users = state.users.read().unwrap();
        users.values().find(|u| u.username == username).cloned()
    };

    if let Some(user) = user_opt {
        let parsed_hash = PasswordHash::new(&user.password_hash)
            .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { error: "Internal server error".to_string() })))?;
        let argon2 = Argon2::default();
        if argon2.verify_password(password.as_bytes(), &parsed_hash).is_ok() {
            let session_id = Uuid::new_v4().to_string();
            
            state.sessions.write().unwrap().insert(session_id.clone(), user.id);

            let mut headers = HeaderMap::new();
            headers.insert(
                SET_COOKIE,
                format!("session_id={}; Path=/; HttpOnly", session_id).parse().unwrap(),
            );

            return Ok((StatusCode::OK, headers, Json(UserResponse { id: user.id, username: user.username })));
        }
    }

    Err(unauthorized_error("Invalid credentials"))
}

async fn logout(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ErrorResponse>)> {
    let _user = get_current_user(&state, &headers).ok_or_else(|| unauthorized_error("Authentication required"))?;
    
    let cookie = headers.get("cookie")
        .and_then(|c| c.to_str().ok())
        .and_then(|c| c.split(';').find_map(|part| {
            let part = part.trim();
            if part.starts_with("session_id=") {
                Some(part["session_id=".len()..].to_string())
            } else {
                None
            }
        }));

    if let Some(session_id) = cookie {
        state.sessions.write().unwrap().remove(&session_id);
    }

    Ok(Json(serde_json::json!({})))
}

async fn me(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<UserResponse>, (StatusCode, Json<ErrorResponse>)> {
    let user = get_current_user(&state, &headers).ok_or_else(|| unauthorized_error("Authentication required"))?;
    Ok(Json(UserResponse { id: user.id, username: user.username }))
}

#[derive(Deserialize)]
struct PasswordRequest {
    old_password: Option<String>,
    new_password: Option<String>,
}

async fn update_password(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<PasswordRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<ErrorResponse>)> {
    let user = get_current_user(&state, &headers).ok_or_else(|| unauthorized_error("Authentication required"))?;
    
    let old_password = req.old_password.ok_or_else(|| unauthorized_error("Invalid credentials"))?;
    let new_password = req.new_password.ok_or_else(|| bad_request_error("Password too short"))?;

    if new_password.len() < 8 {
        return Err(bad_request_error("Password too short"));
    }

    let parsed_hash = PasswordHash::new(&user.password_hash)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { error: "Internal server error".to_string() })))?;
    let argon2 = Argon2::default();
    
    if argon2.verify_password(old_password.as_bytes(), &parsed_hash).is_err() {
        return Err(unauthorized_error("Invalid credentials"));
    }

    let salt = SaltString::generate(&mut OsRng);
    let new_password_hash = argon2.hash_password(new_password.as_bytes(), &salt)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(ErrorResponse { error: "Internal server error".to_string() })))?
        .to_string();

    let mut users = state.users.write().unwrap();
    if let Some(u) = users.get_mut(&user.id) {
        u.password_hash = new_password_hash;
    }

    Ok(Json(serde_json::json!({})))
}

async fn list_todos(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Vec<Todo>>, (StatusCode, Json<ErrorResponse>)> {
    let user = get_current_user(&state, &headers).ok_or_else(|| unauthorized_error("Authentication required"))?;
    
    let todos = state.todos.read().unwrap();
    let mut user_todos: Vec<Todo> = todos.values()
        .filter(|t| t.user_id == user.id)
        .cloned()
        .collect();
    user_todos.sort_by_key(|t| t.id);
    Ok(Json(user_todos))
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
) -> Result<(StatusCode, Json<Todo>), (StatusCode, Json<ErrorResponse>)> {
    let user = get_current_user(&state, &headers).ok_or_else(|| unauthorized_error("Authentication required"))?;

    let title = req.title.ok_or_else(|| bad_request_error("Title is required"))?;
    if title.is_empty() {
        return Err(bad_request_error("Title is required"));
    }

    let description = req.description.unwrap_or_default();
    let now = get_current_time();

    let mut todos = state.todos.write().unwrap();
    let mut next_todo_id = state.next_todo_id.write().unwrap();

    let todo_id = *next_todo_id;
    *next_todo_id += 1;

    let todo = Todo {
        id: todo_id,
        user_id: user.id,
        title,
        description,
        completed: false,
        created_at: now.clone(),
        updated_at: now,
    };

    todos.insert(todo_id, todo.clone());

    Ok((StatusCode::CREATED, Json(todo)))
}

async fn get_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(todo_id_str): Path<String>,
) -> Result<Json<Todo>, (StatusCode, Json<ErrorResponse>)> {
    let user = get_current_user(&state, &headers).ok_or_else(|| unauthorized_error("Authentication required"))?;
    
    let todo_id: u32 = todo_id_str.parse().map_err(|_| not_found_error("Todo not found"))?;
    let todos = state.todos.read().unwrap();
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id == user.id {
            return Ok(Json(todo.clone()));
        }
    }
    Err(not_found_error("Todo not found"))
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
    Path(todo_id_str): Path<String>,
    Json(req): Json<UpdateTodoRequest>,
) -> Result<Json<Todo>, (StatusCode, Json<ErrorResponse>)> {
    let user = get_current_user(&state, &headers).ok_or_else(|| unauthorized_error("Authentication required"))?;
    
    let todo_id: u32 = todo_id_str.parse().map_err(|_| not_found_error("Todo not found"))?;
    let mut todos = state.todos.write().unwrap();
    if let Some(todo) = todos.get_mut(&todo_id) {
        if todo.user_id == user.id {
            if let Some(title) = req.title {
                if title.is_empty() {
                    return Err(bad_request_error("Title is required"));
                }
                todo.title = title;
            }
            if let Some(description) = req.description {
                todo.description = description;
            }
            if let Some(completed) = req.completed {
                todo.completed = completed;
            }
            todo.updated_at = get_current_time();
            return Ok(Json(todo.clone()));
        }
    }
    Err(not_found_error("Todo not found"))
}

async fn delete_todo(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(todo_id_str): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    let user = get_current_user(&state, &headers).ok_or_else(|| unauthorized_error("Authentication required"))?;
    
    let todo_id: u32 = todo_id_str.parse().map_err(|_| not_found_error("Todo not found"))?;
    let mut todos = state.todos.write().unwrap();
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id == user.id {
            todos.remove(&todo_id);
            return Ok(StatusCode::NO_CONTENT);
        }
    }
    Err(not_found_error("Todo not found"))
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

    let state = Arc::new(AppState {
        users: RwLock::new(HashMap::new()),
        next_user_id: RwLock::new(1),
        sessions: RwLock::new(HashMap::new()),
        todos: RwLock::new(HashMap::new()),
        next_todo_id: RwLock::new(1),
    });

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(update_password))
        .route("/todos", get(list_todos))
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
