use axum::{
    extract::{Path, State},
    http::{HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Json, Router,
};
use axum_extra::extract::cookie::{Cookie, CookieJar};
use chrono::{DateTime, SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use uuid::Uuid;

// Data models
#[derive(Serialize, Clone)]
struct User {
    id: u64,
    username: String,
}

#[derive(Clone)]
struct UserRecord {
    user: User,
    password: String, // stored in plain text for this exercise only
}

#[derive(Serialize, Clone)]
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
    users_by_username: HashMap<String, UserRecord>,
    sessions: HashMap<String, String>, // session_id -> username
    todos_by_user: HashMap<String, HashMap<u64, Todo>>, // username -> (todo_id -> Todo)
}

#[derive(Clone, Default)]
struct AppState(Arc<Mutex<AppStateInner>>);

// Helper to get JSON content-type always
struct JsonResponse(Response);

impl IntoResponse for JsonResponse {
    fn into_response(self) -> Response {
        let mut res = self.0;
        let headers = res.headers_mut();
        headers.insert(
            axum::http::header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        res
    }
}

fn json<T: Serialize>(status: StatusCode, value: &T) -> JsonResponse {
    let body = serde_json::to_vec(value).unwrap();
    let res = Response::builder()
        .status(status)
        .body(axum::body::Body::from(body))
        .unwrap();
    JsonResponse(res)
}

fn error(status: StatusCode, message: &str) -> JsonResponse {
    #[derive(Serialize)]
    struct ErrBody<'a> {
        error: &'a str,
    }
    json(status, &ErrBody { error: message })
}

fn now_iso() -> String {
    let now: DateTime<Utc> = Utc::now();
    now.to_rfc3339_opts(SecondsFormat::Secs, true)
}

// Request bodies
#[derive(Deserialize)]
struct RegisterBody {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct LoginBody {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct ChangePasswordBody {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize)]
struct CreateTodoBody {
    title: String,
    #[serde(default)]
    description: String,
}

#[derive(Deserialize)]
struct UpdateTodoBody {
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    completed: Option<bool>,
}

// Authentication helper
fn authenticate(state: &AppState, jar: &CookieJar) -> Result<UserRecord, JsonResponse> {
    if let Some(cookie) = jar.get("session_id") {
        let token = cookie.value().to_string();
        let guard = state.0.lock().unwrap();
        if let Some(username) = guard.sessions.get(&token).cloned() {
            if let Some(user) = guard.users_by_username.get(&username).cloned() {
                return Ok(user);
            }
        }
    }
    Err(error(
        StatusCode::UNAUTHORIZED,
        "Authentication required",
    ))
}

// Handlers
async fn register(State(state): State<AppState>, Json(payload): Json<RegisterBody>) -> JsonResponse {
    // Validate username
    let username_re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !username_re.is_match(&payload.username) {
        return error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if payload.password.len() < 8 {
        return error(StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut guard = state.0.lock().unwrap();
    if guard.users_by_username.contains_key(&payload.username) {
        return error(StatusCode::CONFLICT, "Username already exists");
    }
    guard.next_user_id += 1;
    let id = guard.next_user_id;
    let user = User {
        id,
        username: payload.username.clone(),
    };
    let rec = UserRecord {
        user: user.clone(),
        password: payload.password,
    };
    guard
        .users_by_username
        .insert(user.username.clone(), rec);

    json(StatusCode::CREATED, &user)
}

async fn login(State(state): State<AppState>, jar: CookieJar, Json(payload): Json<LoginBody>) -> (CookieJar, JsonResponse) {
    let mut guard = state.0.lock().unwrap();
    if let Some(rec) = guard
        .users_by_username
        .get(&payload.username)
        .cloned()
    {
        if rec.password == payload.password {
            let token = Uuid::new_v4().to_string();
            guard
                .sessions
                .insert(token.clone(), payload.username.clone());
            let cookie = Cookie::build(("session_id", token))
                .path("/")
                .http_only(true)
                .build();
            let jar = jar.add(cookie);
            return (jar, json(StatusCode::OK, &rec.user));
        }
    }
    (jar, error(StatusCode::UNAUTHORIZED, "Invalid credentials"))
}

async fn logout(State(state): State<AppState>, jar: CookieJar) -> (CookieJar, JsonResponse) {
    // Authenticate first
    let token_opt = jar.get("session_id").map(|c| c.value().to_string());
    if token_opt.is_none() {
        return (jar, error(StatusCode::UNAUTHORIZED, "Authentication required"));
    }
    let token = token_opt.unwrap();
    let mut guard = state.0.lock().unwrap();
    if let Some(_username) = guard.sessions.remove(&token) {
        // Replace cookie with empty value (session invalidated server-side)
        let cookie = Cookie::build(("session_id", ""))
            .path("/")
            .http_only(true)
            .build();
        let jar = jar.add(cookie);
        return (jar, json(StatusCode::OK, &serde_json::json!({})));
    }
    (
        jar,
        error(StatusCode::UNAUTHORIZED, "Authentication required"),
    )
}

async fn me(State(state): State<AppState>, jar: CookieJar) -> JsonResponse {
    match authenticate(&state, &jar) {
        Ok(user) => json(StatusCode::OK, &user.user),
        Err(err) => err,
    }
}

async fn change_password(
    State(state): State<AppState>,
    jar: CookieJar,
    Json(payload): Json<ChangePasswordBody>,
) -> JsonResponse {
    let mut guard = state.0.lock().unwrap();
    // Validate session
    let username = match jar
        .get("session_id")
        .and_then(|c| guard.sessions.get(c.value()).cloned())
    {
        Some(u) => u,
        None => return error(StatusCode::UNAUTHORIZED, "Authentication required"),
    };

    // Validate old password
    let rec = match guard.users_by_username.get_mut(&username) {
        Some(r) => r,
        None => return error(StatusCode::UNAUTHORIZED, "Authentication required"),
    };
    if rec.password != payload.old_password {
        return error(StatusCode::UNAUTHORIZED, "Invalid credentials");
    }
    if payload.new_password.len() < 8 {
        return error(StatusCode::BAD_REQUEST, "Password too short");
    }
    rec.password = payload.new_password;
    json(StatusCode::OK, &serde_json::json!({}))
}

async fn list_todos(State(state): State<AppState>, jar: CookieJar) -> JsonResponse {
    let user = match authenticate(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    let guard = state.0.lock().unwrap();
    let todos_map = guard.todos_by_user.get(&user.user.username);
    let mut todos: Vec<Todo> = todos_map
        .map(|m| m.values().cloned().collect())
        .unwrap_or_else(Vec::new);
    todos.sort_by_key(|t| t.id);
    json(StatusCode::OK, &todos)
}

async fn create_todo(
    State(state): State<AppState>,
    jar: CookieJar,
    Json(payload): Json<CreateTodoBody>,
) -> JsonResponse {
    let user = match authenticate(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    if payload.title.trim().is_empty() {
        return error(StatusCode::BAD_REQUEST, "Title is required");
    }
    let mut guard = state.0.lock().unwrap();
    guard.next_todo_id += 1;
    let id = guard.next_todo_id;
    let now = now_iso();
    let todo = Todo {
        id,
        title: payload.title,
        description: payload.description,
        completed: false,
        created_at: now.clone(),
        updated_at: now,
    };
    guard
        .todos_by_user
        .entry(user.user.username.clone())
        .or_insert_with(HashMap::new)
        .insert(id, todo.clone());
    json(StatusCode::CREATED, &todo)
}

async fn get_todo(State(state): State<AppState>, jar: CookieJar, Path(id): Path<u64>) -> JsonResponse {
    let user = match authenticate(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    let guard = state.0.lock().unwrap();
    if let Some(map) = guard.todos_by_user.get(&user.user.username) {
        if let Some(todo) = map.get(&id) {
            return json(StatusCode::OK, todo);
        }
    }
    error(StatusCode::NOT_FOUND, "Todo not found")
}

async fn update_todo(
    State(state): State<AppState>,
    jar: CookieJar,
    Path(id): Path<u64>,
    Json(payload): Json<UpdateTodoBody>,
) -> JsonResponse {
    let user = match authenticate(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    let mut guard = state.0.lock().unwrap();
    let map = match guard.todos_by_user.get_mut(&user.user.username) {
        Some(m) => m,
        None => return error(StatusCode::NOT_FOUND, "Todo not found"),
    };
    let todo = match map.get_mut(&id) {
        Some(t) => t,
        None => return error(StatusCode::NOT_FOUND, "Todo not found"),
    };

    if let Some(title) = payload.title {
        if title.trim().is_empty() {
            return error(StatusCode::BAD_REQUEST, "Title is required");
        }
        todo.title = title;
    }
    if let Some(desc) = payload.description {
        todo.description = desc;
    }
    if let Some(comp) = payload.completed {
        todo.completed = comp;
    }
    todo.updated_at = now_iso();
    json(StatusCode::OK, todo)
}

async fn delete_todo(State(state): State<AppState>, jar: CookieJar, Path(id): Path<u64>) -> Response {
    let user = match authenticate(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e.into_response(),
    };
    let mut guard = state.0.lock().unwrap();
    let map = guard.todos_by_user.get_mut(&user.user.username);
    let found = if let Some(m) = map { m.remove(&id).is_some() } else { false };
    if !found {
        return error(StatusCode::NOT_FOUND, "Todo not found").into_response();
    }
    // For DELETE, ensure no body
    Response::builder()
        .status(StatusCode::NO_CONTENT)
        .body(axum::body::Body::empty())
        .unwrap()
}

#[tokio::main]
async fn main() {
    // Parse CLI args for --port
    let mut port: u16 = 3000;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(p) = args.next() {
                if let Ok(parsed) = p.parse::<u16>() {
                    port = parsed;
                }
            }
        }
    }

    let state = AppState(Arc::new(Mutex::new(AppStateInner::default())));

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
    axum::serve(
        tokio::net::TcpListener::bind(addr).await.unwrap(),
        app.into_make_service(),
    )
    .await
    .unwrap();
}
