use axum::{
    extract::{Path, State},
    http::{StatusCode, header},
    response::Response,
    routing::{get, post, put, delete},
    Json, Router,
};
use axum_extra::extract::cookie::{Cookie, CookieJar};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, net::SocketAddr, sync::{Arc, Mutex}};
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
    user_id: u64,
}

#[derive(Clone, Default)]
struct AppState {
    users: Arc<Mutex<HashMap<u64, UserPrivate>>>,
    username_index: Arc<Mutex<HashMap<String, u64>>>,
    sessions: Arc<Mutex<HashMap<String, u64>>>,
    todos: Arc<Mutex<HashMap<u64, Todo>>>,
    next_user_id: Arc<Mutex<u64>>,
    next_todo_id: Arc<Mutex<u64>>,
}

fn now_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now();
    let dt = now.duration_since(UNIX_EPOCH).unwrap();
    // seconds precision
    let secs = dt.as_secs() as i64;
    let naive = chrono::NaiveDateTime::from_timestamp_opt(secs, 0).unwrap();
    let utc: chrono::DateTime<chrono::Utc> = chrono::DateTime::from_utc(naive, chrono::Utc);
    utc.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[derive(Deserialize)]
struct RegisterBody { username: String, password: String }

#[derive(Deserialize)]
struct LoginBody { username: String, password: String }

#[derive(Deserialize)]
struct ChangePasswordBody { old_password: String, new_password: String }

