use std::{collections::HashMap, net::SocketAddr, sync::{Arc, RwLock}};

use axum::{
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Json, Router,
};
use axum::http::header::HeaderName;
use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize)]
struct UserPublic { id: u64, username: String }

#[derive(Clone, Debug)]
struct UserPrivate { id: u64, username: String, password: String }

#[derive(Clone, Debug, Serialize)]
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
    // username -> user
    users: HashMap<String, UserPrivate>,
    // session_id -> username
    sessions: HashMap<String, String>,
    // username -> Vec<Todo>
    todos: HashMap<String, Vec<Todo>>, 
}

#[derive(Clone, Default)]
struct AppState(Arc<RwLock<AppStateInner>>);

impl AppState {
    fn with_lock<F, R>(&self, f: F) -> R where F: FnOnce(&mut AppStateInner) -> R {
        let mut g = self.0.write().expect("poison");
        f(&mut g)
    }

    fn with_read<F, R>(&self, f: F) -> R where F: FnOnce(&AppStateInner) -> R {
        let g = self.0.read().expect("poison");
        f(&g)
    }
}

#[derive(Debug, Serialize)]
struct ErrorBody { error: String }

impl ErrorBody {
    fn new(msg: &str) -> Json<ErrorBody> { Json(ErrorBody { error: msg.to_string() }) }
}

fn json_response<T: Serialize>(status: StatusCode, body: &T, extra_headers: Option<Vec<(String, String)>>) -> Response {
    let bytes = serde_json::to_vec(body).unwrap_or_else(|_| b"{}".to_vec());
    let mut headers = HeaderMap::new();
    headers.insert("Content-Type", HeaderValue::from_static("application/json"));
    if let Some(extra) = extra_headers {
        for (k, v) in extra {
            if let Ok(name) = k.parse::<HeaderName>() { if let Ok(val) = HeaderValue::from_str(&v) { headers.insert(name, val); } }
        }
    }
    (status, headers, bytes).into_response()
}

fn json_empty(status: StatusCode) -> Response {
    let mut headers = HeaderMap::new();
    headers.insert("Content-Type", HeaderValue::from_static("application/json"));
    let empty = serde_json::to_vec(&serde_json::json!({})).unwrap();
    (status, headers, empty).into_response()
}

fn now_iso() -> String { Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true) }

// Request bodies
#[derive(Deserialize)]
struct RegisterBody { username: String, password: String }
#[derive(Deserialize)]
struct LoginBody { username: String, password: String }
#[derive(Deserialize)]
struct PasswordBody { old_password: String, new_password: String }
#[derive(Deserialize)]
struct CreateTodoBody { title: Option<String>, description: Option<String> }
#[derive(Deserialize)]
struct UpdateTodoBody { title: Option<String>, description: Option<String>, completed: Option<bool> }

