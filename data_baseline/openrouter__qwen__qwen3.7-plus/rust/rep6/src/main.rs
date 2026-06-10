use std::sync::{Arc, Mutex};
use std::collections::HashMap;
use axum::{
    extract::{Path, State},
    http::{header::SET_COOKIE, HeaderMap, StatusCode},
    response::{IntoResponse, Json},
    routing::{delete, get, post, put},
    Router,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;
use chrono::Utc;
use regex::Regex;
use bcrypt::{hash, verify, DEFAULT_COST};

#[derive(Clone)]
struct AppState {
    users: Arc<Mutex<Vec<User>>>,
    todos: Arc<Mutex<Vec<Todo>>>,
    sessions: Arc<Mutex<HashMap<String, i32>>>,
    next_user_id: Arc<Mutex<i32>>,
    next_todo_id: Arc<Mutex<i32>>,
}

#[derive(Clone)]
struct User {
    id: i32,
    username: String,
    password_hash: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct Todo {
    id: i32,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
    #[serde(skip)]
    user_id: i32,
}

struct UserInfo {
    id: i32,
    username: String,
}

fn hash_password(password: &str) -> String {
    hash(password, DEFAULT_COST).unwrap()
}

fn verify_password(password: &str, hash_str: &str) -> bool {
    verify(password, hash_str).unwrap_or(false)
}

fn get_user_from_headers(
    headers: &HeaderMap,
    state: &AppState,
) -> Result<UserInfo, (StatusCode, Json<serde_json::Value>)> {
    let cookie_header = headers.get("cookie");
    if let Some(cookie) = cookie_header {
        let cookie_str = cookie.to_str().unwrap_or("");
        for c in cookie_str.split(';') {
            let c = c.trim();
            if let Some(session_id) = c.strip_prefix("session_id=") {
                let sessions = state.sessions.lock().unwrap();
                if let Some(&user_id) = sessions.get(session_id) {
                    let users = state.users.lock().unwrap();
                    if let Some(user) = users.iter().find(|u| u.id == user_id) {
                        return Ok(UserInfo {
                            id: user.id,
                            username: user.username.clone(),
                        });
                    }
                }
            }
        }
    }
    Err((
        StatusCode::UNAUTHORIZED,
        Json(json!({"error": "Authentication required"})),
    ))
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn register(
    State(state): State<AppState>,
    Json(req): Json<RegisterRequest>,
) -> Result<(StatusCode, Json<serde_json::Value>), (StatusCode, Json<serde_json::Value>)> {
    let username = req.username.unwrap_or_default();
    let password = req.password.unwrap_or_default();

    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    if username.len() < 3 || username.len() > 50 || !re.is_match(&username) {
        return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Invalid username"}))));
    }

    if password.len() < 8 {
        return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Password too short"}))));
    }

    let mut users = state.users.lock().unwrap();
    if users.iter().any(|u| u.username == username) {
        return Err((StatusCode::CONFLICT, Json(json!({"error": "Username already exists"}))));
    }

    let id = *state.next_user_id.lock().unwrap();
    *state.next_user_id.lock().unwrap() += 1;

    let password_hash = hash_password(&password);
    users.push(User {
        id,
        username: username.clone(),
        password_hash,
    });

    Ok((StatusCode::CREATED, Json(json!({
        "id": id,
        "username": username
    }))))
}

#[derive(Deserialize)]
struct LoginRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn login(
    State(state): State<AppState>,
    Json(req): Json<LoginRequest>,
) -> Result<(HeaderMap, Json<serde_json::Value>), (StatusCode, Json<serde_json::Value>)> {
    let username = req.username.unwrap_or_default();
    let password = req.password.unwrap_or_default();

    let users = state.users.lock().unwrap();
    let user_opt = users.iter().find(|u| u.username == username).cloned();
    drop(users);

    if let Some(user) = user_opt {
        if verify_password(&password, &user.password_hash) {
            let session_id = Uuid::new_v4().to_string();
            state.sessions.lock().unwrap().insert(session_id.clone(), user.id);

            let mut headers = HeaderMap::new();
            headers.insert(SET_COOKIE, format!("session_id={}; Path=/; HttpOnly", session_id).parse().unwrap());
            
            return Ok((headers, Json(json!({
                "id": user.id,
                "username": user.username
            }))));
        }
    }

    Err((StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))))
}

async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    let _user = get_user_from_headers(&headers, &state)?;
    
    let cookie_header = headers.get("cookie");
    if let Some(cookie) = cookie_header {
        let cookie_str = cookie.to_str().unwrap_or("");
        for c in cookie_str.split(';') {
            let c = c.trim();
            if let Some(session_id) = c.strip_prefix("session_id=") {
                state.sessions.lock().unwrap().remove(session_id);
                break;
            }
        }
    }

    Ok(Json(json!({})))
}

