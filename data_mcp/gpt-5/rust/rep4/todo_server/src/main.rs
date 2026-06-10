use axum::{
    async_trait,
    extract::{FromRequestParts, Path, State},
    http::{header, request::Parts, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use tokio::net::TcpListener;
use uuid::Uuid;

#[derive(Clone, Debug)]
struct AppState {
    inner: Arc<Mutex<DataStore>>,
}

#[derive(Debug)]
struct DataStore {
    users: HashMap<i32, UserInternal>,
    users_by_name: HashMap<String, i32>,
    sessions: HashMap<String, i32>,
    todos: HashMap<i32, Vec<Todo>>, // by user id, keep vector ordered by id asc
    next_user_id: i32,
    next_todo_id: i32,
}

#[derive(Debug, Clone, Serialize)]
struct UserPublic {
    id: i32,
    username: String,
}

#[derive(Debug, Clone)]
struct UserInternal {
    id: i32,
    username: String,
    password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Todo {
    id: i32,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: String,
}

impl IntoResponse for ErrorResponse {
    fn into_response(self) -> Response {
        let body = Json(self);
        let mut resp = (StatusCode::BAD_REQUEST, body).into_response();
        ensure_json_content_type(&mut resp);
        resp
    }
}

fn ensure_json_content_type(resp: &mut Response) {
    if resp.status() != StatusCode::NO_CONTENT {
        let headers = resp.headers_mut();
        headers.insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
    }
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let mut port: u16 = 3000;
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(p) = args.next() {
                port = p.parse().unwrap_or(3000);
            }
        }
    }

    let state = AppState {
        inner: Arc::new(Mutex::new(DataStore {
            users: HashMap::new(),
            users_by_name: HashMap::new(),
            sessions: HashMap::new(),
            todos: HashMap::new(),
            next_user_id: 1,
            next_todo_id: 1,
        })),
    };

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(state.clone());

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    println!("listening on {}", addr);
    let listener = TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

fn json_error(status: StatusCode, msg: &str) -> Response {
    let body = Json(ErrorResponse {
        error: msg.to_string(),
    });
    let mut resp = (status, body).into_response();
    ensure_json_content_type(&mut resp);
    resp
}

struct AuthUser(i32);

#[async_trait]
impl FromRequestParts<AppState> for AuthUser {
    type Rejection = Response;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let cookies = parts.headers.get(header::COOKIE);
        let Some(raw_cookie) = cookies else {
            return Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required"));
        };
        let raw = raw_cookie.to_str().unwrap_or("");
        let mut user_id: Option<i32> = None;
        for pair in raw.split(';') {
            let trimmed = pair.trim();
            if let Some(rest) = trimmed.strip_prefix("session_id=") {
                let token = rest.to_string();
                let store = state.inner.lock().unwrap();
                user_id = store.sessions.get(&token).cloned();
                break;
            }
        }
        match user_id {
            Some(uid) => Ok(AuthUser(uid)),
            None => Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required")),
        }
    }
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: String,
    password: String,
}

fn valid_username(name: &str) -> bool {
    if name.len() < 3 || name.len() > 50 {
        return false;
    }
    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    re.is_match(name)
}

async fn register(State(state): State<AppState>, Json(payload): Json<RegisterRequest>) -> Response {
    if !valid_username(&payload.username) {
        return json_error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if payload.password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut store = state.inner.lock().unwrap();
    if store.users_by_name.contains_key(&payload.username) {
        return json_error(StatusCode::CONFLICT, "Username already exists");
    }
    let id = store.next_user_id;
    store.next_user_id += 1;
    let user_internal = UserInternal {
        id,
        username: payload.username.clone(),
        password: payload.password.clone(),
    };
    store.users.insert(id, user_internal.clone());
    store
        .users_by_name
        .insert(payload.username.clone(), id);

    let user_pub = UserPublic {
        id,
        username: payload.username,
    };

    let mut resp = (StatusCode::CREATED, Json(user_pub)).into_response();
    ensure_json_content_type(&mut resp);
    resp
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

async fn login(State(state): State<AppState>, Json(payload): Json<LoginRequest>) -> Response {
    // First, verify credentials under immutable borrow
    let (uid, username) = {
        let store = state.inner.lock().unwrap();
        let Some(&uid) = store.users_by_name.get(&payload.username) else {
            return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
        };
        let user = store.users.get(&uid).unwrap();
        if user.password != payload.password {
            return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
        }
        (uid, user.username.clone())
    };
    // Now create a session under mutable borrow
    let token = Uuid::new_v4().to_string();
    {
        let mut store = state.inner.lock().unwrap();
        store.sessions.insert(token.clone(), uid);
    }
    let user_pub = UserPublic { id: uid, username };

    let mut resp = (StatusCode::OK, Json(user_pub)).into_response();
    let cookie = format!("session_id={}; Path=/; HttpOnly", token);
    resp.headers_mut()
        .insert(header::SET_COOKIE, HeaderValue::from_str(&cookie).unwrap());
    ensure_json_content_type(&mut resp);
    resp
}

async fn logout(State(state): State<AppState>, AuthUser(_uid): AuthUser, headers: HeaderMap) -> Response {
    let cookie_header = headers.get(header::COOKIE).and_then(|v| v.to_str().ok());
    if let Some(raw) = cookie_header {
        let mut token_opt: Option<String> = None;
        for part in raw.split(';') {
            let p = part.trim();
            if let Some(rest) = p.strip_prefix("session_id=") {
                token_opt = Some(rest.to_string());
                break;
            }
        }
        if let Some(token) = token_opt {
            let mut store = state.inner.lock().unwrap();
            store.sessions.remove(&token);
        }
    }
    let mut resp = (StatusCode::OK, Json(serde_json::json!({}))).into_response();
    ensure_json_content_type(&mut resp);
    resp
}

async fn me(State(state): State<AppState>, AuthUser(uid): AuthUser) -> Response {
    let store = state.inner.lock().unwrap();
    if let Some(user) = store.users.get(&uid) {
        let user_pub = UserPublic {
            id: user.id,
            username: user.username.clone(),
        };
        let mut resp = (StatusCode::OK, Json(user_pub)).into_response();
        ensure_json_content_type(&mut resp);
        return resp;
    }
    json_error(StatusCode::UNAUTHORIZED, "Authentication required")
}

#[derive(Deserialize)]
struct PasswordChange {
    old_password: String,
    new_password: String,
}

async fn change_password(State(state): State<AppState>, AuthUser(uid): AuthUser, Json(payload): Json<PasswordChange>) -> Response {
    if payload.new_password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }
    let mut store = state.inner.lock().unwrap();
    let user = store.users.get_mut(&uid).unwrap();
    if user.password != payload.old_password {
        return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
    }
    user.password = payload.new_password;
    let mut resp = (StatusCode::OK, Json(serde_json::json!({}))).into_response();
    ensure_json_content_type(&mut resp);
    resp
}

fn now_iso8601() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[derive(Deserialize)]
struct CreateTodoRequest {
    title: String,
    #[serde(default)]
    description: String,
}

async fn list_todos(State(state): State<AppState>, AuthUser(uid): AuthUser) -> Response {
    let store = state.inner.lock().unwrap();
    let list = store.todos.get(&uid).cloned().unwrap_or_default();
    let mut resp = (StatusCode::OK, Json(list)).into_response();
    ensure_json_content_type(&mut resp);
    resp
}

async fn create_todo(State(state): State<AppState>, AuthUser(uid): AuthUser, Json(payload): Json<CreateTodoRequest>) -> Response {
    if payload.title.trim().is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "Title is required");
    }
    let mut store = state.inner.lock().unwrap();
    let id = store.next_todo_id;
    store.next_todo_id += 1;
    let ts = now_iso8601();
    let todo = Todo {
        id,
        title: payload.title.clone(),
        description: payload.description.clone(),
        completed: false,
        created_at: ts.clone(),
        updated_at: ts,
    };
    store.todos.entry(uid).or_default().push(todo.clone());
    let mut resp = (StatusCode::CREATED, Json(todo)).into_response();
    ensure_json_content_type(&mut resp);
    resp
}

