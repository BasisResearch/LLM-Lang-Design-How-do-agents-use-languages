use axum::{
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use tokio::signal;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize)]
struct User { id: u64, username: String }

#[derive(Debug, Clone)]
struct UserInternal { id: u64, username: String, password: String }

#[derive(Debug, Clone, Serialize)]
struct Todo {
    id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Default)]
struct AppStateInner {
    users_by_id: BTreeMap<u64, UserInternal>,
    users_by_username: HashMap<String, u64>,
    next_user_id: u64,

    sessions: HashMap<String, u64>, // session_id -> user_id

    todos_by_user: HashMap<u64, BTreeMap<u64, Todo>>, // user_id -> todos by id
    next_todo_id_by_user: HashMap<u64, u64>,
}

#[derive(Clone, Default)]
struct AppState(Arc<Mutex<AppStateInner>>);

impl AppStateInner {
    fn now() -> String { Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true) }

    fn ensure_user_entry(&mut self, uid: u64) {
        self.todos_by_user.entry(uid).or_default();
        self.next_todo_id_by_user.entry(uid).or_insert(1);
    }
}

#[derive(Debug, Deserialize)]
struct RegisterReq { username: String, password: String }

#[derive(Debug, Deserialize)]
struct LoginReq { username: String, password: String }

#[derive(Debug, Deserialize)]
struct PasswordReq { old_password: String, new_password: String }

#[derive(Debug, Deserialize)]
struct CreateTodoReq { title: Option<String>, description: Option<String> }

#[derive(Debug, Deserialize)]
struct UpdateTodoReq { title: Option<Option<String>>, description: Option<Option<String>>, completed: Option<bool> }

fn json_response<T: Serialize>(status: StatusCode, value: &T) -> Response {
    let body = serde_json::to_vec(value).unwrap();
    let mut resp = (status, body).into_response();
    let headers = resp.headers_mut();
    headers.insert(axum::http::header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    resp
}

fn json_error(status: StatusCode, msg: &str) -> Response {
    #[derive(Serialize)]
    struct Err<'a> { error: &'a str }
    json_response(status, &Err { error: msg })
}

fn ok_empty() -> Response { json_response(StatusCode::OK, &serde_json::json!({})) }

async fn register(State(state): State<AppState>, Json(payload): Json<RegisterReq>) -> Response {
    // Validate username
    let uname = payload.username.trim();
    if uname.len() < 3 || uname.len() > 50 || !uname.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return json_error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if payload.password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }
    let mut guard = state.0.lock().unwrap();
    if guard.users_by_username.contains_key(uname) {
        return json_error(StatusCode::CONFLICT, "Username already exists");
    }
    guard.next_user_id = guard.next_user_id.max(1);
    let id = guard.next_user_id;
    guard.next_user_id += 1;
    guard.users_by_username.insert(uname.to_string(), id);
    guard.users_by_id.insert(id, UserInternal { id, username: uname.to_string(), password: payload.password });
    let user = User { id, username: uname.to_string() };
    json_response(StatusCode::CREATED, &user)
}

fn extract_session_user_id(state: &AppState, headers: &HeaderMap) -> Result<u64, Response> {
    let cookie = headers.get(axum::http::header::COOKIE).and_then(|v| v.to_str().ok()).unwrap_or("");
    let mut uid = None;
    for part in cookie.split(';') {
        let p = part.trim();
        if let Some(rest) = p.strip_prefix("session_id=") {
            let token = rest.trim();
            let g = state.0.lock().unwrap();
            if let Some(&id) = g.sessions.get(token) { uid = Some(id); }
            break;
        }
    }
    uid.ok_or_else(|| json_error(StatusCode::UNAUTHORIZED, "Authentication required"))
}