async fn get_me(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    let user = get_user_from_headers(&headers, &state)?;
    Ok(Json(json!({
        "id": user.id,
        "username": user.username
    })))
}

#[derive(Deserialize)]
struct PasswordUpdateRequest {
    old_password: Option<String>,
    new_password: Option<String>,
}

async fn update_password(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<PasswordUpdateRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    let user = get_user_from_headers(&headers, &state)?;
    
    let old_password = req.old_password.unwrap_or_default();
    let new_password = req.new_password.unwrap_or_default();

    if new_password.len() < 8 {
        return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Password too short"}))));
    }

    let mut users = state.users.lock().unwrap();
    let user_idx = users.iter().position(|u| u.id == user.id).unwrap();
    
    if !verify_password(&old_password, &users[user_idx].password_hash) {
        return Err((StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))));
    }

    users[user_idx].password_hash = hash_password(&new_password);

    Ok(Json(json!({})))
}

async fn get_todos(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    let user = get_user_from_headers(&headers, &state)?;
    
    let mut todos: Vec<_> = state.todos.lock().unwrap()
        .iter()
        .filter(|t| t.user_id == user.id)
        .cloned()
        .collect();
    
    todos.sort_by_key(|t| t.id);

    Ok(Json(serde_json::to_value(todos).unwrap()))
}

#[derive(Deserialize)]
struct CreateTodoRequest {
    title: Option<String>,
    description: Option<String>,
}

async fn create_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<CreateTodoRequest>,
) -> Result<(StatusCode, Json<serde_json::Value>), (StatusCode, Json<serde_json::Value>)> {
    let user = get_user_from_headers(&headers, &state)?;
    
    let title = req.title.unwrap_or_default();
    if title.is_empty() {
        return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Title is required"}))));
    }

    let description = req.description.unwrap_or_default();
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let id = *state.next_todo_id.lock().unwrap();
    *state.next_todo_id.lock().unwrap() += 1;

    let todo = Todo {
        id,
        user_id: user.id,
        title,
        description,
        completed: false,
        created_at: now.clone(),
        updated_at: now,
    };

    state.todos.lock().unwrap().push(todo.clone());

    Ok((StatusCode::CREATED, Json(serde_json::to_value(todo).unwrap())))
}

async fn get_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(todo_id): Path<i32>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    let user = get_user_from_headers(&headers, &state)?;
    
    let todos = state.todos.lock().unwrap();
    let todo = todos.iter().find(|t| t.id == todo_id && t.user_id == user.id).cloned();
    
    match todo {
        Some(t) => Ok(Json(serde_json::to_value(t).unwrap())),
        None => Err((StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"})))),
    }
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

async fn update_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(todo_id): Path<i32>,
    Json(req): Json<UpdateTodoRequest>,
) -> Result<Json<serde_json::Value>, (StatusCode, Json<serde_json::Value>)> {
    let user = get_user_from_headers(&headers, &state)?;
    
    if let Some(ref title) = req.title {
        if title.is_empty() {
            return Err((StatusCode::BAD_REQUEST, Json(json!({"error": "Title is required"}))));
        }
    }

    let mut todos = state.todos.lock().unwrap();
    let todo_idx = todos.iter().position(|t| t.id == todo_id && t.user_id == user.id);

    match todo_idx {
        Some(idx) => {
            if let Some(title) = req.title {
                todos[idx].title = title;
            }
            if let Some(description) = req.description {
                todos[idx].description = description;
            }
            if let Some(completed) = req.completed {
                todos[idx].completed = completed;
            }
            todos[idx].updated_at = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
            
            Ok(Json(serde_json::to_value(todos[idx].clone()).unwrap()))
        }
        None => Err((StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"})))),
    }
}

async fn delete_todo(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(todo_id): Path<i32>,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let user = get_user_from_headers(&headers, &state)?;
    
    let mut todos = state.todos.lock().unwrap();
    let todo_idx = todos.iter().position(|t| t.id == todo_id && t.user_id == user.id);

    match todo_idx {
        Some(idx) => {
            todos.remove(idx);
            Ok(StatusCode::NO_CONTENT)
        }
        None => Err((StatusCode::NOT_FOUND, Json(json!({"error": "Todo not found"})))),
    }
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut port = 3000;
    for i in 0..args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse().unwrap_or(3000);
        }
    }

    let state = AppState {
        users: Arc::new(Mutex::new(Vec::new())),
        todos: Arc::new(Mutex::new(Vec::new())),
        sessions: Arc::new(Mutex::new(HashMap::new())),
        next_user_id: Arc::new(Mutex::new(1)),
        next_todo_id: Arc::new(Mutex::new(1)),
    };

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

    let addr = format!("0.0.0.0:{}", port);
    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    println!("Listening on {}", addr);
    axum::serve(listener, app).await.unwrap();
}
