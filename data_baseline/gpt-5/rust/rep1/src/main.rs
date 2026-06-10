use axum::{
    extract::{Path, Request, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Json, Router,
};
use chrono::{DateTime, Utc};
use cookie::CookieBuilder;
use regex::Regex;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use thiserror::Error;
use tokio::signal;
use tracing::info;
use uuid::Uuid;

// Data models
#[derive(Debug, Clone, Serialize)]
struct UserPublic {
    id: u64,
    username: String,
}

#[derive(Debug, Clone)]
struct UserPrivate {
    id: u64,
    username: String,
    password: String,
}

#[derive(Debug, Clone)]
struct TodoInternal {
    id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
    user_id: u64,
}

#[derive(Debug, Clone, Serialize)]
struct TodoPublic {
    id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

impl From<&TodoInternal> for TodoPublic {
    fn from(t: &TodoInternal) -> Self {
        TodoPublic {
            id: t.id,
            title: t.title.clone(),
            description: t.description.clone(),
            completed: t.completed,
            created_at: t.created_at.clone(),
            updated_at: t.updated_at.clone(),
        }
    }
}

// Requests
#[derive(Debug, Deserialize)]
struct RegisterReq {
    username: String,
    password: String,
}

#[derive(Debug, Deserialize)]
struct LoginReq {
    username: String,
    password: String,
}

#[derive(Debug, Deserialize)]
struct PasswordChangeReq {
    old_password: String,
    new_password: String,
}

#[derive(Debug, Deserialize)]
struct TodoCreateReq {
    title: String,
    #[serde(default)]
    description: String,
}

#[derive(Debug, Deserialize)]
struct TodoUpdateReq {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    completed: Option<bool>,
}

#[derive(Debug, Serialize)]
struct ErrorResponse<'a> {
    error: &'a str,
}

// A wrapper around Json<T> that ensures JSON error responses on rejection
struct CheckedJson<T>(T);

#[axum::async_trait]
impl<S, T> axum::extract::FromRequest<S> for CheckedJson<T>
where
    S: Send + Sync,
    T: serde::de::DeserializeOwned,
{
    type Rejection = Response;

    async fn from_request(req: Request, state: &S) -> Result<Self, Self::Rejection> {
        match Json::<T>::from_request(req, state).await {
            Ok(Json(v)) => Ok(CheckedJson(v)),
            Err(_rej) => {
                // Map any JSON extraction error to a 400 JSON error
                Err(json_response(
                    StatusCode::BAD_REQUEST,
                    &ErrorResponse { error: "Invalid JSON" },
                ))
            }
        }
    }
}

// App state
#[derive(Clone, Default)]
struct AppState {
    inner: Arc<Mutex<InnerState>>,
}

#[derive(Default)]
struct InnerState {
    users: BTreeMap<u64, UserPrivate>,
    username_to_id: HashMap<String, u64>,
    next_user_id: u64,

    todos: BTreeMap<u64, TodoInternal>,
    // map user_id -> ordered list of todo ids (id ascending)
    user_todos: HashMap<u64, Vec<u64>>,
    next_todo_id: u64,

    // session token -> user_id
    sessions: HashMap<String, u64>,
}

impl AppState {
    fn lock(&self) -> std::sync::MutexGuard<'_, InnerState> {
        self.inner.lock().unwrap()
    }
}

// Utility functions
fn now_timestamp() -> String {
    let now: DateTime<Utc> = Utc::now();
    // Second precision: truncate nanos
    let secs = now.timestamp();
    let truncated = DateTime::<Utc>::from_timestamp(secs, 0).unwrap();
    truncated.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn user_public(u: &UserPrivate) -> UserPublic {
    UserPublic {
        id: u.id,
        username: u.username.clone(),
    }
}

// Error helper: ensures JSON content-type in all responses
fn json_response<T: Serialize>(status: StatusCode, body: &T) -> Response {
    let payload = serde_json::to_vec(body).unwrap_or_else(|_| b"{}".to_vec());
    let mut resp = (status, payload).into_response();
    resp.headers_mut()
        .insert(axum::http::header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    resp
}

#[derive(Debug, Error)]
enum ApiError {
    #[error("Authentication required")]
    Unauthorized,
    #[error("Invalid username")]
    InvalidUsername,
    #[error("Password too short")]
    PasswordTooShort,
    #[error("Username already exists")]
    UsernameExists,
    #[error("Invalid credentials")]
    InvalidCredentials,
    #[error("Title is required")]
    TitleRequired,
    #[error("Todo not found")]
    NotFound,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, msg) = match self {
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "Authentication required"),
            ApiError::InvalidUsername => (StatusCode::BAD_REQUEST, "Invalid username"),
            ApiError::PasswordTooShort => (StatusCode::BAD_REQUEST, "Password too short"),
            ApiError::UsernameExists => (StatusCode::CONFLICT, "Username already exists"),
            ApiError::InvalidCredentials => (StatusCode::UNAUTHORIZED, "Invalid credentials"),
            ApiError::TitleRequired => (StatusCode::BAD_REQUEST, "Title is required"),
            ApiError::NotFound => (StatusCode::NOT_FOUND, "Todo not found"),
        };
        json_response(status, &ErrorResponse { error: msg })
    }
}

