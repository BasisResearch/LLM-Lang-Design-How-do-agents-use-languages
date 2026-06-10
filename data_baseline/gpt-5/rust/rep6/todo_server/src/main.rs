use std::{collections::HashMap, net::SocketAddr, sync::Arc};

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{delete, get, post, put},
    Json, Router,
};
use axum::serve;
use axum_extra::extract::CookieJar;
use regex::Regex;
use serde::{Deserialize, Serialize};
use time::{format_description::FormatItem, macros::format_description, OffsetDateTime};
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Clone)]
struct AppState {
    users: Arc<RwLock<HashMap<i64, UserRecord>>>,
    username_to_id: Arc<RwLock<HashMap<String, i64>>>,
    sessions: Arc<RwLock<HashMap<String, i64>>>,
    todos: Arc<RwLock<HashMap<i64, TodoRecord>>>,
    next_user_id: Arc<RwLock<i64>>, // starting at 1
    next_todo_id: Arc<RwLock<i64>>, // starting at 1
}

#[derive(Clone, Serialize)]
struct UserPublic {
    id: i64,
    username: String,
}

#[derive(Clone)]
struct UserRecord {
    id: i64,
    username: String,
    password: String, // stored in-memory, plaintext per spec simplicity
}

#[derive(Clone, Serialize, Deserialize)]
struct Todo {
    id: i64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone)]
