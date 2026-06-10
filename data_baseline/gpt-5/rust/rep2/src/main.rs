use std::{collections::HashMap, net::SocketAddr, sync::{Arc, RwLock}};

use axum::{
    extract::{Path, State, FromRequestParts},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

// Simple cookie parsing because we avoid tower-cookies for compatibility
use axum::http::HeaderMap;

#[derive(Clone, Debug, Serialize)]
struct UserOut { id: u64, username: String }

#[derive(Clone, Debug)]
struct User { id: u64, username: String, password: String }

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Todo {
    id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone, Debug)]
struct TodoInternal {
    todo: Todo,
    user_id: u64,
}

#[derive(Clone, Default)]
struct AppState {
    users: Arc<RwLock<HashMap<u64, User>>>,
    users_by_name: Arc<RwLock<HashMap<String, u64>>>,
    user_next_id: Arc<RwLock<u64>>,

    sessions: Arc<RwLock<HashMap<String, u64>>>, // session_id -> user_id

    todos: Arc<RwLock<HashMap<u64, TodoInternal>>>,
    todo_next_id: Arc<RwLock<u64>>,
}

impl AppState {
    fn new() -> Self { Self::default() }
}

#[derive(Error, Debug)]
enum ApiError {
    #[error("Authentication required")]
    AuthRequired,
    #[error("Invalid credentials")]
    InvalidCreds,
    #[error("Invalid username")]
    InvalidUsername,
    #[error("Password too short")]
    PasswordTooShort,
    #[error("Username already exists")]
    UsernameExists,
    #[error("Title is required")]
    TitleRequired,
    #[error("Todo not found")]
    TodoNotFound,
    #[error("Bad request")]
    BadRequest,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = match self {
            ApiError::AuthRequired => StatusCode::UNAUTHORIZED,
            ApiError::InvalidCreds => StatusCode::UNAUTHORIZED,
            ApiError::InvalidUsername => StatusCode::BAD_REQUEST,
            ApiError::PasswordTooShort => StatusCode::BAD_REQUEST,
            ApiError::UsernameExists => StatusCode::CONFLICT,
            ApiError::TitleRequired => StatusCode::BAD_REQUEST,
            ApiError::TodoNotFound => StatusCode::NOT_FOUND,
            ApiError::BadRequest => StatusCode::BAD_REQUEST,
        };
        let body = serde_json::json!({"error": self.to_string()});
        (status, Json(body)).into_response()
    }
}

fn now_iso() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[derive(Deserialize)]
struct RegisterReq { username: String, password: String }

async fn register(State(state): State<AppState>, Json(payload): Json<RegisterReq>) -> Result<(StatusCode, Json<UserOut>), ApiError> {
    let uname = payload.username.trim();
    let re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !re.is_match(uname) { return Err(ApiError::InvalidUsername); }
    if payload.password.len() < 8 { return Err(ApiError::PasswordTooShort); }

    let user_id = {
        let mut next = state.user_next_id.write().unwrap();
        *next += 1;
        *next
    };

    {
        let mut by_name = state.users_by_name.write().unwrap();
        if by_name.contains_key(uname) { return Err(ApiError::UsernameExists); }
        by_name.insert(uname.to_string(), user_id);
    }

    let user = User { id: user_id, username: uname.to_string(), password: payload.password };
    {
        let mut users = state.users.write().unwrap();
        users.insert(user_id, user.clone());
    }

    Ok((StatusCode::CREATED, Json(UserOut { id: user.id, username: user.username })))
}

#[derive(Deserialize)]
struct LoginReq { username: String, password: String }