// Session extraction
fn extract_session_user_id(headers: &HeaderMap, state: &AppState) -> Result<u64, ApiError> {
    // parse Cookie header for session_id
    if let Some(cookie_hdr) = headers.get(axum::http::header::COOKIE) {
        if let Ok(cookie_str) = cookie_hdr.to_str() {
            for pair in cookie_str.split(';') {
                let part = pair.trim();
                if let Some(rest) = part.strip_prefix("session_id=") {
                    let token = rest.to_string();
                    let st = state.lock();
                    if let Some(&uid) = st.sessions.get(&token) {
                        return Ok(uid);
                    } else {
                        return Err(ApiError::Unauthorized);
                    }
                }
            }
        }
    }
    Err(ApiError::Unauthorized)
}

// Handlers
async fn register(
    State(state): State<AppState>,
    CheckedJson(payload): CheckedJson<RegisterReq>,
) -> Result<Response, ApiError> {
    // validate username
    let re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !re.is_match(&payload.username) {
        return Err(ApiError::InvalidUsername);
    }
    if payload.password.len() < 8 {
        return Err(ApiError::PasswordTooShort);
    }

    let mut st = state.lock();
    if st.username_to_id.contains_key(&payload.username) {
        return Err(ApiError::UsernameExists);
    }
    st.next_user_id = st.next_user_id.saturating_add(1);
    let id = st.next_user_id;
    let user = UserPrivate { id, username: payload.username.clone(), password: payload.password };
    st.username_to_id.insert(user.username.clone(), id);
    st.users.insert(id, user.clone());

    let pub_user = user_public(&user);
    Ok(json_response(StatusCode::CREATED, &pub_user))
}

async fn login(
    State(state): State<AppState>,
    CheckedJson(payload): CheckedJson<LoginReq>,
) -> Result<Response, ApiError> {
    let st = state.lock();
    if let Some(&uid) = st.username_to_id.get(&payload.username) {
        if let Some(user) = st.users.get(&uid) {
            if user.password == payload.password {
                // create session token
                drop(st);
                let token = Uuid::new_v4().simple().to_string();
                let mut st2 = state.lock();
                st2.sessions.insert(token.clone(), uid);
                let pub_user = user_public(st2.users.get(&uid).unwrap());

                let mut resp = json_response(StatusCode::OK, &pub_user);
                // Set-Cookie header
                let cookie = CookieBuilder::new("session_id", token)
                    .path("/")
                    .http_only(true)
                    .build();
                resp.headers_mut().append(
                    axum::http::header::SET_COOKIE,
                    HeaderValue::from_str(&cookie.to_string()).unwrap(),
                );
                return Ok(resp);
            }
        }
    }
    Err(ApiError::InvalidCredentials)
}

async fn logout(State(state): State<AppState>, headers: HeaderMap) -> Result<Response, ApiError> {
    // Extract token and invalidate
    if let Some(cookie_hdr) = headers.get(axum::http::header::COOKIE) {
        if let Ok(cookie_str) = cookie_hdr.to_str() {
            for pair in cookie_str.split(';') {
                let part = pair.trim();
                if let Some(rest) = part.strip_prefix("session_id=") {
                    let token = rest.to_string();
                    let mut st = state.lock();
                    st.sessions.remove(&token);
                    let resp = json_response(StatusCode::OK, &serde_json::json!({}));
                    return Ok(resp);
                }
            }
        }
    }
    Err(ApiError::Unauthorized)
}

async fn me(State(state): State<AppState>, headers: HeaderMap) -> Result<Response, ApiError> {
    let uid = extract_session_user_id(&headers, &state)?;
    let st = state.lock();
    if let Some(user) = st.users.get(&uid) {
        return Ok(json_response(StatusCode::OK, &user_public(user)));
    }
    Err(ApiError::Unauthorized)
}

