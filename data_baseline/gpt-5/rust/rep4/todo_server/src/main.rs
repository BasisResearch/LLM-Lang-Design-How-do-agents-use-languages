use std::{collections::HashMap, net::SocketAddr, sync::{Arc, Mutex}};

use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize, Deserialize)]
struct User {
    id: u64,
    username: String,
}

#[derive(Clone, Debug)]
struct StoredUser {
    user: User,
    // store password as salted hash in a simple way
    password_hash: String,
    salt: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
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
    // username -> user
    users_by_username: HashMap<String, StoredUser>,
    // id -> user
    users_by_id: HashMap<u64, StoredUser>,
    next_user_id: u64,

    // session_id -> user_id
    sessions: HashMap<String, u64>,

    // user_id -> Vec<Todo>
    todos: HashMap<u64, Vec<Todo>>,
    next_todo_id: HashMap<u64, u64>,
}

impl AppState {
    fn new() -> Self {
        Self { next_user_id: 1, ..Default::default() }
    }
}

#[derive(Clone)]
struct SharedState(Arc<Mutex<AppState>>);

impl SharedState {
    fn new() -> Self { Self(Arc::new(Mutex::new(AppState::new()))) }
}

#[derive(Debug, Serialize)]
struct ErrorResponse { error: String }

impl IntoResponse for ErrorResponse {
    fn into_response(self) -> Response {
        let mut res = (StatusCode::BAD_REQUEST, Json(self)).into_response();
        // ensure content-type application/json
        res.headers_mut().insert(axum::http::header::CONTENT_TYPE, axum::http::HeaderValue::from_static("application/json"));
        res
    }
}

fn json_response<T: Serialize>(status: StatusCode, value: &T) -> Response {
    let body = serde_json::to_string(value).unwrap();
    let res = Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .body(axum::body::Body::from(body))
        .unwrap();
    res
}

fn now_iso() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn hash_password(password: &str, salt: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(password.as_bytes());
    let out = hasher.finalize();
    hex::encode(out)
}

#[derive(Deserialize)]
struct RegisterReq { username: String, password: String }

#[derive(Serialize)]
struct UserResp { id: u64, username: String }

async fn register(State(state): State<SharedState>, Json(req): Json<RegisterReq>) -> Response {
    // validations
    let username_re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !username_re.is_match(&req.username) {
        return json_response(StatusCode::BAD_REQUEST, &ErrorResponse{ error: "Invalid username".to_string() });
    }
    if req.password.len() < 8 {
        return json_response(StatusCode::BAD_REQUEST, &ErrorResponse{ error: "Password too short".to_string() });
    }

    let mut s = state.0.lock().unwrap();
    if s.users_by_username.contains_key(&req.username) {
        return json_response(StatusCode::CONFLICT, &ErrorResponse{ error: "Username already exists".to_string() });
    }
    let id = s.next_user_id;
    s.next_user_id += 1;
    let salt = Uuid::new_v4().to_string();
    let stored = StoredUser{
        user: User{ id, username: req.username.clone() },
        password_hash: hash_password(&req.password, &salt),
        salt,
    };
    s.users_by_id.insert(id, stored.clone());
    s.users_by_username.insert(req.username.clone(), stored);

    let resp = UserResp{ id, username: req.username.clone() };
    json_response(StatusCode::CREATED, &resp)
}

#[derive(Deserialize)]
struct LoginReq { username: String, password: String }

async fn login(State(state): State<SharedState>, Json(req): Json<LoginReq>) -> Response {
    let mut s = state.0.lock().unwrap();
    let user = match s.users_by_username.get(&req.username) {
        Some(u) => u.clone(),
        None => {
            return json_response(StatusCode::UNAUTHORIZED, &ErrorResponse{ error: "Invalid credentials".to_string() });
        }
    };
    if user.password_hash != hash_password(&req.password, &user.salt) {
        return json_response(StatusCode::UNAUTHORIZED, &ErrorResponse{ error: "Invalid credentials".to_string() });
    }

    let token = Uuid::new_v4().to_string();
    s.sessions.insert(token.clone(), user.user.id);

    // Set-Cookie header
    let set_cookie = format!("session_id={}; Path=/; HttpOnly", token);

    let resp = UserResp{ id: user.user.id, username: user.user.username.clone() };
    let body = serde_json::to_string(&resp).unwrap();
    let response = Response::builder()
        .status(StatusCode::OK)
        .header("Content-Type", "application/json")
        .header("Set-Cookie", set_cookie)
        .body(axum::body::Body::from(body))
        .unwrap();
    response
}

