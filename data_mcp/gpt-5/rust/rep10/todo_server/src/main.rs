use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, net::SocketAddr, sync::{Arc, Mutex}};
use uuid::Uuid;

#[derive(Clone, Serialize)]
struct UserOut { id: u64, username: String }

#[derive(Clone)]
struct User {
    id: u64,
    username: String,
    password: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Todo {
    id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone, Default)]
struct AppState {
    users: HashMap<u64, User>,
    username_index: HashMap<String, u64>,
    sessions: HashMap<String, u64>, // session_id -> user_id
    todos: HashMap<u64, HashMap<u64, Todo>>, // user_id -> (todo_id -> Todo)
    next_user_id: u64,
    next_todo_id: HashMap<u64, u64>, // user_id -> next_todo_id
}

impl AppState {
    fn new() -> Self { Self { users: HashMap::new(), username_index: HashMap::new(), sessions: HashMap::new(), todos: HashMap::new(), next_user_id: 1, next_todo_id: HashMap::new() } }
}

#[derive(Serialize)]
struct ErrorMessage { error: String }

fn json<T: Serialize>(status: StatusCode, value: &T) -> Response {
    let body = serde_json::to_string(value).unwrap();
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, HeaderValue::from_static("application/json"))
        .body(axum::body::Body::from(body))
        .unwrap()
}

fn json_error(status: StatusCode, msg: &str) -> Response {
    json(status, &ErrorMessage { error: msg.to_string() })
}

fn now_iso() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

type Shared = Arc<Mutex<AppState>>;

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

fn extract_session_user(headers: &HeaderMap, state: &mut AppState) -> Result<u64, Response> {
    let mut user_id_opt: Option<u64> = None;
    if let Some(cookie_header) = headers.get(header::COOKIE) {
        if let Ok(cookie_str) = cookie_header.to_str() {
            for part in cookie_str.split(';') {
                let trimmed = part.trim();
                if let Some(rest) = trimmed.strip_prefix("session_id=") {
                    if let Some(uid) = state.sessions.get(rest) {
                        user_id_opt = Some(*uid);
                    }
                }
            }
        }
    }
    match user_id_opt {
        Some(uid) => Ok(uid),
        None => Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required")),
    }
}