async fn login(State(state): State<AppState>, Json(payload): Json<LoginReq>) -> Result<(HeaderMap, Json<UserOut>), ApiError> {
    let uname = payload.username.trim();
    let uid = {
        let map = state.users_by_name.read().unwrap();
        map.get(uname).cloned()
    };
    let uid = match uid { Some(id) => id, None => return Err(ApiError::InvalidCreds) };
    let user = {
        let users = state.users.read().unwrap();
        users.get(&uid).cloned().unwrap()
    };
    if user.password != payload.password { return Err(ApiError::InvalidCreds); }

    let token = Uuid::new_v4().simple().to_string();
    {
        let mut sessions = state.sessions.write().unwrap();
        sessions.insert(token.clone(), uid);
    }
    // Build Set-Cookie header
    let mut headers = HeaderMap::new();
    let cookie_value = format!("session_id={}; Path=/; HttpOnly", token);
    headers.insert(axum::http::header::SET_COOKIE, axum::http::HeaderValue::from_str(&cookie_value).unwrap());

    Ok((headers, Json(UserOut { id: user.id, username: user.username })))
}

async fn logout(State(state): State<AppState>, user_id: UserId) -> Result<Json<serde_json::Value>, ApiError> {
    // Logout by invalidating the session token derived from cookie in extractor
    // extractor validated the cookie and stored uid; but we also need to remove the session id
    // Since we don't have direct access to the cookie token here, we require the extractor to expose it.
    // We'll create a different extractor carrying both uid and token.
    let _ = user_id; // replaced below
    Err(ApiError::BadRequest)
}

#[derive(Clone)]
struct UserId(u64);

#[derive(Clone)]
struct AuthSession { user_id: u64, token: String }

#[axum::async_trait]
impl FromRequestParts<AppState> for AuthSession {
    type Rejection = ApiError;
    async fn from_request_parts(parts: &mut axum::http::request::Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        // Parse Cookie header manually
        let cookie_header = parts.headers.get(axum::http::header::COOKIE).and_then(|v| v.to_str().ok()).unwrap_or("");
        let mut session_token: Option<String> = None;
        for pair in cookie_header.split(';') {
            let p = pair.trim();
            if let Some(rest) = p.strip_prefix("session_id=") {
                session_token = Some(rest.to_string());
                break;
            }
        }
        let token = session_token.ok_or(ApiError::AuthRequired)?;
        let sessions = state.sessions.read().unwrap();
        let uid = sessions.get(&token).cloned().ok_or(ApiError::AuthRequired)?;
        Ok(AuthSession { user_id: uid, token })
    }
}

async fn logout2(State(state): State<AppState>, auth: AuthSession) -> Result<Json<serde_json::Value>, ApiError> {
    let mut sessions = state.sessions.write().unwrap();
    sessions.remove(&auth.token);
    Ok(Json(serde_json::json!({})))
}

#[derive(Deserialize)]
struct PasswordReq { old_password: String, new_password: String }

async fn change_password(State(state): State<AppState>, auth: AuthSession, Json(payload): Json<PasswordReq>) -> Result<Json<serde_json::Value>, ApiError> {
    if payload.new_password.len() < 8 { return Err(ApiError::PasswordTooShort); }
    {
        let users = state.users.read().unwrap();
        let user = users.get(&auth.user_id).unwrap();
        if user.password != payload.old_password { return Err(ApiError::InvalidCreds); }
    }
    {
        let mut users = state.users.write().unwrap();
        if let Some(user) = users.get_mut(&auth.user_id) {
            user.password = payload.new_password;
        }
    }
    Ok(Json(serde_json::json!({})))
}

async fn me(State(state): State<AppState>, auth: AuthSession) -> Result<Json<UserOut>, ApiError> {
    let users = state.users.read().unwrap();
    let user = users.get(&auth.user_id).cloned().unwrap();
    Ok(Json(UserOut { id: user.id, username: user.username }))
}

async fn list_todos(State(state): State<AppState>, auth: AuthSession) -> Result<Json<Vec<Todo>>, ApiError> {
    let todos_map = state.todos.read().unwrap();
    let mut todos: Vec<Todo> = todos_map
        .values()
        .filter(|t| t.user_id == auth.user_id)
        .map(|t| t.todo.clone())
        .collect();
    todos.sort_by_key(|t| t.id);
    Ok(Json(todos))
}