async fn get_todo(State(state): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<i32>) -> Response {
    let store = state.inner.lock().unwrap();
    if let Some(list) = store.todos.get(&uid) {
        if let Some(todo) = list.iter().find(|t| t.id == id) {
            let mut resp = (StatusCode::OK, Json(todo.clone())).into_response();
            ensure_json_content_type(&mut resp);
            return resp;
        }
    }
    json_error(StatusCode::NOT_FOUND, "Todo not found")
}

#[derive(Deserialize, Default)]
struct UpdateTodoRequest {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    completed: Option<bool>,
}

async fn update_todo(State(state): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<i32>, Json(payload): Json<UpdateTodoRequest>) -> Response {
    let mut store = state.inner.lock().unwrap();
    let list = store.todos.get_mut(&uid);
    if list.is_none() {
        return json_error(StatusCode::NOT_FOUND, "Todo not found");
    }
    let list = list.unwrap();
    let Some(todo) = list.iter_mut().find(|t| t.id == id) else {
        return json_error(StatusCode::NOT_FOUND, "Todo not found");
    };
    if let Some(title) = payload.title {
        if title.trim().is_empty() {
            return json_error(StatusCode::BAD_REQUEST, "Title is required");
        }
        todo.title = title;
    }
    if let Some(desc) = payload.description {
        todo.description = desc;
    }
    if let Some(comp) = payload.completed {
        todo.completed = comp;
    }
    todo.updated_at = now_iso8601();
    let mut resp = (StatusCode::OK, Json(todo.clone())).into_response();
    ensure_json_content_type(&mut resp);
    resp
}

async fn delete_todo(State(state): State<AppState>, AuthUser(uid): AuthUser, Path(id): Path<i32>) -> Response {
    let mut store = state.inner.lock().unwrap();
    let list = store.todos.get_mut(&uid);
    if list.is_none() {
        return json_error(StatusCode::NOT_FOUND, "Todo not found");
    }
    let list = list.unwrap();
    let len_before = list.len();
    list.retain(|t| t.id != id);
    if list.len() == len_before {
        return json_error(StatusCode::NOT_FOUND, "Todo not found");
    }
    (StatusCode::NO_CONTENT).into_response()
}
