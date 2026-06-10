use std::{collections::HashMap, net::SocketAddr, sync::Arc};

use axum::{
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use parking_lot::Mutex;
use regex::Regex;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;
use clap::Parser;

#[derive(Parser, Debug)]
#[command(version, about = "In-memory Todo server with cookie auth")] 
struct Cli {
    #[arg(long, default_value_t = 8080)]
    port: u16,
}

fn now_ts() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[derive(Clone, Serialize)]
struct UserPublic { id: u64, username: String }

#[derive(Clone)]
struct UserPrivate { id: u64, username: String, password: String }

#[derive(Clone, Serialize)]
struct Todo {
    id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Default)]
struct AppStateInner {
    next_user_id: u64,
    next_todo_id: u64,
    users_by_name: HashMap<String, UserPrivate>,
    sessions: HashMap<String, u64>, // session_id -> user_id
    todos: HashMap<u64, Vec<Todo>>, // user_id -> todos
}

#[derive(Clone, Default)]
struct AppState(Arc<Mutex<AppStateInner>>);

impl AppState {
    fn lock(&self) -> parking_lot::MutexGuard<'_, AppStateInner> { self.0.lock() }
}

#[derive(Deserialize)]
struct RegisterReq { username: String, password: String }

#[derive(Deserialize)]
struct LoginReq { username: String, password: String }

#[derive(Deserialize)]
struct PasswordReq { old_password: String, new_password: String }

#[derive(Deserialize)]
struct CreateTodoReq { title: Option<String>, description: Option<String> }

#[derive(Deserialize)]
struct UpdateTodoReq { title: Option<String>, description: Option<String>, completed: Option<bool> }

#[derive(Error, Debug)]
enum ApiError {
    #[error("Authentication required")] AuthRequired,
    #[error("Invalid credentials")] InvalidCredentials,
    #[error("Invalid username")] InvalidUsername,
    #[error("Password too short")] PasswordTooShort,
    #[error("Username already exists")] UsernameExists,
    #[error("Title is required")] TitleRequired,
    #[error("Todo not found")] TodoNotFound,
    #[error("Bad request")] BadRequest,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (code, msg) = match self {
            ApiError::AuthRequired => (StatusCode::UNAUTHORIZED, "Authentication required"),
            ApiError::InvalidCredentials => (StatusCode::UNAUTHORIZED, "Invalid credentials"),
            ApiError::InvalidUsername => (StatusCode::BAD_REQUEST, "Invalid username"),
            ApiError::PasswordTooShort => (StatusCode::BAD_REQUEST, "Password too short"),
            ApiError::UsernameExists => (StatusCode::CONFLICT, "Username already exists"),
            ApiError::TitleRequired => (StatusCode::BAD_REQUEST, "Title is required"),
            ApiError::TodoNotFound => (StatusCode::NOT_FOUND, "Todo not found"),
            ApiError::BadRequest => (StatusCode::BAD_REQUEST, "Bad request"),
        };
        let body = serde_json::json!({"error": msg});
        let mut res = (code, Json(body)).into_response();
        // Ensure JSON content-type
        res.headers_mut().insert(axum::http::header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
        res
    }
}

fn username_valid(name: &str) -> bool {
    if name.len() < 3 || name.len() > 50 { return false; }
    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    re.is_match(name)
}