#[derive(Deserialize)]
struct CreateTodoReq { title: Option<String>, description: Option<String> }

async fn create_todo(State(state): State<AppState>, auth: AuthSession, Json(payload): Json<CreateTodoReq>) -> Result<(StatusCode, Json<Todo>), ApiError> {
    let title = payload.title.unwrap_or_default();
    if title.trim().is_empty() { return Err(ApiError::TitleRequired); }
    let description = payload.description.unwrap_or_else(|| "".to_string());
    let id = {
        let mut next = state.todo_next_id.write().unwrap();
        *next += 1;
        *next
    };
    let now = now_iso();
    let todo = Todo { id, title, description, completed: false, created_at: now.clone(), updated_at: now };
    let internal = TodoInternal { todo: todo.clone(), user_id: auth.user_id };
    {
        let mut map = state.todos.write().unwrap();
        map.insert(id, internal);
    }
    Ok((StatusCode::CREATED, Json(todo)))
}

async fn get_todo(State(state): State<AppState>, auth: AuthSession, Path(id): Path<u64>) -> Result<Json<Todo>, ApiError> {
    let map = state.todos.read().unwrap();
    let t = map.get(&id).ok_or(ApiError::TodoNotFound)?;
    if t.user_id != auth.user_id { return Err(ApiError::TodoNotFound); }
    Ok(Json(t.todo.clone()))
}

#[derive(Deserialize)]
struct UpdateTodoReq { title: Option<String>, description: Option<String>, completed: Option<bool> }

async fn update_todo(State(state): State<AppState>, auth: AuthSession, Path(id): Path<u64>, Json(payload): Json<UpdateTodoReq>) -> Result<Json<Todo>, ApiError> {
    let mut map = state.todos.write().unwrap();
    let entry = map.get_mut(&id).ok_or(ApiError::TodoNotFound)?;
    if entry.user_id != auth.user_id { return Err(ApiError::TodoNotFound); }
    if let Some(t) = payload.title.as_ref() {
        if t.trim().is_empty() { return Err(ApiError::TitleRequired); }
    }
    if let Some(t) = payload.title { entry.todo.title = t; }
    if let Some(d) = payload.description { entry.todo.description = d; }
    if let Some(c) = payload.completed { entry.todo.completed = c; }
    entry.todo.updated_at = now_iso();
    Ok(Json(entry.todo.clone()))
}

async fn delete_todo(State(state): State<AppState>, auth: AuthSession, Path(id): Path<u64>) -> Result<StatusCode, ApiError> {
    let mut map = state.todos.write().unwrap();
    let entry = map.get(&id).cloned().ok_or(ApiError::TodoNotFound)?;
    if entry.user_id != auth.user_id { return Err(ApiError::TodoNotFound); }
    map.remove(&id);
    Ok(StatusCode::NO_CONTENT)
}

async fn json_response<B>(mut res: Response<B>) -> Response<B> {
    if res.status() == StatusCode::NO_CONTENT { return res; }
    let headers = res.headers_mut();
    headers.insert(axum::http::header::CONTENT_TYPE, axum::http::HeaderValue::from_static("application/json"));
    res
}

#[tokio::main]
async fn main() {
    let mut port: u16 = 3000;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(pstr) = args.next() {
                if let Ok(p) = pstr.parse::<u16>() { port = p; }
            }
        }
    }

    let state = AppState::new();
    {
        *state.user_next_id.write().unwrap() = 0;
        *state.todo_next_id.write().unwrap() = 0;
    }

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout2))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .layer(axum::middleware::map_response(json_response))
        .with_state(state);

    let addr = SocketAddr::from(([0,0,0,0], port));
    println!("listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
