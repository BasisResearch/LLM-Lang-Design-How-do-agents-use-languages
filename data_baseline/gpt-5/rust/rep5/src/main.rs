use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router,
};
use axum_extra::extract::cookie::{Cookie, CookieJar};
use chrono::{SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, net::SocketAddr, sync::{Arc, Mutex}};
use uuid::Uuid;

#[derive(Clone)]
struct AppState {
    inner: Arc<Mutex<Inner>>,
}

struct Inner {
    next_user_id: i64,
    next_todo_id: i64,
    users: HashMap<i64, UserRecord>,
    username_index: HashMap<String, i64>,
    sessions: HashMap<String, i64>, // session_id -> user_id
    todos: HashMap<i64, TodoRecord>,
}

#[derive(Clone, Serialize)]
struct UserPublic { id: i64, username: String }

#[derive(Clone)]
struct UserRecord { id: i64, username: String, password: String }

#[derive(Clone, Serialize)]
struct TodoPublic {
    id: i64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone)]
struct TodoRecord {
    id: i64,
    user_id: i64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Deserialize)]
struct RegisterBody { username: String, password: String }

#[derive(Deserialize)]
struct LoginBody { username: String, password: String }

#[derive(Deserialize)]
struct PasswordChangeBody { old_password: String, new_password: String }