fn extract_user_id_from_cookie(s: &mut AppState, headers: &HeaderMap) -> Result<u64, Response> {
    if let Some(cookie_header) = headers.get(axum::http::header::COOKIE) {
        if let Ok(cookie_str) = cookie_header.to_str() {
            // parse simple cookie "a=b; c=d" style
            for part in cookie_str.split(';') {
                let trimmed = part.trim();
                if let Some(rest) = trimmed.strip_prefix("session_id=") {
                    if let Some(uid) = s.sessions.get(rest) {
                        return Ok(*uid);
                    } else {
                        return Err(json_response(StatusCode::UNAUTHORIZED, &ErrorResponse{ error: "Authentication required".to_string() }));
                    }
                }
            }
        }
    }
    Err(json_response(StatusCode::UNAUTHORIZED, &ErrorResponse{ error: "Authentication required".to_string() }))
}

async fn me(State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let mut s = state.0.lock().unwrap();
    let uid = match extract_user_id_from_cookie(&mut s, &headers) { Ok(id)=>id, Err(resp)=> return resp };
    if let Some(stored) = s.users_by_id.get(&uid) {
        let resp = UserResp{ id: stored.user.id, username: stored.user.username.clone() };
        return json_response(StatusCode::OK, &resp);
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorResponse{ error: "Authentication required".to_string() })
}

async fn logout(State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let mut s = state.0.lock().unwrap();
    // require valid session cookie and invalidate token
    if let Some(cookie_header) = headers.get(axum::http::header::COOKIE) {
        if let Ok(cookie_str) = cookie_header.to_str() {
            for part in cookie_str.split(';') {
                let trimmed = part.trim();
                if let Some(token) = trimmed.strip_prefix("session_id=") {
                    if s.sessions.contains_key(token) {
                        s.sessions.remove(token);
                        let body = serde_json::to_string(&serde_json::json!({})).unwrap();
                        let response = Response::builder()
                            .status(StatusCode::OK)
                            .header("Content-Type", "application/json")
                            .body(axum::body::Body::from(body))
                            .unwrap();
                        return response;
                    } else {
                        return json_response(StatusCode::UNAUTHORIZED, &ErrorResponse{ error: "Authentication required".to_string() });
                    }
                }
            }
        }
    }
    // if missing/invalid, return 401
    json_response(StatusCode::UNAUTHORIZED, &ErrorResponse{ error: "Authentication required".to_string() })
}

#[derive(Deserialize)]
struct PasswordChangeReq { old_password: String, new_password: String }

async fn change_password(State(state): State<SharedState>, headers: HeaderMap, Json(req): Json<PasswordChangeReq>) -> Response {
    let mut s = state.0.lock().unwrap();
    let uid = match extract_user_id_from_cookie(&mut s, &headers) { Ok(id)=>id, Err(resp)=> return resp };
    let stored = match s.users_by_id.get(&uid).cloned() { Some(u)=>u, None=> {
        return json_response(StatusCode::UNAUTHORIZED, &ErrorResponse{ error: "Authentication required".to_string() });
    }};
    if stored.password_hash != hash_password(&req.old_password, &stored.salt) {
        return json_response(StatusCode::UNAUTHORIZED, &ErrorResponse{ error: "Invalid credentials".to_string() });
    }
    if req.new_password.len() < 8 {
        return json_response(StatusCode::BAD_REQUEST, &ErrorResponse{ error: "Password too short".to_string() });
    }
    // update
    let new_hash = hash_password(&req.new_password, &stored.salt);
    if let Some(entry) = s.users_by_id.get_mut(&uid) { entry.password_hash = new_hash.clone(); }
    if let Some(entry) = s.users_by_username.get_mut(&stored.user.username) { entry.password_hash = new_hash; }
    json_response(StatusCode::OK, &serde_json::json!({}))
}

#[derive(Deserialize)]
struct CreateTodoReq { title: Option<String>, description: Option<String> }