fn set_json_content_type(headers: &mut HeaderMap) {
    headers.insert(axum::http::header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
}

fn set_cookie(headers: &mut HeaderMap, token: &str) {
    // Set-Cookie: session_id=<token>; Path=/; HttpOnly
    let cookie = format!("session_id={}; Path=/; HttpOnly", token);
    headers.append(axum::http::header::SET_COOKIE, HeaderValue::from_str(&cookie).unwrap());
}

fn read_session_cookie(headers: &HeaderMap) -> Option<String> {
    // Parse Cookie header manually to avoid extra deps
    let cookie_header = headers.get(axum::http::header::COOKIE)?;
    let cookie_str = cookie_header.to_str().ok()?;
    for part in cookie_str.split(';') {
        let p = part.trim();
        if let Some(rest) = p.strip_prefix("session_id=") {
            return Some(rest.to_string());
        }
    }
    None
}

fn require_auth(headers: &HeaderMap, state: &AppState) -> Result<u64, ApiError> {
    if let Some(token) = read_session_cookie(headers) {
        let st = state.lock();
        if let Some(uid) = st.sessions.get(&token) { return Ok(*uid); }
    }
    Err(ApiError::AuthRequired)
}

async fn register(State(state): State<AppState>, Json(req): Json<RegisterReq>) -> Result<impl IntoResponse, ApiError> {
    if !username_valid(&req.username) { return Err(ApiError::InvalidUsername); }
    if req.password.len() < 8 { return Err(ApiError::PasswordTooShort); }

    let mut st = state.lock();
    if st.users_by_name.contains_key(&req.username) {
        return Err(ApiError::UsernameExists);
    }
    st.next_user_id += 1;
    let id = st.next_user_id;
    let user = UserPrivate { id, username: req.username.clone(), password: req.password };
    st.users_by_name.insert(user.username.clone(), user.clone());

    let pubu = UserPublic { id: user.id, username: user.username };
    let body = Json(pubu);
    let mut res = (StatusCode::CREATED, body).into_response();
    set_json_content_type(res.headers_mut());
    Ok(res)
}

async fn login(State(state): State<AppState>, Json(req): Json<LoginReq>) -> Result<impl IntoResponse, ApiError> {
    let mut st = state.lock();
    let user = match st.users_by_name.get(&req.username) { Some(u) => u.clone(), None => return Err(ApiError::InvalidCredentials) };
    if user.password != req.password { return Err(ApiError::InvalidCredentials); }
    let token = Uuid::new_v4().simple().to_string();
    st.sessions.insert(token.clone(), user.id);

    let pubu = UserPublic { id: user.id, username: user.username };
    let mut res = (StatusCode::OK, Json(pubu)).into_response();
    set_json_content_type(res.headers_mut());
    set_cookie(res.headers_mut(), &token);
    Ok(res)
}

async fn logout(State(state): State<AppState>, headers: HeaderMap) -> Result<impl IntoResponse, ApiError> {
    let token = read_session_cookie(&headers).ok_or(ApiError::AuthRequired)?;
    let mut st = state.lock();
    if st.sessions.remove(&token).is_none() { return Err(ApiError::AuthRequired); }
    let mut res = (StatusCode::OK, Json(serde_json::json!({}))).into_response();
    set_json_content_type(res.headers_mut());
    Ok(res)
}

async fn me(State(state): State<AppState>, headers: HeaderMap) -> Result<impl IntoResponse, ApiError> {
    let uid = require_auth(&headers, &state)?;
    let st = state.lock();
    let user = st.users_by_name.values().find(|u| u.id == uid).unwrap().clone();
    let pubu = UserPublic { id: user.id, username: user.username };
    let mut res = (StatusCode::OK, Json(pubu)).into_response();
    set_json_content_type(res.headers_mut());
    Ok(res)
}

async fn change_password(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<PasswordReq>) -> Result<impl IntoResponse, ApiError> {
    let uid = require_auth(&headers, &state)?;
    if req.new_password.len() < 8 { return Err(ApiError::PasswordTooShort); }
    let mut st = state.lock();
    let user = st.users_by_name.values_mut().find(|u| u.id == uid).unwrap();
    if user.password != req.old_password { return Err(ApiError::InvalidCredentials); }
    user.password = req.new_password;
    let mut res = (StatusCode::OK, Json(serde_json::json!({}))).into_response();
    set_json_content_type(res.headers_mut());
    Ok(res)
}

async fn list_todos(State(state): State<AppState>, headers: HeaderMap) -> Result<impl IntoResponse, ApiError> {
    let uid = require_auth(&headers, &state)?;
    let st = state.lock();
    let mut list = st.todos.get(&uid).cloned().unwrap_or_default();
    list.sort_by_key(|t| t.id);
    let mut res = (StatusCode::OK, Json(list)).into_response();
    set_json_content_type(res.headers_mut());
    Ok(res)
}

async fn create_todo(State(state): State<AppState>, headers: HeaderMap, Json(req): Json<CreateTodoReq>) -> Result<impl IntoResponse, ApiError> {
    let uid = require_auth(&headers, &state)?;
    let title = match req.title { Some(t) if !t.trim().is_empty() => t, _ => return Err(ApiError::TitleRequired) };
    let description = req.description.unwrap_or_default();
    let mut st = state.lock();
    st.next_todo_id += 1;
    let id = st.next_todo_id;
    let ts = now_ts();
    let todo = Todo { id, title, description: description.clone(), completed: false, created_at: ts.clone(), updated_at: ts };
    let entry = st.todos.entry(uid).or_default();
    entry.push(todo.clone());
    let mut res = (StatusCode::CREATED, Json(todo)).into_response();
    set_json_content_type(res.headers_mut());
    Ok(res)
}

fn find_todo_mut<'a>(st: &'a mut AppStateInner, uid: u64, id: u64) -> Option<&'a mut Todo> {
    let list = st.todos.get_mut(&uid)?;
    list.iter_mut().find(|t| t.id == id)
}

async fn get_todo(Path(id): Path<u64>, State(state): State<AppState>, headers: HeaderMap) -> Result<impl IntoResponse, ApiError> {
    let uid = require_auth(&headers, &state)?;
    let st = state.lock();
    if let Some(list) = st.todos.get(&uid) {
        if let Some(todo) = list.iter().find(|t| t.id == id) {
            let mut res = (StatusCode::OK, Json(todo.clone())).into_response();
            set_json_content_type(res.headers_mut());
            return Ok(res);
        }
    }
    Err(ApiError::TodoNotFound)
}

async fn update_todo(Path(id): Path<u64>, State(state): State<AppState>, headers: HeaderMap, Json(req): Json<UpdateTodoReq>) -> Result<impl IntoResponse, ApiError> {
    let uid = require_auth(&headers, &state)?;
    if let Some(title) = &req.title { if title.trim().is_empty() { return Err(ApiError::TitleRequired); } }
    let mut st = state.lock();
    let Some(todo) = find_todo_mut(&mut st, uid, id) else { return Err(ApiError::TodoNotFound); };
    if let Some(t) = req.title { todo.title = t; }
    if let Some(d) = req.description { todo.description = d; }
    if let Some(c) = req.completed { todo.completed = c; }
    todo.updated_at = now_ts();
    let mut res = (StatusCode::OK, Json(todo.clone())).into_response();
    set_json_content_type(res.headers_mut());
    Ok(res)
}

async fn delete_todo(Path(id): Path<u64>, State(state): State<AppState>, headers: HeaderMap) -> Result<impl IntoResponse, ApiError> {
    let uid = require_auth(&headers, &state)?;
    let mut st = state.lock();
    if let Some(list) = st.todos.get_mut(&uid) {
        if let Some(pos) = list.iter().position(|t| t.id == id) {
            list.remove(pos);
            return Ok(StatusCode::NO_CONTENT.into_response());
        }
    }
    Err(ApiError::TodoNotFound)
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let state = AppState(Default::default());

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(state);

    let addr = SocketAddr::from(([0,0,0,0], cli.port));
    println!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
