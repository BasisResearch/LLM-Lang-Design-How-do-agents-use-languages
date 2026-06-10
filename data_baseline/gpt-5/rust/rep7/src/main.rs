use axum::{
    async_trait,
    extract::{FromRef, FromRequestParts, Path, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::Response,
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, net::SocketAddr, sync::{Arc, RwLock}};
use uuid::Uuid;

#[derive(Clone)]
struct AppState {
    inner: Arc<InnerState>,
}

struct InnerState {
    users: RwLock<HashMap<u64, UserRecord>>,
    usernames: RwLock<HashMap<String, u64>>, // username -> user_id
    sessions: RwLock<HashMap<String, u64>>, // session_id -> user_id
    next_user_id: RwLock<u64>,
    todos: RwLock<HashMap<u64, TodoRecord>>, // todo_id -> record
    user_todos: RwLock<HashMap<u64, Vec<u64>>>, // user_id -> sorted list of todo ids
    next_todo_id: RwLock<u64>,
}

#[derive(Clone, Serialize)]
struct UserOut {
    id: u64,
    username: String,
}

#[derive(Clone)]
struct UserRecord {
    id: u64,
    username: String,
    password: String,
}

#[derive(Clone, Serialize)]
struct TodoOut {
    id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone)]
struct TodoRecord {
    id: u64,
    user_id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

impl From<&UserRecord> for UserOut {
    fn from(u: &UserRecord) -> Self { Self { id: u.id, username: u.username.clone() } }
}

impl From<&TodoRecord> for TodoOut {
    fn from(t: &TodoRecord) -> Self {
        Self { id: t.id, title: t.title.clone(), description: t.description.clone(), completed: t.completed, created_at: t.created_at.clone(), updated_at: t.updated_at.clone() }
    }
}

#[derive(Deserialize)]
struct RegisterInput { username: String, password: String }

#[derive(Deserialize)]
struct LoginInput { username: String, password: String }

#[derive(Deserialize)]
struct PasswordChangeInput { old_password: String, new_password: String }

#[derive(Deserialize)]
struct TodoCreateInput { title: Option<String>, description: Option<String> }

#[derive(Deserialize)]
struct TodoUpdateInput { title: Option<String>, description: Option<String>, completed: Option<bool> }

#[derive(Debug)]
struct AuthSession { uid: u64, token: String }

#[async_trait]
impl<S> FromRequestParts<S> for AuthSession
where
    AppState: FromRef<S>,
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request_parts(parts: &mut axum::http::request::Parts, state: &S) -> Result<Self, Self::Rejection> {
        let app_state = AppState::from_ref(state);
        let headers = &parts.headers;
        let cookies = headers.get(header::COOKIE).and_then(|v| v.to_str().ok()).unwrap_or("");
        let mut found: Option<(u64, String)> = None;
        for cookie in cookies.split(';') {
            let c = cookie.trim();
            if let Some(val) = c.strip_prefix("session_id=") {
                let sid = val.to_string();
                let sessions = app_state.inner.sessions.read().unwrap();
                if let Some(uid) = sessions.get(&sid) { found = Some((*uid, sid)); }
                break;
            }
        }
        if let Some((uid, token)) = found {
            Ok(AuthSession { uid, token })
        } else {
            Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required"))
        }
    }
}

fn now_iso() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn json_response<T: Serialize>(status: StatusCode, value: &T) -> Response {
    let body = serde_json::to_vec(value).unwrap();
    Response::builder().status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(axum::body::Body::from(body))
        .unwrap()
}