async fn list_todos(State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let mut s = state.0.lock().unwrap();
    let uid = match extract_user_id_from_cookie(&mut s, &headers) { Ok(id)=>id, Err(resp)=> return resp };
    let todos = s.todos.get(&uid).cloned().unwrap_or_default();
    let mut todos_sorted = todos;
    todos_sorted.sort_by_key(|t| t.id);
    json_response(StatusCode::OK, &todos_sorted)
}

async fn create_todo(State(state): State<SharedState>, headers: HeaderMap, Json(req): Json<CreateTodoReq>) -> Response {
    let mut s = state.0.lock().unwrap();
    let uid = match extract_user_id_from_cookie(&mut s, &headers) { Ok(id)=>id, Err(resp)=> return resp };
    let title = match req.title { Some(t) if !t.trim().is_empty() => t, _ => {
        return json_response(StatusCode::BAD_REQUEST, &ErrorResponse{ error: "Title is required".to_string() });
    }};
    let description = req.description.unwrap_or_else(|| "".to_string());
    let id = s.next_todo_id.entry(uid).or_insert(1);
    let now = now_iso();
    let todo = Todo{ id: *id, title, description, completed: false, created_at: now.clone(), updated_at: now };
    *id += 1;
    s.todos.entry(uid).or_insert_with(Vec::new).push(todo.clone());
    json_response(StatusCode::CREATED, &todo)
}

async fn get_todo(State(state): State<SharedState>, headers: HeaderMap, Path(id): Path<u64>) -> Response {
    let mut s = state.0.lock().unwrap();
    let uid = match extract_user_id_from_cookie(&mut s, &headers) { Ok(id)=>id, Err(resp)=> return resp };
    if let Some(list) = s.todos.get(&uid) {
        if let Some(todo) = list.iter().find(|t| t.id == id) { return json_response(StatusCode::OK, todo); }
    }
    json_response(StatusCode::NOT_FOUND, &ErrorResponse{ error: "Todo not found".to_string() })
}

#[derive(Deserialize)]
struct UpdateTodoReq { title: Option<String>, description: Option<String>, completed: Option<bool> }

async fn update_todo(State(state): State<SharedState>, headers: HeaderMap, Path(id): Path<u64>, Json(req): Json<UpdateTodoReq>) -> Response {
    let mut s = state.0.lock().unwrap();
    let uid = match extract_user_id_from_cookie(&mut s, &headers) { Ok(id)=>id, Err(resp)=> return resp };
    if let Some(list) = s.todos.get_mut(&uid) {
        if let Some(todo) = list.iter_mut().find(|t| t.id == id) {
            if let Some(t) = req.title {
                if t.trim().is_empty() { return json_response(StatusCode::BAD_REQUEST, &ErrorResponse{ error: "Title is required".to_string() }); }
                todo.title = t;
            }
            if let Some(d) = req.description { todo.description = d; }
            if let Some(c) = req.completed { todo.completed = c; }
            todo.updated_at = now_iso();
            return json_response(StatusCode::OK, todo);
        }
    }
    json_response(StatusCode::NOT_FOUND, &ErrorResponse{ error: "Todo not found".to_string() })
}

async fn delete_todo(State(state): State<SharedState>, headers: HeaderMap, Path(id): Path<u64>) -> Response {
    let mut s = state.0.lock().unwrap();
    let uid = match extract_user_id_from_cookie(&mut s, &headers) { Ok(id)=>id, Err(resp)=> return resp };
    if let Some(list) = s.todos.get_mut(&uid) {
        if let Some(pos) = list.iter().position(|t| t.id == id) {
            list.remove(pos);
            // 204 No Content, and no body, but still ensure Content-Type not required per spec for DELETE
            return Response::builder().status(StatusCode::NO_CONTENT).body(axum::body::Body::empty()).unwrap();
        }
    }
    json_response(StatusCode::NOT_FOUND, &ErrorResponse{ error: "Todo not found".to_string() })
}

#[tokio::main]
async fn main() {
    // parse --port PORT
    let mut port: u16 = 3000;
    let args = std::env::args().collect::<Vec<_>>();
    let mut i = 1;
    while i + 1 < args.len() {
        if args[i] == "--port" { if let Ok(p) = args[i+1].parse::<u16>() { port = p; } i += 2; } else { i += 1; }
    }

    let state = SharedState::new();

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(state);

    let addr = SocketAddr::from(([0,0,0,0], port));
    println!("listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
