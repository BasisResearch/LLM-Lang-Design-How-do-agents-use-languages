use std::{collections::{HashMap, BTreeMap}, net::SocketAddr, sync::{Arc, Mutex}};

use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put, delete},
    Json, Router,
};
use axum::http::header::{CONTENT_TYPE, SET_COOKIE, COOKIE};
use regex::Regex;
use serde::{Deserialize, Serialize};
use time::{format_description::FormatItem, macros::format_description, OffsetDateTime};
use uuid::Uuid;

#[derive(Clone, Debug, Serialize)]
struct UserPublic { id: i64, username: String }

#[derive(Clone, Debug)]
struct UserPrivate { id: i64, username: String, password: String }

#[derive(Clone, Debug, Serialize)]
struct Todo {
    id: i64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Default)]
struct AppState {
    users: BTreeMap<i64, UserPrivate>,
    username_index: HashMap<String, i64>,
    next_user_id: i64,

    sessions: HashMap<String, i64>, // token -> user_id

    todos: BTreeMap<i64, TodoRecord>,
    user_todos: HashMap<i64, Vec<i64>>, // user_id -> todo ids
    next_todo_id: i64,
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

type SharedState = Arc<Mutex<AppState>>;

#[derive(Debug, Serialize)]
struct ErrorBody { error: String }

fn json_error(status: StatusCode, msg: &str) -> Response {
    let body = ErrorBody { error: msg.to_string() };
    let mut res = (status, Json(body)).into_response();
    res.headers_mut().insert(CONTENT_TYPE, "application/json".parse().unwrap());
    res
}

fn json_ok<T: Serialize>(status: StatusCode, value: T) -> Response {
    let mut res = (status, Json(value)).into_response();
    res.headers_mut().insert(CONTENT_TYPE, "application/json".parse().unwrap());
    res
}

fn now_iso() -> String {
    // second precision UTC timestamp with trailing Z
    static FMT: &[FormatItem<'_>] = format_description!("[year]-[month]-[day]T[hour]:[minute]:[second]Z");
    let now = OffsetDateTime::now_utc().replace_nanosecond(0).unwrap();
    now.format(FMT).unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn user_public(u: &UserPrivate) -> UserPublic { UserPublic { id: u.id, username: u.username.clone() } }

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

async fn register(State(state): State<SharedState>, Json(body): Json<RegisterBody>) -> Response {
    let username_re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !username_re.is_match(&body.username) {
        return json_error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if body.password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }
    let mut st = state.lock().unwrap();
    if st.username_index.contains_key(&body.username) {
        return json_error(StatusCode::CONFLICT, "Username already exists");
    }
    st.next_user_id += 1;
    let id = st.next_user_id;
    let user = UserPrivate { id, username: body.username.clone(), password: body.password.clone() };
    st.username_index.insert(body.username.clone(), id);
    st.users.insert(id, user.clone());
    let public = user_public(&user);
    json_ok(StatusCode::CREATED, public)
}

async fn login(State(state): State<SharedState>, Json(body): Json<LoginBody>) -> Response {
    let mut st = state.lock().unwrap();
    let found = {
        if let Some(&uid) = st.username_index.get(&body.username) {
            if let Some(user) = st.users.get(&uid) {
                if user.password == body.password {
                    Some((uid, user_public(user)))
                } else { None }
            } else { None }
        } else { None }
    };
    if let Some((uid, public)) = found {
        let token = Uuid::new_v4().to_string();
        st.sessions.insert(token.clone(), uid);
        let mut res = (StatusCode::OK, Json(public)).into_response();
        res.headers_mut().insert(CONTENT_TYPE, "application/json".parse().unwrap());
        res.headers_mut().insert(SET_COOKIE, format!("session_id={}; Path=/; HttpOnly", token).parse().unwrap());
        res
    } else {
        json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")
    }
}

async fn logout(State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let token = get_session_token(&headers);
    if token.is_none() { return auth_required(); }
    let token = token.unwrap();
    let mut st = state.lock().unwrap();
    if let Some(_uid) = st.sessions.remove(&token) {
        json_ok(StatusCode::OK, serde_json::json!({}))
    } else {
        auth_required()
    }
}

async fn me(State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let uid = match auth_user_id(&state, &headers) { Ok(uid) => uid, Err(resp) => return resp };
    let st = state.lock().unwrap();
    let user = st.users.get(&uid).unwrap();
    json_ok(StatusCode::OK, user_public(user))
}

async fn change_password(State(state): State<SharedState>, headers: HeaderMap, Json(body): Json<PasswordBody>) -> Response {
    let uid = match auth_user_id(&state, &headers) { Ok(uid) => uid, Err(resp) => return resp };
    let mut st = state.lock().unwrap();
    let user = st.users.get_mut(&uid).unwrap();
    if user.password != body.old_password { return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials"); }
    if body.new_password.len() < 8 { return json_error(StatusCode::BAD_REQUEST, "Password too short"); }
    user.password = body.new_password;
    json_ok(StatusCode::OK, serde_json::json!({}))
}

async fn list_todos(State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let uid = match auth_user_id(&state, &headers) { Ok(uid) => uid, Err(resp) => return resp };
    let st = state.lock().unwrap();
    let ids = st.user_todos.get(&uid).cloned().unwrap_or_default();
    let mut todos: Vec<Todo> = Vec::new();
    for id in ids {
        if let Some(rec) = st.todos.get(&id) { if rec.user_id == uid { todos.push(to_public(rec)); } }
    }
    todos.sort_by_key(|t| t.id);
    json_ok(StatusCode::OK, todos)
}

async fn create_todo(State(state): State<SharedState>, headers: HeaderMap, Json(body): Json<CreateTodoBody>) -> Response {
    let uid = match auth_user_id(&state, &headers) { Ok(uid) => uid, Err(resp) => return resp };
    let title = match body.title { Some(t) if !t.trim().is_empty() => t, _ => return json_error(StatusCode::BAD_REQUEST, "Title is required") };
    let description = body.description.unwrap_or_else(|| "".to_string());
    let mut st = state.lock().unwrap();
    st.next_todo_id += 1; let id = st.next_todo_id;
    let now = now_iso();
    let rec = TodoRecord { id, user_id: uid, title, description, completed: false, created_at: now.clone(), updated_at: now.clone() };
    st.todos.insert(id, rec.clone());
    st.user_todos.entry(uid).or_default().push(id);
    json_ok(StatusCode::CREATED, to_public(&rec))
}

async fn get_todo(Path(id): Path<i64>, State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let uid = match auth_user_id(&state, &headers) { Ok(uid) => uid, Err(resp) => return resp };
    let st = state.lock().unwrap();
    if let Some(rec) = st.todos.get(&id) { if rec.user_id == uid { return json_ok(StatusCode::OK, to_public(rec)); } }
    json_error(StatusCode::NOT_FOUND, "Todo not found")
}

async fn update_todo(Path(id): Path<i64>, State(state): State<SharedState>, headers: HeaderMap, Json(body): Json<UpdateTodoBody>) -> Response {
    let uid = match auth_user_id(&state, &headers) { Ok(uid) => uid, Err(resp) => return resp };
    let mut st = state.lock().unwrap();
    let rec = match st.todos.get_mut(&id) { Some(r) if r.user_id == uid => r, _ => return json_error(StatusCode::NOT_FOUND, "Todo not found") };
    if let Some(t) = body.title { if t.trim().is_empty() { return json_error(StatusCode::BAD_REQUEST, "Title is required"); } else { rec.title = t; } }
    if let Some(d) = body.description { rec.description = d; }
    if let Some(c) = body.completed { rec.completed = c; }
    rec.updated_at = now_iso();
    let public = to_public(rec);
    json_ok(StatusCode::OK, public)
}

async fn delete_todo(Path(id): Path<i64>, State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let uid = match auth_user_id(&state, &headers) { Ok(uid) => uid, Err(resp) => return resp };
    let mut st = state.lock().unwrap();
    let exists_and_owned = st.todos.get(&id).map(|r| r.user_id == uid).unwrap_or(false);
    if !exists_and_owned { return json_error(StatusCode::NOT_FOUND, "Todo not found"); }
    st.todos.remove(&id);
    if let Some(list) = st.user_todos.get_mut(&uid) { list.retain(|&x| x != id); }
    // 204 No Content, no body and no content-type per spec's exception
    (StatusCode::NO_CONTENT).into_response()
}

fn to_public(r: &TodoRecord) -> Todo {
    Todo { id: r.id, title: r.title.clone(), description: r.description.clone(), completed: r.completed, created_at: r.created_at.clone(), updated_at: r.updated_at.clone() }
}

fn get_session_token(headers: &HeaderMap) -> Option<String> {
    if let Some(cookie) = headers.get(COOKIE).and_then(|v| v.to_str().ok()) {
        for part in cookie.split(';') {
            let p = part.trim();
            if let Some(rest) = p.strip_prefix("session_id=") { return Some(rest.to_string()); }
        }
    }
    None
}

fn auth_required() -> Response {
    json_error(StatusCode::UNAUTHORIZED, "Authentication required")
}

fn auth_user_id(state: &SharedState, headers: &HeaderMap) -> Result<i64, Response> {
    let token = get_session_token(headers).ok_or_else(auth_required)?;
    let st = state.lock().unwrap();
    if let Some(&uid) = st.sessions.get(&token) { Ok(uid) } else { Err(auth_required()) }
}

#[tokio::main]
async fn main() {
    // parse --port PORT
    let mut port: u16 = 8080;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--port" { if let Some(p) = args.next() { port = p.parse().unwrap_or(8080); } }
    }

    let state: SharedState = Arc::new(Mutex::new(AppState { next_user_id: 0, next_todo_id: 0, ..Default::default() }));

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
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    println!("Listening on {}", addr);
    axum::serve(listener, app).await.unwrap();
}
