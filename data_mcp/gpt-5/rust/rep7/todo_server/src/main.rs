mod middleware;
mod strict_json;

use axum::{
    extract::{Path, State, FromRequestParts, FromRef},
    http::{StatusCode, HeaderMap, header},
    response::{IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router,
};
use chrono::{SecondsFormat, Utc, NaiveDateTime};
use cookie::Cookie;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, env, net::SocketAddr, sync::Arc};
use thiserror::Error;
use tokio::sync::Mutex;
use uuid::Uuid;
use strict_json::StrictJson;

#[derive(Clone)]
struct AppState(Arc<Mutex<Store>>);

#[derive(Default)]
struct Store {
    users: HashMap<i64, UserRecord>,
    username_index: HashMap<String, i64>,
    sessions: HashMap<String, i64>, // token -> user_id
    todos: HashMap<i64, TodoRecord>, // todo_id -> todo
    next_user_id: i64,
    next_todo_id: i64,
}

#[derive(Clone, Debug)]
struct UserRecord {
    id: i64,
    username: String,
    password: String,
}

#[derive(Clone, Debug)]
struct TodoRecord {
    id: i64,
    user_id: i64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Serialize)]
pub struct UserPublic {
    id: i64,
    username: String,
}

impl From<&UserRecord> for UserPublic {
    fn from(u: &UserRecord) -> Self {
        Self { id: u.id, username: u.username.clone() }
    }
}