#[derive(Deserialize)]
struct CreateTodoBody { title: String, #[serde(default)] description: String }

#[derive(Deserialize)]
struct UpdateTodoBody { #[serde(default)] title: Option<String>, #[serde(default)] description: Option<String>, #[serde(default)] completed: Option<bool> }

const COOKIE_NAME: &str = "session_id";

#[tokio::main]
async fn main() {
    let mut args = std::env::args().skip(1);
    let mut port: u16 = 8080;
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(p) = args.next() { port = p.parse().unwrap_or(8080); }
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
    println!("listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

fn json_response<T: Serialize>(status: StatusCode, body: &T) -> Response {
    let json = serde_json::to_string(body).unwrap();
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .body(axum::body::Body::from(json))
        .unwrap()
}

fn json_error(status: StatusCode, msg: &str) -> Response {
    #[derive(Serialize)]
    struct ErrBody<'a> { error: &'a str }
    json_response(status, &ErrBody { error: msg })
}

fn validate_username(name: &str) -> bool {
    let re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    re.is_match(name)
}

fn get_user_id_from_cookie(jar: &CookieJar, state: &AppState) -> Option<u64> {
    let cookie = jar.get(COOKIE_NAME)?;
    let token = cookie.value().to_string();
    let sessions = state.sessions.lock().unwrap();
    sessions.get(&token).copied()
}

async fn register(State(state): State<AppState>, Json(body): Json<RegisterBody>) -> Response {
    if !validate_username(&body.username) { return json_error(StatusCode::BAD_REQUEST, "Invalid username"); }
    if body.password.len() < 8 { return json_error(StatusCode::BAD_REQUEST, "Password too short"); }

    // uniqueness
    {
        let mut idx = state.username_index.lock().unwrap();
        if idx.contains_key(&body.username) {
            return json_error(StatusCode::CONFLICT, "Username already exists");
        }
        // create user
        let mut next = state.next_user_id.lock().unwrap();
        let id = *next + 1;
        *next = id;
        let user = UserPrivate { id, username: body.username.clone(), password: body.password.clone() };
        state.users.lock().unwrap().insert(id, user);
        idx.insert(body.username.clone(), id);
        let pubu = UserPublic { id, username: body.username };
        return json_response(StatusCode::CREATED, &pubu);
    }
}

async fn login(State(state): State<AppState>, jar: CookieJar, Json(body): Json<LoginBody>) -> (CookieJar, Response) {
    // find user
    let uid_opt = {
        let idx = state.username_index.lock().unwrap();
        idx.get(&body.username).copied()
    };
    if let Some(uid) = uid_opt {
        let ok = {
            let users = state.users.lock().unwrap();
            if let Some(u) = users.get(&uid) { u.password == body.password } else { false }
        };
        if ok {
            let token = Uuid::new_v4().to_string();
            state.sessions.lock().unwrap().insert(token.clone(), uid);
            let cookie = Cookie::build((COOKIE_NAME, token.clone()))
                .path("/")
                .http_only(true)
                .build();
            let pubu = UserPublic { id: uid, username: body.username };
            let res = json_response(StatusCode::OK, &pubu);
            return (jar.add(cookie), res);
        }
    }
    (jar, json_error(StatusCode::UNAUTHORIZED, "Invalid credentials"))
}

async fn require_auth<'a>(jar: &'a CookieJar, state: &AppState) -> Result<u64, Response> {
    match get_user_id_from_cookie(jar, state) {
        Some(uid) => Ok(uid),
        None => Err(json_error(StatusCode::UNAUTHORIZED, "Authentication required")),
    }
}

async fn logout(State(state): State<AppState>, jar: CookieJar) -> (CookieJar, Response) {
    if let Some(cookie) = jar.get(COOKIE_NAME) {
        let token = cookie.value().to_string();
        let removed = state.sessions.lock().unwrap().remove(&token);
        if removed.is_some() {
            // We do not need to clear the client cookie per spec; server-side invalidation is sufficient
            return (jar, json_response(StatusCode::OK, &serde_json::json!({})))
        }
    }
    // no valid session
    (jar, json_error(StatusCode::UNAUTHORIZED, "Authentication required"))
}

async fn me(State(state): State<AppState>, jar: CookieJar) -> Response {
    match require_auth(&jar, &state).await {
        Ok(uid) => {
            let users = state.users.lock().unwrap();
            if let Some(u) = users.get(&uid) {
                let pubu = UserPublic { id: u.id, username: u.username.clone() };
                json_response(StatusCode::OK, &pubu)
            } else {
                json_error(StatusCode::UNAUTHORIZED, "Authentication required")
            }
        }
        Err(resp) => resp,
    }
}

async fn change_password(State(state): State<AppState>, jar: CookieJar, Json(body): Json<ChangePasswordBody>) -> Response {
    match require_auth(&jar, &state).await {
        Ok(uid) => {
            if body.new_password.len() < 8 { return json_error(StatusCode::BAD_REQUEST, "Password too short"); }
            let mut users = state.users.lock().unwrap();
            if let Some(u) = users.get_mut(&uid) {
                if u.password != body.old_password { return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials"); }
                u.password = body.new_password.clone();
                return json_response(StatusCode::OK, &serde_json::json!({}));
            }
            json_error(StatusCode::UNAUTHORIZED, "Authentication required")
        }
        Err(resp) => resp,
    }
}

async fn list_todos(State(state): State<AppState>, jar: CookieJar) -> Response {
    match require_auth(&jar, &state).await {
        Ok(uid) => {
            let mut list: Vec<Todo> = state.todos.lock().unwrap().values().filter(|t| t.user_id == uid).cloned().collect();
            list.sort_by_key(|t| t.id);
            #[derive(Serialize)]
            struct TodoOut { id: u64, title: String, description: String, completed: bool, created_at: String, updated_at: String }
            let out: Vec<TodoOut> = list.into_iter().map(|t| TodoOut { id: t.id, title: t.title, description: t.description, completed: t.completed, created_at: t.created_at, updated_at: t.updated_at }).collect();
            json_response(StatusCode::OK, &out)
        }
        Err(resp) => resp,
    }
}

async fn create_todo(State(state): State<AppState>, jar: CookieJar, Json(body): Json<CreateTodoBody>) -> Response {
    match require_auth(&jar, &state).await {
        Ok(uid) => {
            if body.title.trim().is_empty() { return json_error(StatusCode::BAD_REQUEST, "Title is required"); }
            let mut next = state.next_todo_id.lock().unwrap();
            let id = *next + 1; *next = id;
            let now = now_iso8601();
            let todo = Todo { id, title: body.title.clone(), description: body.description.clone(), completed: false, created_at: now.clone(), updated_at: now.clone(), user_id: uid };
            state.todos.lock().unwrap().insert(id, todo.clone());
            #[derive(Serialize)]
            struct TodoOut { id: u64, title: String, description: String, completed: bool, created_at: String, updated_at: String }
            let out = TodoOut { id: todo.id, title: todo.title, description: todo.description, completed: todo.completed, created_at: todo.created_at, updated_at: todo.updated_at };
            json_response(StatusCode::CREATED, &out)
        }
        Err(resp) => resp,
    }
}

async fn find_user_todo(state: &AppState, uid: u64, id: u64) -> Option<Todo> {
    let todos = state.todos.lock().unwrap();
    let t = todos.get(&id)?;
    if t.user_id != uid { return None; }
    Some(t.clone())
}

async fn get_todo(State(state): State<AppState>, jar: CookieJar, Path(id): Path<u64>) -> Response {
    match require_auth(&jar, &state).await {
        Ok(uid) => {
            if let Some(t) = find_user_todo(&state, uid, id).await {
                #[derive(Serialize)]
                struct TodoOut { id: u64, title: String, description: String, completed: bool, created_at: String, updated_at: String }
                let out = TodoOut { id: t.id, title: t.title, description: t.description, completed: t.completed, created_at: t.created_at, updated_at: t.updated_at };
                json_response(StatusCode::OK, &out)
            } else {
                json_error(StatusCode::NOT_FOUND, "Todo not found")
            }
        }
        Err(resp) => resp,
    }
}

async fn update_todo(State(state): State<AppState>, jar: CookieJar, Path(id): Path<u64>, Json(body): Json<UpdateTodoBody>) -> Response {
    match require_auth(&jar, &state).await {
        Ok(uid) => {
            let mut todos = state.todos.lock().unwrap();
            if let Some(t) = todos.get_mut(&id) {
                if t.user_id != uid { return json_error(StatusCode::NOT_FOUND, "Todo not found"); }
                if let Some(title) = &body.title { if title.trim().is_empty() { return json_error(StatusCode::BAD_REQUEST, "Title is required"); } }
                if let Some(title) = body.title { t.title = title; }
                if let Some(desc) = body.description { t.description = desc; }
                if let Some(comp) = body.completed { t.completed = comp; }
                t.updated_at = now_iso8601();
                #[derive(Serialize)]
                struct TodoOut { id: u64, title: String, description: String, completed: bool, created_at: String, updated_at: String }
                let out = TodoOut { id: t.id, title: t.title.clone(), description: t.description.clone(), completed: t.completed, created_at: t.created_at.clone(), updated_at: t.updated_at.clone() };
                json_response(StatusCode::OK, &out)
            } else {
                json_error(StatusCode::NOT_FOUND, "Todo not found")
            }
        }
        Err(resp) => resp,
    }
}

async fn delete_todo(State(state): State<AppState>, jar: CookieJar, Path(id): Path<u64>) -> Response {
    match require_auth(&jar, &state).await {
        Ok(uid) => {
            let mut todos = state.todos.lock().unwrap();
            if let Some(t) = todos.get(&id) {
                if t.user_id != uid { return json_error(StatusCode::NOT_FOUND, "Todo not found"); }
            } else {
                return json_error(StatusCode::NOT_FOUND, "Todo not found");
            }
            todos.remove(&id);
            Response::builder().status(StatusCode::NO_CONTENT).body(axum::body::Body::empty()).unwrap()
        }
        Err(resp) => resp,
    }
}