async fn login(State(state): State<AppState>, Json(payload): Json<LoginReq>) -> Response {
    let mut headers = HeaderMap::new();
    let mut status = StatusCode::OK;
    let user_opt = {
        let guard = state.0.lock().unwrap();
        if let Some(&uid) = guard.users_by_username.get(payload.username.as_str()) {
            if let Some(u) = guard.users_by_id.get(&uid) {
                if u.password == payload.password { Some(u.clone()) } else { None }
            } else { None }
        } else { None }
    };
    if let Some(u) = user_opt {
        let token = Uuid::new_v4().to_string();
        {
            let mut g = state.0.lock().unwrap();
            g.sessions.insert(token.clone(), u.id);
            g.ensure_user_entry(u.id);
        }
        let cookie_val = format!("session_id={}; Path=/; HttpOnly", token);
        headers.insert(axum::http::header::SET_COOKIE, HeaderValue::from_str(&cookie_val).unwrap());
        let body = json_response(StatusCode::OK, &User { id: u.id, username: u.username });
        let (mut parts, body_bytes) = body.into_parts();
        parts.headers.extend(headers);
        Response::from_parts(parts, body_bytes)
    } else {
        json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")
    }
}

async fn logout(State(state): State<AppState>, headers: HeaderMap) -> Response {
    match extract_session_user_id(&state, &headers) {
        Ok(_) => {
            // remove the session token
            if let Some(cookie_str) = headers.get(axum::http::header::COOKIE).and_then(|v| v.to_str().ok()) {
                for part in cookie_str.split(';') {
                    let p = part.trim();
                    if let Some(rest) = p.strip_prefix("session_id=") {
                        let token = rest.trim().to_string();
                        let mut g = state.0.lock().unwrap();
                        g.sessions.remove(&token);
                        break;
                    }
                }
            }
            ok_empty()
        }
        Err(resp) => resp,
    }
}

async fn me(State(state): State<AppState>, headers: HeaderMap) -> Response {
    match extract_session_user_id(&state, &headers) {
        Ok(uid) => {
            let g = state.0.lock().unwrap();
            if let Some(u) = g.users_by_id.get(&uid) {
                json_response(StatusCode::OK, &User { id: u.id, username: u.username.clone() })
            } else {
                json_error(StatusCode::UNAUTHORIZED, "Authentication required")
            }
        }
        Err(resp) => resp,
    }
}

async fn password_change(State(state): State<AppState>, headers: HeaderMap, Json(payload): Json<PasswordReq>) -> Response {
    match extract_session_user_id(&state, &headers) {
        Ok(uid) => {
            if payload.new_password.len() < 8 {
                return json_error(StatusCode::BAD_REQUEST, "Password too short");
            }
            let mut g = state.0.lock().unwrap();
            if let Some(u) = g.users_by_id.get_mut(&uid) {
                if u.password != payload.old_password {
                    return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
                }
                u.password = payload.new_password;
                ok_empty()
            } else {
                json_error(StatusCode::UNAUTHORIZED, "Authentication required")
            }
        }
        Err(resp) => resp,
    }
}

async fn list_todos(State(state): State<AppState>, headers: HeaderMap) -> Response {
    match extract_session_user_id(&state, &headers) {
        Ok(uid) => {
            let g = state.0.lock().unwrap();
            let list: Vec<Todo> = g
                .todos_by_user
                .get(&uid)
                .map(|m| m.values().cloned().collect())
                .unwrap_or_else(|| vec![]);
            json_response(StatusCode::OK, &list)
        }
        Err(resp) => resp,
    }
}

async fn create_todo(State(state): State<AppState>, headers: HeaderMap, Json(payload): Json<CreateTodoReq>) -> Response {
    match extract_session_user_id(&state, &headers) {
        Ok(uid) => {
            let title_opt = payload.title.clone().unwrap_or_default();
            if title_opt.trim().is_empty() {
                return json_error(StatusCode::BAD_REQUEST, "Title is required");
            }
            let description = payload.description.clone().unwrap_or_else(|| "".to_string());
            let now = AppStateInner::now();
            let mut g = state.0.lock().unwrap();
            g.ensure_user_entry(uid);
            let id = *g.next_todo_id_by_user.get(&uid).unwrap();
            *g.next_todo_id_by_user.get_mut(&uid).unwrap() += 1;
            let todo = Todo { id, title: title_opt, description, completed: false, created_at: now.clone(), updated_at: now };
            g.todos_by_user.get_mut(&uid).unwrap().insert(id, todo.clone());
            json_response(StatusCode::CREATED, &todo)
        }
        Err(resp) => resp,
    }
}