#[tokio::main]
async fn main() {
    // Parse --port PORT
    let mut port: u16 = 3000;
    {
        let mut args = std::env::args().skip(1);
        while let Some(arg) = args.next() {
            if arg == "--port" {
                if let Some(p) = args.next() {
                    port = p.parse().unwrap_or(3000);
                }
            }
        }
    }

    let state: Shared = Arc::new(Mutex::new(AppState::new()));

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(state);

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    println!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn register(State(state): State<Shared>, Json(payload): Json<RegisterReq>) -> impl IntoResponse {
    // Validate
    let username_re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !username_re.is_match(&payload.username) { return json_error(StatusCode::BAD_REQUEST, "Invalid username"); }
    if payload.password.len() < 8 { return json_error(StatusCode::BAD_REQUEST, "Password too short"); }
    let mut st = state.lock().unwrap();
    if st.username_index.contains_key(&payload.username) { return json_error(StatusCode::CONFLICT, "Username already exists"); }
    let id = st.next_user_id;
    st.next_user_id += 1;
    st.users.insert(id, User { id, username: payload.username.clone(), password: payload.password.clone() });
    st.username_index.insert(payload.username.clone(), id);
    let out = UserOut { id, username: payload.username };
    json(StatusCode::CREATED, &out)
}

async fn login(State(state): State<Shared>, Json(payload): Json<LoginReq>) -> impl IntoResponse {
    let mut st = state.lock().unwrap();
    let uid = match st.username_index.get(&payload.username).cloned() { Some(id) => id, None => return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials") };
    // Clone user to avoid borrow conflicts when mutating sessions
    let user_cloned = st.users.get(&uid).cloned().unwrap();
    if user_cloned.password != payload.password { return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials"); }
    let token = Uuid::new_v4().to_string();
    st.sessions.insert(token.clone(), uid);
    let out = UserOut { id: user_cloned.id, username: user_cloned.username };
    let body = serde_json::to_string(&out).unwrap();
    let cookie_header_value = format!("session_id={}; Path=/; HttpOnly", token);
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, HeaderValue::from_static("application/json"))
        .header(header::SET_COOKIE, HeaderValue::from_str(&cookie_header_value).unwrap())
        .body(axum::body::Body::from(body))
        .unwrap()
}

async fn logout(State(state): State<Shared>, headers: HeaderMap) -> impl IntoResponse {
    let mut st = state.lock().unwrap();
    let _uid = match extract_session_user(&headers, &mut st) { Ok(id) => id, Err(e) => return e };
    // Find session token from header and remove it
    if let Some(cookie_header) = headers.get(header::COOKIE) {
        if let Ok(cookie_str) = cookie_header.to_str() {
            for part in cookie_str.split(';') {
                let trimmed = part.trim();
                if let Some(rest) = trimmed.strip_prefix("session_id=") {
                    st.sessions.remove(rest);
                }
            }
        }
    }
    json(StatusCode::OK, &serde_json::json!({}))
}

async fn me(State(state): State<Shared>, headers: HeaderMap) -> impl IntoResponse {
    let mut st = state.lock().unwrap();
    let uid = match extract_session_user(&headers, &mut st) { Ok(id) => id, Err(e) => return e };
    let user = st.users.get(&uid).unwrap();
    json(StatusCode::OK, &UserOut { id: user.id, username: user.username.clone() })
}

async fn change_password(State(state): State<Shared>, headers: HeaderMap, Json(payload): Json<PasswordReq>) -> impl IntoResponse {
    let mut st = state.lock().unwrap();
    let uid = match extract_session_user(&headers, &mut st) { Ok(id) => id, Err(e) => return e };
    if payload.new_password.len() < 8 { return json_error(StatusCode::BAD_REQUEST, "Password too short"); }
    let user = st.users.get_mut(&uid).unwrap();
    if user.password != payload.old_password { return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials"); }
    user.password = payload.new_password;
    json(StatusCode::OK, &serde_json::json!({}))
}

async fn list_todos(State(state): State<Shared>, headers: HeaderMap) -> impl IntoResponse {
    let mut st = state.lock().unwrap();
    let uid = match extract_session_user(&headers, &mut st) { Ok(id) => id, Err(e) => return e };
    let list = st.todos.get(&uid).map(|m| {
        let mut v: Vec<Todo> = m.values().cloned().collect();
        v.sort_by_key(|t| t.id);
        v
    }).unwrap_or_else(Vec::new);
    json(StatusCode::OK, &list)
}

async fn create_todo(State(state): State<Shared>, headers: HeaderMap, Json(payload): Json<CreateTodoReq>) -> impl IntoResponse {
    let mut st = state.lock().unwrap();
    let uid = match extract_session_user(&headers, &mut st) { Ok(id) => id, Err(e) => return e };
    let title = match payload.title.clone() { Some(t) if !t.trim().is_empty() => t, _ => return json_error(StatusCode::BAD_REQUEST, "Title is required") };
    let description = payload.description.clone().unwrap_or_else(String::new);
    let next_id = st.next_todo_id.entry(uid).or_insert(1);
    let id = *next_id;
    *next_id += 1;
    let ts = now_iso();
    let todo = Todo { id, title, description, completed: false, created_at: ts.clone(), updated_at: ts };
    st.todos.entry(uid).or_insert_with(HashMap::new).insert(id, todo.clone());
    json(StatusCode::CREATED, &todo)
}

async fn get_todo(State(state): State<Shared>, headers: HeaderMap, Path(id): Path<u64>) -> impl IntoResponse {
    let mut st = state.lock().unwrap();
    let uid = match extract_session_user(&headers, &mut st) { Ok(id) => id, Err(e) => return e };
    if let Some(todo) = st.todos.get(&uid).and_then(|m| m.get(&id)).cloned() {
        json(StatusCode::OK, &todo)
    } else {
        json_error(StatusCode::NOT_FOUND, "Todo not found")
    }
}

async fn update_todo(State(state): State<Shared>, headers: HeaderMap, Path(id): Path<u64>, Json(payload): Json<UpdateTodoReq>) -> impl IntoResponse {
    let mut st = state.lock().unwrap();
    let uid = match extract_session_user(&headers, &mut st) { Ok(id) => id, Err(e) => return e };
    let map = match st.todos.get_mut(&uid) { Some(m) => m, None => return json_error(StatusCode::NOT_FOUND, "Todo not found") };
    let todo = match map.get_mut(&id) { Some(t) => t, None => return json_error(StatusCode::NOT_FOUND, "Todo not found") };
    if let Some(t) = payload.title.clone() { if t.trim().is_empty() { return json_error(StatusCode::BAD_REQUEST, "Title is required"); } else { todo.title = t; } }
    if let Some(d) = payload.description.clone() { todo.description = d; }
    if let Some(c) = payload.completed { todo.completed = c; }
    todo.updated_at = now_iso();
    json(StatusCode::OK, &todo.clone())
}

async fn delete_todo(State(state): State<Shared>, headers: HeaderMap, Path(id): Path<u64>) -> impl IntoResponse {
    let mut st = state.lock().unwrap();
    let uid = match extract_session_user(&headers, &mut st) { Ok(id) => id, Err(e) => return e };
    if let Some(map) = st.todos.get_mut(&uid) {
        if map.remove(&id).is_some() {
            return Response::builder()
                .status(StatusCode::NO_CONTENT)
                .body(axum::body::Body::empty())
                .unwrap();
        }
    }
    json_error(StatusCode::NOT_FOUND, "Todo not found")
}