#[derive(Deserialize)]
struct CreateTodoBody { title: String, #[serde(default)] description: String }

#[derive(Deserialize)]
struct UpdateTodoBody { #[serde(default)] title: Option<String>, #[serde(default)] description: Option<String>, #[serde(default)] completed: Option<bool> }

#[derive(Serialize)]
struct ErrorResp { error: String }

impl AppState {
    fn new() -> Self {
        Self { inner: Arc::new(Mutex::new(Inner { next_user_id: 1, next_todo_id: 1, users: HashMap::new(), username_index: HashMap::new(), sessions: HashMap::new(), todos: HashMap::new() })) }
    }
}

fn json_response<T: Serialize>(value: &T, status: StatusCode) -> Response {
    let body = serde_json::to_string(value).unwrap();
    let mut resp = Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .body(axum::body::Body::from(body))
        .unwrap();
    resp
}

fn empty_json(status: StatusCode) -> Response {
    let mut resp = Response::builder()
        .status(status)
        .header("Content-Type", "application/json")
        .body(axum::body::Body::from("{}"))
        .unwrap();
    resp
}

fn error(status: StatusCode, msg: &str) -> Response {
    json_response(&ErrorResp { error: msg.to_string() }, status)
}

fn now_ts() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn validate_username(name: &str) -> bool {
    if name.len() < 3 || name.len() > 50 { return false; }
    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    re.is_match(name)
}

async fn register_handler(State(state): State<AppState>, Json(body): Json<RegisterBody>) -> Response {
    if !validate_username(&body.username) { return error(StatusCode::BAD_REQUEST, "Invalid username"); }
    if body.password.len() < 8 { return error(StatusCode::BAD_REQUEST, "Password too short"); }
    let mut inner = state.inner.lock().unwrap();
    if inner.username_index.contains_key(&body.username) {
        return error(StatusCode::CONFLICT, "Username already exists");
    }
    let id = inner.next_user_id;
    inner.next_user_id += 1;
    let user = UserRecord { id, username: body.username.clone(), password: body.password.clone() };
    inner.username_index.insert(body.username.clone(), id);
    inner.users.insert(id, user.clone());
    let public = UserPublic { id, username: user.username };
    json_response(&public, StatusCode::CREATED)
}

async fn login_handler(State(state): State<AppState>, jar: CookieJar, Json(body): Json<LoginBody>) -> (CookieJar, Response) {
    let mut jar = jar;
    let mut inner = state.inner.lock().unwrap();
    let uid = match inner.username_index.get(&body.username).and_then(|id| inner.users.get(id)).filter(|u| u.password == body.password) {
        Some(u) => u.id,
        None => {
            let resp = error(StatusCode::UNAUTHORIZED, "Invalid credentials");
            return (jar, resp);
        }
    };
    let token = Uuid::new_v4().to_string();
    inner.sessions.insert(token.clone(), uid);
    let cookie = Cookie::build(("session_id", token.clone()))
        .path("/")
        .http_only(true)
        .build();
    jar = jar.add(cookie);
    let public = {
        let u = inner.users.get(&uid).unwrap();
        UserPublic { id: u.id, username: u.username.clone() }
    };
    (jar, json_response(&public, StatusCode::OK))
}

fn auth_user_id(jar: &CookieJar, state: &AppState) -> Option<i64> {
    let cookie = jar.get("session_id")?;
    let token = cookie.value().to_string();
    let inner = state.inner.lock().unwrap();
    inner.sessions.get(&token).cloned()
}

async fn logout_handler(State(state): State<AppState>, jar: CookieJar) -> (CookieJar, Response) {
    let mut jar = jar;
    let token_opt = jar.get("session_id").map(|c| c.value().to_string());
    let mut inner = state.inner.lock().unwrap();
    let uid = match token_opt.as_ref().and_then(|t| inner.sessions.get(t)).cloned() {
        Some(u) => u,
        None => {
            let resp = error(StatusCode::UNAUTHORIZED, "Authentication required");
            return (jar, resp);
        }
    };
    if let Some(token) = token_opt { inner.sessions.remove(&token); }
    // Optional: remove cookie client-side too (but spec doesn't require); keep Set-Cookie clearing not required
    (jar, empty_json(StatusCode::OK))
}

async fn me_handler(State(state): State<AppState>, jar: CookieJar) -> Response {
    let uid = match auth_user_id(&jar, &state) { Some(id) => id, None => return error(StatusCode::UNAUTHORIZED, "Authentication required") };
    let inner = state.inner.lock().unwrap();
    let u = inner.users.get(&uid).unwrap();
    json_response(&UserPublic { id: u.id, username: u.username.clone() }, StatusCode::OK)
}

async fn password_handler(State(state): State<AppState>, jar: CookieJar, Json(body): Json<PasswordChangeBody>) -> Response {
    let uid = match auth_user_id(&jar, &state) { Some(id) => id, None => return error(StatusCode::UNAUTHORIZED, "Authentication required") };
    if body.new_password.len() < 8 { return error(StatusCode::BAD_REQUEST, "Password too short"); }
    let mut inner = state.inner.lock().unwrap();
    let u = inner.users.get_mut(&uid).unwrap();
    if u.password != body.old_password { return error(StatusCode::UNAUTHORIZED, "Invalid credentials"); }
    u.password = body.new_password.clone();
    empty_json(StatusCode::OK)
}

async fn list_todos_handler(State(state): State<AppState>, jar: CookieJar) -> Response {
    let uid = match auth_user_id(&jar, &state) { Some(id) => id, None => return error(StatusCode::UNAUTHORIZED, "Authentication required") };
    let inner = state.inner.lock().unwrap();
    let mut todos: Vec<TodoPublic> = inner.todos.values()
        .filter(|t| t.user_id == uid)
        .map(|t| TodoPublic { id: t.id, title: t.title.clone(), description: t.description.clone(), completed: t.completed, created_at: t.created_at.clone(), updated_at: t.updated_at.clone() })
        .collect();
    todos.sort_by_key(|t| t.id);
    json_response(&todos, StatusCode::OK)
}

async fn create_todo_handler(State(state): State<AppState>, jar: CookieJar, Json(body): Json<CreateTodoBody>) -> Response {
    let uid = match auth_user_id(&jar, &state) { Some(id) => id, None => return error(StatusCode::UNAUTHORIZED, "Authentication required") };
    if body.title.trim().is_empty() { return error(StatusCode::BAD_REQUEST, "Title is required"); }
    let mut inner = state.inner.lock().unwrap();
    let id = inner.next_todo_id; inner.next_todo_id += 1;
    let now = now_ts();
    let rec = TodoRecord { id, user_id: uid, title: body.title.clone(), description: body.description.clone(), completed: false, created_at: now.clone(), updated_at: now.clone() };
    inner.todos.insert(id, rec.clone());
    let pubt = TodoPublic { id: rec.id, title: rec.title, description: rec.description, completed: rec.completed, created_at: rec.created_at, updated_at: rec.updated_at };
    json_response(&pubt, StatusCode::CREATED)
}

fn not_found_todo() -> Response { error(StatusCode::NOT_FOUND, "Todo not found") }

async fn get_todo_handler(State(state): State<AppState>, jar: CookieJar, Path(id): Path<i64>) -> Response {
    let uid = match auth_user_id(&jar, &state) { Some(id) => id, None => return error(StatusCode::UNAUTHORIZED, "Authentication required") };
    let inner = state.inner.lock().unwrap();
    match inner.todos.get(&id).filter(|t| t.user_id == uid) {
        Some(t) => json_response(&TodoPublic { id: t.id, title: t.title.clone(), description: t.description.clone(), completed: t.completed, created_at: t.created_at.clone(), updated_at: t.updated_at.clone() }, StatusCode::OK),
        None => not_found_todo(),
    }
}

async fn update_todo_handler(State(state): State<AppState>, jar: CookieJar, Path(id): Path<i64>, Json(body): Json<UpdateTodoBody>) -> Response {
    let uid = match auth_user_id(&jar, &state) { Some(id) => id, None => return error(StatusCode::UNAUTHORIZED, "Authentication required") };
    let mut inner = state.inner.lock().unwrap();
    let rec = match inner.todos.get_mut(&id) { Some(r) => r, None => return not_found_todo() };
    if rec.user_id != uid { return not_found_todo(); }
    if let Some(t) = body.title.as_ref() { if t.trim().is_empty() { return error(StatusCode::BAD_REQUEST, "Title is required"); } }
    if let Some(t) = body.title { rec.title = t; }
    if let Some(d) = body.description { rec.description = d; }
    if let Some(c) = body.completed { rec.completed = c; }
    rec.updated_at = now_ts();
    let pubt = TodoPublic { id: rec.id, title: rec.title.clone(), description: rec.description.clone(), completed: rec.completed, created_at: rec.created_at.clone(), updated_at: rec.updated_at.clone() };
    json_response(&pubt, StatusCode::OK)
}

async fn delete_todo_handler(State(state): State<AppState>, jar: CookieJar, Path(id): Path<i64>) -> Response {
    let uid = match auth_user_id(&jar, &state) { Some(id) => id, None => return error(StatusCode::UNAUTHORIZED, "Authentication required") };
    let mut inner = state.inner.lock().unwrap();
    match inner.todos.get(&id).cloned() {
        Some(t) if t.user_id == uid => {
            inner.todos.remove(&id);
            Response::builder().status(StatusCode::NO_CONTENT).body(axum::body::Body::empty()).unwrap()
        }
        _ => not_found_todo(),
    }
}

#[tokio::main]
async fn main() {
    let mut port = 8080u16;
    let mut args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.len() >= 2 && args[0] == "--port" {
        if let Ok(p) = args[1].parse::<u16>() { port = p; }
    }

    let state = AppState::new();

    let app = Router::new()
        .route("/register", post(register_handler))
        .route("/login", post(login_handler))
        .route("/logout", post(logout_handler))
        .route("/me", get(me_handler))
        .route("/password", put(password_handler))
        .route("/todos", get(list_todos_handler).post(create_todo_handler))
        .route("/todos/:id", get(get_todo_handler).put(update_todo_handler).delete(delete_todo_handler))
        .with_state(state);

    let addr = SocketAddr::from(([0,0,0,0], port));
    println!("Listening on {}", addr);
    axum::serve(tokio::net::TcpListener::bind(addr).await.unwrap(), app).await.unwrap();
}