fn validate_username(u: &str) -> bool {
    if u.len() < 3 || u.len() > 50 { return false; }
    u.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

async fn register(State(state): State<AppState>, Json(body): Json<RegisterBody>) -> Response {
    if !validate_username(&body.username) {
        return json_response(StatusCode::BAD_REQUEST, &ErrorBody { error: "Invalid username".into() }, None);
    }
    if body.password.len() < 8 {
        return json_response(StatusCode::BAD_REQUEST, &ErrorBody { error: "Password too short".into() }, None);
    }
    let user = state.with_lock(|s| {
        if s.users.contains_key(&body.username) {
            return Err(())
        }
        s.next_user_id += 1;
        let id = s.next_user_id;
        let u = UserPrivate { id, username: body.username.clone(), password: body.password.clone() };
        s.users.insert(body.username.clone(), u.clone());
        Ok(UserPublic { id, username: body.username.clone() })
    });
    match user {
        Ok(pub_user) => json_response(StatusCode::CREATED, &pub_user, None),
        Err(_) => json_response(StatusCode::CONFLICT, &ErrorBody { error: "Username already exists".into() }, None),
    }
}

async fn login(State(state): State<AppState>, Json(body): Json<LoginBody>) -> Response {
    let found = state.with_read(|s| s.users.get(&body.username).cloned());
    if let Some(u) = found {
        if u.password == body.password {
            let token = Uuid::new_v4().simple().to_string();
            state.with_lock(|s| { s.sessions.insert(token.clone(), u.username.clone()); });
            let cookie = format!("session_id={}; Path=/; HttpOnly", token);
            let headers = vec![("Set-Cookie".to_string(), cookie)];
            return json_response(StatusCode::OK, &UserPublic { id: u.id, username: u.username }, Some(headers));
        }
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Invalid credentials".into() }, None)
}

fn extract_session_username(state: &AppState, headers: &HeaderMap) -> Option<String> {
    // Parse Cookie header manually to avoid extra deps
    if let Some(cookies) = headers.get("cookie").and_then(|v| v.to_str().ok()) {
        // cookies string like: a=1; session_id=token; b=2
        for part in cookies.split(';') {
            let p = part.trim();
            if let Some(rest) = p.strip_prefix("session_id=") {
                let token = rest.to_string();
                return state.with_read(|s| s.sessions.get(&token).cloned());
            }
        }
    }
    None
}

async fn logout(State(state): State<AppState>, headers: HeaderMap) -> Response {
    // Invalidate session
    if let Some(cookies) = headers.get("cookie").and_then(|v| v.to_str().ok()) {
        for part in cookies.split(';') {
            let p = part.trim();
            if let Some(rest) = p.strip_prefix("session_id=") {
                let token = rest.to_string();
                let removed = state.with_lock(|s| s.sessions.remove(&token));
                if removed.is_some() {
                    return json_empty(StatusCode::OK);
                } else {
                    break;
                }
            }
        }
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Authentication required".into() }, None)
}

async fn me(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if let Some(username) = extract_session_username(&state, &headers) {
        let u = state.with_read(|s| s.users.get(&username).cloned());
        if let Some(u) = u { return json_response(StatusCode::OK, &UserPublic { id: u.id, username: u.username }, None); }
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Authentication required".into() }, None)
}

async fn change_password(State(state): State<AppState>, headers: HeaderMap, Json(body): Json<PasswordBody>) -> Response {
    if let Some(username) = extract_session_username(&state, &headers) {
        let mut ok = false;
        let mut too_short = false;
        state.with_lock(|s| {
            if let Some(u) = s.users.get(&username).cloned() {
                if u.password == body.old_password {
                    if body.new_password.len() < 8 { too_short = true; return; }
                    if let Some(upd) = s.users.get_mut(&username) { upd.password = body.new_password.clone(); ok = true; }
                }
            }
        });
        if too_short { return json_response(StatusCode::BAD_REQUEST, &ErrorBody { error: "Password too short".into() }, None); }
        if ok { return json_empty(StatusCode::OK); }
        return json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Invalid credentials".into() }, None);
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Authentication required".into() }, None)
}

async fn list_todos(State(state): State<AppState>, headers: HeaderMap) -> Response {
    if let Some(username) = extract_session_username(&state, &headers) {
        let list = state.with_read(|s| {
            let mut v = s.todos.get(&username).cloned().unwrap_or_default();
            v.sort_by_key(|t| t.id);
            v
        });
        return json_response(StatusCode::OK, &list, None);
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Authentication required".into() }, None)
}

async fn create_todo(State(state): State<AppState>, headers: HeaderMap, Json(body): Json<CreateTodoBody>) -> Response {
    if let Some(username) = extract_session_username(&state, &headers) {
        let title = match body.title.as_ref().map(|s| s.trim()).filter(|s| !s.is_empty()) {
            Some(t) => t.to_string(),
            None => return json_response(StatusCode::BAD_REQUEST, &ErrorBody { error: "Title is required".into() }, None),
        };
        let description = body.description.clone().unwrap_or_else(|| "".into());
        let todo = state.with_lock(|s| {
            s.next_todo_id += 1;
            let id = s.next_todo_id;
            let ts = now_iso();
            let t = Todo { id, title: title.clone(), description: description.clone(), completed: false, created_at: ts.clone(), updated_at: ts.clone() };
            s.todos.entry(username.clone()).or_default().push(t.clone());
            t
        });
        return json_response(StatusCode::CREATED, &todo, None);
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Authentication required".into() }, None)
}

fn find_todo_mut<'a>(todos: &'a mut Vec<Todo>, id: u64) -> Option<&'a mut Todo> {
    todos.iter_mut().find(|t| t.id == id)
}

async fn get_todo(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<u64>) -> Response {
    if let Some(username) = extract_session_username(&state, &headers) {
        let todo = state.with_read(|s| {
            s.todos.get(&username).and_then(|v| v.iter().find(|t| t.id == id).cloned())
        });
        return match todo { Some(t) => json_response(StatusCode::OK, &t, None), None => json_response(StatusCode::NOT_FOUND, &ErrorBody { error: "Todo not found".into() }, None) };
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Authentication required".into() }, None)
}

async fn update_todo(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<u64>, Json(body): Json<UpdateTodoBody>) -> Response {
    if let Some(username) = extract_session_username(&state, &headers) {
        let mut not_found = false;
        let mut title_empty = false;
        let updated = state.with_lock(|s| {
            if let Some(list) = s.todos.get_mut(&username) {
                if let Some(t) = find_todo_mut(list, id) {
                    if let Some(ti) = body.title.as_ref() {
                        if ti.trim().is_empty() { title_empty = true; return None; }
                        t.title = ti.clone();
                    }
                    if let Some(desc) = body.description.as_ref() { t.description = desc.clone(); }
                    if let Some(c) = body.completed { t.completed = c; }
                    t.updated_at = now_iso();
                    return Some(t.clone());
                }
            }
            not_found = true;
            None
        });
        if title_empty { return json_response(StatusCode::BAD_REQUEST, &ErrorBody { error: "Title is required".into() }, None); }
        if not_found { return json_response(StatusCode::NOT_FOUND, &ErrorBody { error: "Todo not found".into() }, None); }
        if let Some(t) = updated { return json_response(StatusCode::OK, &t, None); }
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Authentication required".into() }, None)
}

async fn delete_todo(State(state): State<AppState>, headers: HeaderMap, Path(id): Path<u64>) -> Response {
    if let Some(username) = extract_session_username(&state, &headers) {
        let removed = state.with_lock(|s| {
            if let Some(list) = s.todos.get_mut(&username) {
                let before = list.len();
                list.retain(|t| t.id != id);
                return before != list.len();
            }
            false
        });
        if removed {
            // DELETE must return 204 and no body
            return (StatusCode::NO_CONTENT, HeaderMap::new()).into_response();
        }
        return json_response(StatusCode::NOT_FOUND, &ErrorBody { error: "Todo not found".into() }, None);
    }
    json_response(StatusCode::UNAUTHORIZED, &ErrorBody { error: "Authentication required".into() }, None)
}

#[tokio::main]
async fn main() {
    // Parse --port
    let mut args = std::env::args().skip(1);
    let mut port: u16 = 8080;
    while let Some(a) = args.next() {
        if a == "--port" {
            if let Some(p) = args.next() {
                port = p.parse().unwrap_or(8080);
            }
        } else {
            eprintln!("Unknown argument: {}", a);
            std::process::exit(1);
        }
    }

    let state = AppState::default();

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
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