fn json_error(status: StatusCode, msg: &str) -> Response {
    json_response(status, &serde_json::json!({"error": msg}))
}

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let mut port: u16 = 8000;
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(p) = args.next() { port = p.parse().expect("Invalid port"); }
        }
    }

    let state = AppState { inner: Arc::new(InnerState {
        users: RwLock::new(HashMap::new()),
        usernames: RwLock::new(HashMap::new()),
        sessions: RwLock::new(HashMap::new()),
        next_user_id: RwLock::new(1),
        todos: RwLock::new(HashMap::new()),
        user_todos: RwLock::new(HashMap::new()),
        next_todo_id: RwLock::new(1),
    }) };

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
    axum::serve(listener, app.into_make_service()).await.unwrap();
}

async fn register(State(state): State<AppState>, Json(input): Json<RegisterInput>) -> Response {
    // Validate username
    let re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !re.is_match(&input.username) {
        return json_error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if input.password.len() < 8 { return json_error(StatusCode::BAD_REQUEST, "Password too short"); }

    // Check uniqueness
    {
        let usernames = state.inner.usernames.read().unwrap();
        if usernames.contains_key(&input.username) {
            return json_error(StatusCode::CONFLICT, "Username already exists");
        }
    }

    // Create user
    let user = {
        let mut next_id = state.inner.next_user_id.write().unwrap();
        let id = *next_id; *next_id += 1;
        UserRecord { id, username: input.username.clone(), password: input.password.clone() }
    };
    {
        let mut users = state.inner.users.write().unwrap();
        users.insert(user.id, user.clone());
    }
    {
        let mut usernames = state.inner.usernames.write().unwrap();
        usernames.insert(user.username.clone(), user.id);
    }

    let out: UserOut = (&user).into();
    json_response(StatusCode::CREATED, &out)
}

async fn login(State(state): State<AppState>, Json(input): Json<LoginInput>) -> Response {
    // Find user
    let uid_opt = {
        let usernames = state.inner.usernames.read().unwrap();
        usernames.get(&input.username).copied()
    };
    let uid = match uid_opt { Some(u) => u, None => return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials") };
    let user_ok = {
        let users = state.inner.users.read().unwrap();
        users.get(&uid).map(|u| u.password == input.password).unwrap_or(false)
    };
    if !user_ok { return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials"); }

    // Create session
    let token = Uuid::new_v4().to_string();
    {
        let mut sessions = state.inner.sessions.write().unwrap();
        sessions.insert(token.clone(), uid);
    }

    let out = {
        let users = state.inner.users.read().unwrap();
        let u = users.get(&uid).unwrap();
        UserOut::from(u)
    };

    let body = serde_json::to_vec(&out).unwrap();
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::SET_COOKIE, format!("session_id={}; Path=/; HttpOnly", token))
        .body(axum::body::Body::from(body))
        .unwrap()
}

async fn logout(State(state): State<AppState>, AuthSession { uid: _, token }: AuthSession) -> Response {
    // Invalidate the session token used for this request
    let mut sessions = state.inner.sessions.write().unwrap();
    sessions.remove(&token);
    json_response(StatusCode::OK, &serde_json::json!({}))
}

async fn me(State(state): State<AppState>, AuthSession { uid, .. }: AuthSession) -> Response {
    let users = state.inner.users.read().unwrap();
    if let Some(u) = users.get(&uid) {
        json_response(StatusCode::OK, &UserOut::from(u))
    } else {
        json_error(StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

async fn change_password(State(state): State<AppState>, AuthSession { uid, .. }: AuthSession, Json(input): Json<PasswordChangeInput>) -> Response {
    if input.new_password.len() < 8 { return json_error(StatusCode::BAD_REQUEST, "Password too short"); }
    let mut users = state.inner.users.write().unwrap();
    if let Some(user) = users.get_mut(&uid) {
        if user.password != input.old_password {
            return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
        }
        user.password = input.new_password.clone();
        json_response(StatusCode::OK, &serde_json::json!({}))
    } else {
        json_error(StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

async fn list_todos(State(state): State<AppState>, AuthSession { uid, .. }: AuthSession) -> Response {
    let todo_ids = {
        let ut = state.inner.user_todos.read().unwrap();
        ut.get(&uid).cloned().unwrap_or_default()
    };
    let todos_map = state.inner.todos.read().unwrap();
    let mut todos: Vec<TodoOut> = todo_ids.into_iter().filter_map(|id| todos_map.get(&id).map(|t| TodoOut::from(t))).collect();
    todos.sort_by_key(|t| t.id);
    json_response(StatusCode::OK, &todos)
}

async fn create_todo(State(state): State<AppState>, AuthSession { uid, .. }: AuthSession, Json(input): Json<TodoCreateInput>) -> Response {
    let title = match input.title { Some(ref t) if !t.trim().is_empty() => t.trim().to_string(), _ => return json_error(StatusCode::BAD_REQUEST, "Title is required") };
    let description = input.description.unwrap_or_else(|| "".to_string());
    let now = now_iso();
    let todo = {
        let mut next_id = state.inner.next_todo_id.write().unwrap();
        let id = *next_id; *next_id += 1;
        TodoRecord { id, user_id: uid, title, description, completed: false, created_at: now.clone(), updated_at: now.clone() }
    };
    {
        let mut todos = state.inner.todos.write().unwrap();
        todos.insert(todo.id, todo.clone());
    }
    {
        let mut ut = state.inner.user_todos.write().unwrap();
        ut.entry(uid).or_default().push(todo.id);
    }
    json_response(StatusCode::CREATED, &TodoOut::from(&todo))
}

async fn get_todo(State(state): State<AppState>, AuthSession { uid, .. }: AuthSession, Path(id): Path<u64>) -> Response {
    let todos = state.inner.todos.read().unwrap();
    if let Some(t) = todos.get(&id) {
        if t.user_id != uid { return json_error(StatusCode::NOT_FOUND, "Todo not found"); }
        json_response(StatusCode::OK, &TodoOut::from(t))
    } else {
        json_error(StatusCode::NOT_FOUND, "Todo not found")
    }
}

async fn update_todo(State(state): State<AppState>, AuthSession { uid, .. }: AuthSession, Path(id): Path<u64>, Json(input): Json<TodoUpdateInput>) -> Response {
    let mut todos = state.inner.todos.write().unwrap();
    if let Some(t) = todos.get_mut(&id) {
        if t.user_id != uid { return json_error(StatusCode::NOT_FOUND, "Todo not found"); }
        if let Some(title) = input.title.as_ref() { if title.trim().is_empty() { return json_error(StatusCode::BAD_REQUEST, "Title is required"); } }
        if let Some(title) = input.title { t.title = title; }
        if let Some(desc) = input.description { t.description = desc; }
        if let Some(comp) = input.completed { t.completed = comp; }
        t.updated_at = now_iso();
        let out = TodoOut::from(&t.clone());
        json_response(StatusCode::OK, &out)
    } else {
        json_error(StatusCode::NOT_FOUND, "Todo not found")
    }
}

async fn delete_todo(State(state): State<AppState>, AuthSession { uid, .. }: AuthSession, Path(id): Path<u64>) -> Response {
    // Ensure 204 with no body
    let mut removed = false;
    {
        let mut todos = state.inner.todos.write().unwrap();
        if let Some(t) = todos.get(&id) {
            if t.user_id != uid { return json_error(StatusCode::NOT_FOUND, "Todo not found"); }
        } else {
            return json_error(StatusCode::NOT_FOUND, "Todo not found");
        }
        if let Some(_t) = todos.remove(&id) { 
            removed = true; 
            let mut ut = state.inner.user_todos.write().unwrap(); 
            if let Some(list) = ut.get_mut(&uid) { if let Some(pos) = list.iter().position(|x| *x == id) { list.remove(pos); } }
        }
    }
    if removed {
        Response::builder().status(StatusCode::NO_CONTENT).body(axum::body::Body::empty()).unwrap()
    } else {
        json_error(StatusCode::NOT_FOUND, "Todo not found")
    }
}