fn get_user_todo_mut<'a>(g: &'a mut AppStateInner, uid: u64, id: u64) -> Option<&'a mut Todo> {
    g.todos_by_user.get_mut(&uid)?.get_mut(&id)
}
fn get_user_todo<'a>(g: &'a AppStateInner, uid: u64, id: u64) -> Option<&'a Todo> {
    g.todos_by_user.get(&uid)?.get(&id)
}

async fn get_todo(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<u64>) -> Response {
    match extract_session_user_id(&state, &headers) {
        Ok(uid) => {
            let g = state.0.lock().unwrap();
            if let Some(todo) = get_user_todo(&g, uid, id) {
                json_response(StatusCode::OK, todo)
            } else {
                json_error(StatusCode::NOT_FOUND, "Todo not found")
            }
        }
        Err(resp) => resp,
    }
}

async fn update_todo(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<u64>, Json(payload): Json<UpdateTodoReq>) -> Response {
    match extract_session_user_id(&state, &headers) {
        Ok(uid) => {
            // Validate title if present
            if let Some(Some(t)) = payload.title.as_ref() {
                if t.trim().is_empty() { return json_error(StatusCode::BAD_REQUEST, "Title is required"); }
            }
            let mut g = state.0.lock().unwrap();
            if let Some(todo) = get_user_todo_mut(&mut g, uid, id) {
                if let Some(t_opt) = payload.title { if let Some(t) = t_opt { todo.title = t; } }
                if let Some(d_opt) = payload.description { if let Some(d) = d_opt { todo.description = d; } }
                if let Some(c) = payload.completed { todo.completed = c; }
                todo.updated_at = AppStateInner::now();
                let cloned = todo.clone();
                json_response(StatusCode::OK, &cloned)
            } else {
                json_error(StatusCode::NOT_FOUND, "Todo not found")
            }
        }
        Err(resp) => resp,
    }
}

async fn delete_todo(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<u64>) -> Response {
    match extract_session_user_id(&state, &headers) {
        Ok(uid) => {
            let mut g = state.0.lock().unwrap();
            if let Some(map) = g.todos_by_user.get_mut(&uid) {
                if map.remove(&id).is_some() {
                    // Return 204 with no body and ensure no Content-Type header per spec for delete: no body
                    let mut resp = StatusCode::NO_CONTENT.into_response();
                    resp.headers_mut().insert(axum::http::header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
                    // However spec says DELETE returns no body, but Content-Type rule says all responses must have application/json except DELETE. So skip header for delete.
                    resp.headers_mut().remove(axum::http::header::CONTENT_TYPE);
                    return resp;
                }
            }
            json_error(StatusCode::NOT_FOUND, "Todo not found")
        }
        Err(resp) => resp,
    }
}

#[tokio::main]
async fn main() {
    // Minimal tracing
    tracing_subscriber::fmt().with_env_filter("info").init();

    let mut args = std::env::args().skip(1);
    let mut port: Option<u16> = None;
    while let Some(a) = args.next() {
        if a == "--port" {
            if let Some(p) = args.next() { port = p.parse::<u16>().ok(); }
        }
    }
    let port = port.unwrap_or(8080);

    let state = AppState(Default::default());

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(password_change))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(state);

    let addr = SocketAddr::from(([0,0,0,0], port));
    tracing::info!("listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).with_graceful_shutdown(shutdown_signal()).await.unwrap();
}

async fn shutdown_signal() {
    let _ = signal::ctrl_c().await;
}
