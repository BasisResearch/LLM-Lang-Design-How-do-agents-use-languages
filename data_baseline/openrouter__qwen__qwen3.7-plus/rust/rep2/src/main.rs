use axum::{
    routing::{get, post, put},
    Router,
    extract::{State, Path},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use axum_extra::extract::cookie::{Cookie, CookieJar};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::sync::atomic::{AtomicU32, Ordering};
use chrono::Utc;
use regex::Regex;
use uuid::Uuid;

#[derive(Clone, Serialize, Deserialize)]
struct User {
    id: u32,
    username: String,
    password: String,
}

#[derive(Clone, Serialize)]
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

struct AppState {
    users: RwLock<HashMap<u32, User>>,
    username_to_id: RwLock<HashMap<String, u32>>,
    sessions: RwLock<HashMap<String, u32>>,
    todos: RwLock<HashMap<u32, Todo>>,
    user_todos: RwLock<HashMap<u32, Vec<u32>>>,
    next_user_id: AtomicU32,
    next_todo_id: AtomicU32,
}

impl AppState {
    fn new() -> Self {
        Self {
            users: RwLock::new(HashMap::new()),
            username_to_id: RwLock::new(HashMap::new()),
            sessions: RwLock::new(HashMap::new()),
            todos: RwLock::new(HashMap::new()),
            user_todos: RwLock::new(HashMap::new()),
            next_user_id: AtomicU32::new(1),
            next_todo_id: AtomicU32::new(1),
        }
    }
}

#[derive(Deserialize)]
struct RegisterReq {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct LoginReq {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct ChangePasswordReq {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize)]
struct CreateTodoReq {
    title: Option<String>,
    description: Option<String>,
}

#[derive(Deserialize)]
struct UpdateTodoReq {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

fn get_user_id(jar: &CookieJar, state: &Arc<AppState>) -> Result<u32, (StatusCode, Json<serde_json::Value>)> {
    if let Some(cookie) = jar.get("session_id") {
        let sessions = state.sessions.read().unwrap();
        if let Some(&user_id) = sessions.get(cookie.value()) {
            return Ok(user_id);
        }
    }
    Err((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "Authentication required"}))))
}

async fn register(
    State(state): State<Arc<AppState>>,
    Json(req): Json<RegisterReq>,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let username_regex = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    if req.username.len() < 3 || req.username.len() > 50 || !username_regex.is_match(&req.username) {
        return Err((StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "Invalid username"}))));
    }
    if req.password.len() < 8 {
        return Err((StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "Password too short"}))));
    }

    let mut username_to_id = state.username_to_id.write().unwrap();
    if username_to_id.contains_key(&req.username) {
        return Err((StatusCode::CONFLICT, Json(serde_json::json!({"error": "Username already exists"}))));
    }

    let user_id = state.next_user_id.fetch_add(1, Ordering::SeqCst);
    let user = User {
        id: user_id,
        username: req.username.clone(),
        password: req.password,
    };

    state.users.write().unwrap().insert(user_id, user);
    let username_for_map = req.username.clone();
    username_to_id.insert(username_for_map, user_id);

    Ok((StatusCode::CREATED, Json(serde_json::json!({
        "id": user_id,
        "username": req.username
    }))))
}

async fn login(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    Json(req): Json<LoginReq>,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let user_info = {
        let username_to_id = state.username_to_id.read().unwrap();
        if let Some(&user_id) = username_to_id.get(&req.username) {
            let users = state.users.read().unwrap();
            if let Some(user) = users.get(&user_id) {
                if user.password == req.password {
                    Some((user_id, user.username.clone()))
                } else {
                    None
                }
            } else {
                None
            }
        } else {
            None
        }
    };

    if let Some((user_id, username)) = user_info {
        let token = Uuid::new_v4().to_string();
        state.sessions.write().unwrap().insert(token.clone(), user_id);
        
        let cookie = Cookie::build(("session_id", token))
            .path("/")
            .http_only(true)
            .build();
            
        Ok((jar.add(cookie), (StatusCode::OK, Json(serde_json::json!({
            "id": user_id,
            "username": username
        })))))
    } else {
        Err((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "Invalid credentials"}))))
    }
}

async fn logout(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let _user_id = get_user_id(&jar, &state)?;
    
    if let Some(cookie) = jar.get("session_id") {
        state.sessions.write().unwrap().remove(cookie.value());
    }
    
    Ok((jar.remove(Cookie::from("session_id")), (StatusCode::OK, Json(serde_json::json!({})))))
}