struct TodoRecord {
    owner_id: i64,
    data: Todo,
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct PasswordChangeRequest {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize)]
struct NewTodoRequest {
    title: Option<String>,
    description: Option<String>,
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

const SESSION_COOKIE_NAME: &str = "session_id";

fn now_iso8601_utc_seconds() -> String {
    // Format: YYYY-MM-DDTHH:MM:SSZ
    static FMT: &[FormatItem<'_>] = format_description!("[year]-[month]-[day]T[hour]:[minute]:[second]Z");
    OffsetDateTime::now_utc().format(&FMT).unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn json_error(status: StatusCode, msg: &str) -> (StatusCode, Json<serde_json::Value>) {
    (status, Json(serde_json::json!({"error": msg})))
}

async fn auth_user(jar: &CookieJar, state: &AppState) -> Result<i64, (StatusCode, Json<serde_json::Value>)> {
    if let Some(cookie) = jar.get(SESSION_COOKIE_NAME) {
        let token = cookie.value().to_string();
        let sessions = state.sessions.read().await;
        if let Some(uid) = sessions.get(&token) {
            return Ok(*uid);
        }
    }
    Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required"))
}

fn to_public_user(user: &UserRecord) -> UserPublic {
    UserPublic { id: user.id, username: user.username.clone() }
}

async fn register(State(state): State<AppState>, Json(payload): Json<RegisterRequest>) -> impl IntoResponse {
    // Validate username and password
    let username = payload.username.trim();
    let password = payload.password;

    let username_re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();

    if !username_re.is_match(username) {
        return json_error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }

    // Check uniqueness and create user
    {
        let mut username_to_id = state.username_to_id.write().await;
        if username_to_id.contains_key(username) {
            return json_error(StatusCode::CONFLICT, "Username already exists");
        }
        let mut users = state.users.write().await;
        let mut next_id = state.next_user_id.write().await;
        let id = *next_id;
        *next_id += 1;
        let record = UserRecord { id, username: username.to_string(), password };
        users.insert(id, record.clone());
        username_to_id.insert(username.to_string(), id);
        let public = to_public_user(&record);
        return (StatusCode::CREATED, Json(serde_json::to_value(public).unwrap()));
    }
}

async fn login(State(state): State<AppState>, jar: CookieJar, Json(payload): Json<LoginRequest>) -> impl IntoResponse {
    let username = payload.username;
    let password = payload.password;

    // Lookup user
    let user_id_opt = {
        let map = state.username_to_id.read().await;
        map.get(&username).copied()
    };
    let user_id = match user_id_opt {
        Some(id) => id,
        None => return (jar, json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")),
    };
    let user = {
        let users = state.users.read().await;
        users.get(&user_id).cloned()
    };
    let user = match user {
        Some(u) => u,
        None => return (jar, json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")),
    };
    if user.password != password {
        return (jar, json_error(StatusCode::UNAUTHORIZED, "Invalid credentials"));
    }

    // Create session token
    let token = Uuid::new_v4().to_string();
    {
        let mut sessions = state.sessions.write().await;
        sessions.insert(token.clone(), user.id);
    }

    // Set cookie in jar
    let mut cookie = axum_extra::extract::cookie::Cookie::new(SESSION_COOKIE_NAME.to_string(), token);
    cookie.set_path("/");
    cookie.set_http_only(true);
    let new_jar = jar.add(cookie);

    let public = to_public_user(&user);

    (new_jar, (StatusCode::OK, Json(serde_json::to_value(public).unwrap())))
}

async fn logout(State(state): State<AppState>, jar: CookieJar) -> impl IntoResponse {
    match auth_user(&jar, &state).await {
        Ok(_) => {
            // Invalidate session
            if let Some(cookie) = jar.get(SESSION_COOKIE_NAME) {
                let token = cookie.value().to_string();
                let mut sessions = state.sessions.write().await;
                sessions.remove(&token);
            }
            (StatusCode::OK, Json(serde_json::json!({}))).into_response()
        }
        Err(e) => e.into_response(),
    }
}

async fn me(State(state): State<AppState>, jar: CookieJar) -> impl IntoResponse {
    let uid = match auth_user(&jar, &state).await { Ok(id) => id, Err(e) => return e.into_response() };
    let user = {
        let users = state.users.read().await;
        users.get(&uid).cloned()
    };
    if let Some(user) = user {
        let public = to_public_user(&user);
        (StatusCode::OK, Json(serde_json::to_value(public).unwrap())).into_response()
    } else {
        json_error(StatusCode::UNAUTHORIZED, "Authentication required").into_response()
    }
}

async fn change_password(State(state): State<AppState>, jar: CookieJar, Json(payload): Json<PasswordChangeRequest>) -> impl IntoResponse {
    let uid = match auth_user(&jar, &state).await { Ok(id) => id, Err(e) => return e.into_response() };

    if payload.new_password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short").into_response();
    }

    let mut users = state.users.write().await;
    let Some(user) = users.get_mut(&uid) else {
        return json_error(StatusCode::UNAUTHORIZED, "Authentication required").into_response();
    };

    if user.password != payload.old_password {
        return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials").into_response();
    }

    user.password = payload.new_password;
    (StatusCode::OK, Json(serde_json::json!({}))).into_response()
}

async fn list_todos(State(state): State<AppState>, jar: CookieJar) -> impl IntoResponse {
    let uid = match auth_user(&jar, &state).await { Ok(id) => id, Err(e) => return e.into_response() };

    let todos_map = state.todos.read().await;
    let mut list: Vec<Todo> = todos_map
        .values()
        .filter(|rec| rec.owner_id == uid)
        .map(|rec| rec.data.clone())
        .collect();
    list.sort_by_key(|t| t.id);
    (StatusCode::OK, Json(list)).into_response()
}

async fn create_todo(State(state): State<AppState>, jar: CookieJar, Json(payload): Json<NewTodoRequest>) -> impl IntoResponse {
    let uid = match auth_user(&jar, &state).await { Ok(id) => id, Err(e) => return e.into_response() };

    let title = payload.title.unwrap_or_default().trim().to_string();
    if title.is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "Title is required").into_response();
    }
    let description = payload.description.unwrap_or_else(|| "".to_string());

    let mut next_id = state.next_todo_id.write().await;
    let id = *next_id;
    *next_id += 1;

    let now = now_iso8601_utc_seconds();
    let todo = Todo { id, title, description, completed: false, created_at: now.clone(), updated_at: now };
    let rec = TodoRecord { owner_id: uid, data: todo.clone() };

    let mut todos_map = state.todos.write().await;
    todos_map.insert(id, rec);

    (StatusCode::CREATED, Json(todo)).into_response()
}

async fn get_todo(State(state): State<AppState>, jar: CookieJar, Path(id): Path<i64>) -> impl IntoResponse {
    let uid = match auth_user(&jar, &state).await { Ok(id) => id, Err(e) => return e.into_response() };

    let todos = state.todos.read().await;
    match todos.get(&id) {
        Some(rec) if rec.owner_id == uid => {
            (StatusCode::OK, Json(rec.data.clone())).into_response()
        }
        _ => json_error(StatusCode::NOT_FOUND, "Todo not found").into_response(),
    }
}

async fn update_todo(State(state): State<AppState>, jar: CookieJar, Path(id): Path<i64>, Json(payload): Json<UpdateTodoRequest>) -> impl IntoResponse {
    let uid = match auth_user(&jar, &state).await { Ok(id) => id, Err(e) => return e.into_response() };

    let mut todos = state.todos.write().await;
    let Some(rec) = todos.get_mut(&id) else {
        return json_error(StatusCode::NOT_FOUND, "Todo not found").into_response();
    };
    if rec.owner_id != uid {
        return json_error(StatusCode::NOT_FOUND, "Todo not found").into_response();
    }

    if let Some(ref title) = payload.title {
        if title.trim().is_empty() {
            return json_error(StatusCode::BAD_REQUEST, "Title is required").into_response();
        }
    }

    if let Some(title) = payload.title { rec.data.title = title; }
    if let Some(description) = payload.description { rec.data.description = description; }
    if let Some(completed) = payload.completed { rec.data.completed = completed; }

    rec.data.updated_at = now_iso8601_utc_seconds();

    (StatusCode::OK, Json(rec.data.clone())).into_response()
}

async fn delete_todo(State(state): State<AppState>, jar: CookieJar, Path(id): Path<i64>) -> impl IntoResponse {
    let uid = match auth_user(&jar, &state).await { Ok(id) => id, Err(e) => return e.into_response() };

    let mut todos = state.todos.write().await;
    match todos.get(&id) {
        Some(rec) if rec.owner_id == uid => {
            todos.remove(&id);
            StatusCode::NO_CONTENT.into_response()
        }
        _ => json_error(StatusCode::NOT_FOUND, "Todo not found").into_response(),
    }
}

#[tokio::main]
async fn main() {
    // Parse CLI args for --port PORT
    let mut args = std::env::args().skip(1);
    let mut port: u16 = 3000;
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(p) = args.next() {
                port = p.parse::<u16>().unwrap_or(3000);
            }
        }
    }

    let state = AppState {
        users: Arc::new(RwLock::new(HashMap::new())),
        username_to_id: Arc::new(RwLock::new(HashMap::new())),
        sessions: Arc::new(RwLock::new(HashMap::new())),
        todos: Arc::new(RwLock::new(HashMap::new())),
        next_user_id: Arc::new(RwLock::new(1)),
        next_todo_id: Arc::new(RwLock::new(1)),
    };

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
    println!("Listening on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind failed");
    serve(listener, app).await.expect("server error");
}