#[derive(Serialize)]
pub struct TodoPublic {
    id: i64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

impl From<&TodoRecord> for TodoPublic {
    fn from(t: &TodoRecord) -> Self {
        Self {
            id: t.id,
            title: t.title.clone(),
            description: t.description.clone(),
            completed: t.completed,
            created_at: t.created_at.clone(),
            updated_at: t.updated_at.clone(),
        }
    }
}

#[derive(Serialize)]
pub struct ErrorBody { pub error: String }

fn json_error(status: StatusCode, msg: &str) -> (StatusCode, Json<ErrorBody>) {
    (status, Json(ErrorBody { error: msg.to_string() }))
}

fn now_iso_utc_secs() -> String {
    let now = Utc::now();
    let secs = now.timestamp();
    let dt = chrono::DateTime::<chrono::Utc>::from_naive_utc_and_offset(NaiveDateTime::from_timestamp_opt(secs, 0).unwrap(), Utc);
    dt.to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[derive(Debug, Error)]
enum AuthError { #[error("Authentication required")] AuthRequired }

struct AuthSession { user_id: i64, token: String }

#[axum::async_trait]
impl<S> FromRequestParts<S> for AuthSession
where
    S: Send + Sync,
    AppState: FromRef<S>,
{
    type Rejection = Response;

    async fn from_request_parts(parts: &mut axum::http::request::Parts, state: &S) -> Result<Self, Self::Rejection> {
        let app_state = AppState::from_ref(state);
        let cookie_header = parts.headers.get(header::COOKIE).and_then(|v| v.to_str().ok()).unwrap_or("");
        let mut session_token: Option<String> = None;
        for item in cookie_header.split(';') {
            if let Ok(parsed) = Cookie::parse(item.trim()) {
                if parsed.name() == "session_id" {
                    session_token = Some(parsed.value().to_string());
                    break;
                }
            }
        }
        if session_token.is_none() {
            let (status, body) = json_error(StatusCode::UNAUTHORIZED, "Authentication required");
            return Err((status, body).into_response());
        }
        let token = session_token.unwrap();
        let uid_opt = {
            let store = app_state.0.lock().await;
            store.sessions.get(&token).cloned()
        };
        if let Some(uid) = uid_opt {
            Ok(AuthSession { user_id: uid, token })
        } else {
            let (status, body) = json_error(StatusCode::UNAUTHORIZED, "Authentication required");
            Err((status, body).into_response())
        }
    }
}

#[derive(Deserialize)]
struct RegisterBody { username: String, password: String }

async fn register(State(state): State<AppState>, StrictJson(body): StrictJson<RegisterBody>) -> Result<(StatusCode, Json<UserPublic>), (StatusCode, Json<ErrorBody>)> {
    // Validate username
    let uname = body.username.trim();
    if uname.len() < 3 || uname.len() > 50 || !uname.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err(json_error(StatusCode::BAD_REQUEST, "Invalid username"));
    }
    if body.password.len() < 8 {
        return Err(json_error(StatusCode::BAD_REQUEST, "Password too short"));
    }
    let mut store = state.0.lock().await;
    if store.username_index.contains_key(uname) {
        return Err(json_error(StatusCode::CONFLICT, "Username already exists"));
    }
    store.next_user_id += 1;
    let id = store.next_user_id;
    let user = UserRecord { id, username: uname.to_string(), password: body.password };
    store.username_index.insert(uname.to_string(), id);
    store.users.insert(id, user.clone());
    let public: UserPublic = (&user).into();
    Ok((StatusCode::CREATED, Json(public)))
}

#[derive(Deserialize)]
struct LoginBody { username: String, password: String }

async fn login(State(state): State<AppState>, StrictJson(body): StrictJson<LoginBody>) -> Result<(StatusCode, HeaderMap, Json<UserPublic>), (StatusCode, Json<ErrorBody>)> {
    let uid_opt = {
        let store = state.0.lock().await;
        store.username_index.get(body.username.as_str()).cloned()
    };
    let uid = if let Some(uid) = uid_opt { uid } else { return Err(json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")); };
    let user_ok = {
        let store = state.0.lock().await;
        store.users.get(&uid).map(|u| u.password == body.password).unwrap_or(false)
    };
    if !user_ok { return Err(json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")); }
    let token = Uuid::new_v4().as_simple().to_string();
    {
        let mut store = state.0.lock().await;
        store.sessions.insert(token.clone(), uid);
    }
    let mut headers = HeaderMap::new();
    let set_cookie = format!("session_id={}; Path=/; HttpOnly", token);
    headers.insert(header::SET_COOKIE, set_cookie.parse().unwrap());
    let user_public: UserPublic = {
        let store = state.0.lock().await;
        store.users.get(&uid).map(|u| u.into()).unwrap()
    };
    Ok((StatusCode::OK, headers, Json(user_public)))
}

async fn logout(State(state): State<AppState>, auth: AuthSession) -> (StatusCode, Json<serde_json::Value>) {
    let mut store = state.0.lock().await;
    store.sessions.remove(&auth.token);
    (StatusCode::OK, Json(serde_json::json!({})))
}

async fn me(State(state): State<AppState>, auth: AuthSession) -> Result<Json<UserPublic>, (StatusCode, Json<ErrorBody>)> {
    let store = state.0.lock().await;
    if let Some(user) = store.users.get(&auth.user_id) {
        Ok(Json(user.into()))
    } else {
        Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required"))
    }
}

#[derive(Deserialize)]
struct PasswordBody { old_password: String, new_password: String }

async fn change_password(State(state): State<AppState>, auth: AuthSession, StrictJson(body): StrictJson<PasswordBody>) -> Result<(StatusCode, Json<serde_json::Value>), (StatusCode, Json<ErrorBody>)> {
    if body.new_password.len() < 8 { return Err(json_error(StatusCode::BAD_REQUEST, "Password too short")); }
    let mut store = state.0.lock().await;
    let user = match store.users.get_mut(&auth.user_id) { Some(u)=>u, None=> return Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required")) };
    if user.password != body.old_password { return Err(json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")); }
    user.password = body.new_password;
    Ok((StatusCode::OK, Json(serde_json::json!({}))))
}

#[derive(Deserialize)]
struct CreateTodoBody { title: Option<String>, description: Option<String> }

async fn create_todo(State(state): State<AppState>, auth: AuthSession, StrictJson(body): StrictJson<CreateTodoBody>) -> Result<(StatusCode, Json<TodoPublic>), (StatusCode, Json<ErrorBody>)> {
    let title = body.title.unwrap_or_default();
    if title.trim().is_empty() { return Err(json_error(StatusCode::BAD_REQUEST, "Title is required")); }
    let description = body.description.unwrap_or_else(|| "".to_string());
    let now = now_iso_utc_secs();
    let mut store = state.0.lock().await;
    store.next_todo_id += 1;
    let id = store.next_todo_id;
    let todo = TodoRecord { id, user_id: auth.user_id, title, description, completed: false, created_at: now.clone(), updated_at: now };
    store.todos.insert(id, todo.clone());
    Ok((StatusCode::CREATED, Json((&todo).into())))
}

async fn list_todos(State(state): State<AppState>, auth: AuthSession) -> Json<Vec<TodoPublic>> {
    let store = state.0.lock().await;
    let mut items: Vec<&TodoRecord> = store.todos.values().filter(|t| t.user_id == auth.user_id).collect();
    items.sort_by_key(|t| t.id);
    Json(items.into_iter().map(|t| t.into()).collect())
}

async fn get_todo(State(state): State<AppState>, auth: AuthSession, Path(id): Path<i64>) -> Result<Json<TodoPublic>, (StatusCode, Json<ErrorBody>)> {
    let store = state.0.lock().await;
    if let Some(todo) = store.todos.get(&id) {
        if todo.user_id != auth.user_id { return Err(json_error(StatusCode::NOT_FOUND, "Todo not found")); }
        Ok(Json(todo.into()))
    } else {
        Err(json_error(StatusCode::NOT_FOUND, "Todo not found"))
    }
}

#[derive(Deserialize)]
struct UpdateTodoBody { title: Option<String>, description: Option<String>, completed: Option<bool> }

async fn update_todo(State(state): State<AppState>, auth: AuthSession, Path(id): Path<i64>, StrictJson(body): StrictJson<UpdateTodoBody>) -> Result<Json<TodoPublic>, (StatusCode, Json<ErrorBody>)> {
    let mut store = state.0.lock().await;
    let todo = match store.todos.get_mut(&id) { Some(t)=>t, None => return Err(json_error(StatusCode::NOT_FOUND, "Todo not found")) };
    if todo.user_id != auth.user_id { return Err(json_error(StatusCode::NOT_FOUND, "Todo not found")); }
    if let Some(title) = body.title {
        if title.trim().is_empty() { return Err(json_error(StatusCode::BAD_REQUEST, "Title is required")); }
        todo.title = title;
    }
    if let Some(desc) = body.description { todo.description = desc; }
    if let Some(comp) = body.completed { todo.completed = comp; }
    todo.updated_at = now_iso_utc_secs();
    Ok(Json(crate::TodoPublic::from(&*todo)))
}

async fn delete_todo(State(state): State<AppState>, auth: AuthSession, Path(id): Path<i64>) -> Result<StatusCode, (StatusCode, Json<ErrorBody>)> {
    let mut store = state.0.lock().await;
    let exists = store.todos.get(&id).cloned();
    if let Some(todo) = exists {
        if todo.user_id != auth.user_id { return Err(json_error(StatusCode::NOT_FOUND, "Todo not found")); }
        store.todos.remove(&id);
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(json_error(StatusCode::NOT_FOUND, "Todo not found"))
    }
}

#[tokio::main]
async fn main() {
    // Parse CLI args for --port
    let mut port: u16 = 8080;
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(p) = args.next() {
                if let Ok(pn) = p.parse::<u16>() { port = pn; }
            }
        }
    }
    let state = AppState(Arc::new(Mutex::new(Store { users: HashMap::new(), username_index: HashMap::new(), sessions: HashMap::new(), todos: HashMap::new(), next_user_id: 0, next_todo_id: 0 })));

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(state)
        .layer(axum::middleware::from_fn(middleware::enforce_json_content_type));

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    println!("listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