async fn password_change(
    State(state): State<AppState>,
    headers: HeaderMap,
    CheckedJson(payload): CheckedJson<PasswordChangeReq>,
) -> Result<Response, ApiError> {
    let uid = extract_session_user_id(&headers, &state)?;
    let mut st = state.lock();
    if let Some(user) = st.users.get_mut(&uid) {
        if user.password != payload.old_password {
            return Err(ApiError::InvalidCredentials);
        }
        if payload.new_password.len() < 8 {
            return Err(ApiError::PasswordTooShort);
        }
        user.password = payload.new_password;
        return Ok(json_response(StatusCode::OK, &serde_json::json!({})));
    }
    Err(ApiError::Unauthorized)
}

async fn todos_list(State(state): State<AppState>, headers: HeaderMap) -> Result<Response, ApiError> {
    let uid = extract_session_user_id(&headers, &state)?;
    let st = state.lock();
    let list = st
        .user_todos
        .get(&uid)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .filter_map(|tid| st.todos.get(&tid).map(|t| TodoPublic::from(t)))
        .collect::<Vec<_>>();
    Ok(json_response(StatusCode::OK, &list))
}

async fn todos_create(
    State(state): State<AppState>,
    headers: HeaderMap,
    CheckedJson(payload): CheckedJson<TodoCreateReq>,
) -> Result<Response, ApiError> {
    let uid = extract_session_user_id(&headers, &state)?;
    if payload.title.trim().is_empty() {
        return Err(ApiError::TitleRequired);
    }

    let mut st = state.lock();
    st.next_todo_id = st.next_todo_id.saturating_add(1);
    let id = st.next_todo_id;
    let ts = now_timestamp();
    let todo = TodoInternal {
        id,
        title: payload.title,
        description: payload.description,
        completed: false,
        created_at: ts.clone(),
        updated_at: ts,
        user_id: uid,
    };
    let public = TodoPublic::from(&todo);
    st.todos.insert(id, todo);
    st.user_todos.entry(uid).or_default().push(id);
    Ok(json_response(StatusCode::CREATED, &public))
}

async fn todos_get(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<u64>,
) -> Result<Response, ApiError> {
    let uid = extract_session_user_id(&headers, &state)?;
    let st = state.lock();
    if let Some(todo) = st.todos.get(&id) {
        if todo.user_id == uid {
            let public = TodoPublic::from(todo);
            return Ok(json_response(StatusCode::OK, &public));
        }
    }
    Err(ApiError::NotFound)
}

async fn todos_update(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<u64>,
    CheckedJson(payload): CheckedJson<TodoUpdateReq>,
) -> Result<Response, ApiError> {
    let uid = extract_session_user_id(&headers, &state)?;
    let mut st = state.lock();
    if let Some(todo) = st.todos.get_mut(&id) {
        if todo.user_id != uid {
            return Err(ApiError::NotFound);
        }
        if let Some(t) = payload.title {
            if t.trim().is_empty() {
                return Err(ApiError::TitleRequired);
            }
            todo.title = t;
        }
        if let Some(d) = payload.description {
            todo.description = d;
        }
        if let Some(c) = payload.completed {
            todo.completed = c;
        }
        todo.updated_at = now_timestamp();
        let updated = TodoPublic::from(&*todo);
        return Ok(json_response(StatusCode::OK, &updated));
    }
    Err(ApiError::NotFound)
}

async fn todos_delete(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<u64>,
) -> Result<Response, ApiError> {
    let uid = extract_session_user_id(&headers, &state)?;
    let mut st = state.lock();
    if let Some(todo) = st.todos.get(&id) {
        if todo.user_id != uid {
            return Err(ApiError::NotFound);
        }
    } else {
        return Err(ApiError::NotFound);
    }
    let _todo = st.todos.remove(&id).unwrap();
    if let Some(list) = st.user_todos.get_mut(&uid) {
        if let Some(pos) = list.iter().position(|&x| x == id) {
            list.remove(pos);
        }
    }
    // 204 No Content with no body and no content-type
    Ok(StatusCode::NO_CONTENT.into_response())
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .with_target(false)
        .compact()
        .init();

    // parse --port
    let mut port: u16 = 8080;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(p) = args.next() {
                port = p.parse().expect("Invalid port");
            }
        }
    }

    let app_state = AppState::default();

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(password_change))
        .route("/todos", get(todos_list).post(todos_create))
        .route("/todos/:id", get(todos_get).put(todos_update).delete(todos_delete))
        .with_state(app_state);

    let addr: SocketAddr = format!("0.0.0.0:{}", port).parse().unwrap();
    info!("listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap();
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        use tokio::signal::unix::{signal, SignalKind};

        let mut term = signal(SignalKind::terminate()).expect("failed to install signal handler");
        term.recv().await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}