async fn me(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let user_id = get_user_id(&jar, &state)?;
    let users = state.users.read().unwrap();
    if let Some(user) = users.get(&user_id) {
        Ok((StatusCode::OK, Json(serde_json::json!({
            "id": user.id,
            "username": user.username.clone()
        }))))
    } else {
        Err((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "Authentication required"}))))
    }
}

async fn change_password(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    Json(req): Json<ChangePasswordReq>,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let user_id = get_user_id(&jar, &state)?;
    
    if req.new_password.len() < 8 {
        return Err((StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "Password too short"}))));
    }
    
    let mut users = state.users.write().unwrap();
    if let Some(user) = users.get_mut(&user_id) {
        if user.password != req.old_password {
            return Err((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "Invalid credentials"}))));
        }
        user.password = req.new_password;
        Ok((StatusCode::OK, Json(serde_json::json!({}))))
    } else {
        Err((StatusCode::UNAUTHORIZED, Json(serde_json::json!({"error": "Authentication required"}))))
    }
}

async fn get_todos(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let user_id = get_user_id(&jar, &state)?;
    
    let todo_ids = {
        let user_todos = state.user_todos.read().unwrap();
        user_todos.get(&user_id).cloned().unwrap_or_default()
    };
    
    let todos = state.todos.read().unwrap();
    let mut result: Vec<Todo> = todo_ids
        .into_iter()
        .filter_map(|id| todos.get(&id).cloned())
        .collect();
        
    result.sort_by_key(|t| t.id);
    
    Ok((StatusCode::OK, Json(serde_json::to_value(result).unwrap())))
}

async fn create_todo(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    Json(req): Json<CreateTodoReq>,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let user_id = get_user_id(&jar, &state)?;
    
    let title = req.title.unwrap_or_default();
    if title.trim().is_empty() {
        return Err((StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "Title is required"}))));
    }
    
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
    
    state.todos.write().unwrap().insert(todo_id, todo.clone());
    
    let mut user_todos = state.user_todos.write().unwrap();
    user_todos.entry(user_id).or_default().push(todo_id);
    
    Ok((StatusCode::CREATED, Json(serde_json::to_value(todo).unwrap())))
}

async fn get_todo(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    Path(todo_id): Path<u32>,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let user_id = get_user_id(&jar, &state)?;
    
    let todos = state.todos.read().unwrap();
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id == user_id {
            return Ok((StatusCode::OK, Json(serde_json::to_value(todo).unwrap())));
        }
    }
    Err((StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "Todo not found"}))))
}

async fn update_todo(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    Path(todo_id): Path<u32>,
    Json(req): Json<UpdateTodoReq>,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let user_id = get_user_id(&jar, &state)?;
    
    let mut todos = state.todos.write().unwrap();
    if let Some(todo) = todos.get_mut(&todo_id) {
        if todo.user_id != user_id {
            return Err((StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "Todo not found"}))));
        }
        
        if let Some(title) = req.title {
            if title.trim().is_empty() {
                return Err((StatusCode::BAD_REQUEST, Json(serde_json::json!({"error": "Title is required"}))));
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
        
        return Ok((StatusCode::OK, Json(serde_json::to_value(todo.clone()).unwrap())));
    }
    
    Err((StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "Todo not found"}))))
}

async fn delete_todo(
    State(state): State<Arc<AppState>>,
    jar: CookieJar,
    Path(todo_id): Path<u32>,
) -> Result<impl IntoResponse, (StatusCode, Json<serde_json::Value>)> {
    let user_id = get_user_id(&jar, &state)?;
    
    let mut todos = state.todos.write().unwrap();
    if let Some(todo) = todos.get(&todo_id) {
        if todo.user_id != user_id {
            return Err((StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "Todo not found"}))));
        }
        
        todos.remove(&todo_id);
        
        let mut user_todos = state.user_todos.write().unwrap();
        if let Some(list) = user_todos.get_mut(&user_id) {
            list.retain(|&id| id != todo_id);
        }
        
        return Ok(StatusCode::NO_CONTENT);
    }
    
    Err((StatusCode::NOT_FOUND, Json(serde_json::json!({"error": "Todo not found"}))))
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut port = 8080;
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse().unwrap_or(8080);
            i += 2;
        } else {
            i += 1;
        }
    }
    
    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(get_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(Arc::new(AppState::new()));

    let listener = tokio::net::TcpListener::bind(format!("0.0.0.0:{}", port)).await.unwrap();
    println!("Listening on 0.0.0.0:{}", port);
    axum::serve(listener, app).await.unwrap();
}
