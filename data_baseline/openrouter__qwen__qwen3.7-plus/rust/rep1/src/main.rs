use axum::{
    extract::{Path, State},
    http::{header::SET_COOKIE, HeaderMap, StatusCode},
    response::{IntoResponse, Response, Json},
    routing::{delete, get, post, put},
    Router,
};
use bcrypt::{hash, verify, DEFAULT_COST};
use chrono::Utc;
use clap::Parser;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

#[derive(Parser, Debug)]
#[command(name = "todo_api")]
#[command(about = "A highly safety critical REST API server")]
struct Args {
    #[arg(long)]
    port: u16,
}

#[derive(Clone, Serialize, Deserialize)]
struct User {
    id: i32,
    username: String,
    #[serde(skip_serializing)]
    password_hash: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Todo {
    id: i32,
    #[serde(skip)]
    user_id: i32,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

struct AppState {
    users: HashMap<i32, User>,
    next_user_id: i32,
    todos: HashMap<i32, Todo>,
    next_todo_id: i32,
    sessions: HashMap<String, i32>,
}

type SharedState = Arc<Mutex<AppState>>;

#[derive(Serialize)]
struct ErrorResponse {
    error: String,
}

fn err_response(status: StatusCode, msg: impl Into<String>) -> Response {
    (status, Json(ErrorResponse { error: msg.into() })).into_response()
}

fn get_current_user(state: &SharedState, headers: &HeaderMap) -> Result<User, Response> {
    if let Some(cookie_header) = headers.get("cookie") {
        let cookie_str = cookie_header.to_str().unwrap_or("");
        for cookie in cookie_str.split(';') {
            let cookie = cookie.trim();
            if cookie.starts_with("session_id=") {
                let token = cookie[11..].to_string();
                let state_guard = state.lock().unwrap();
                if let Some(&user_id) = state_guard.sessions.get(&token) {
                    if let Some(user) = state_guard.users.get(&user_id) {
                        return Ok(user.clone());
                    }
                }
            }
        }
    }
    Err(err_response(StatusCode::UNAUTHORIZED, "Authentication required"))
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn register(State(state): State<SharedState>, Json(req): Json<RegisterRequest>) -> Response {
    let username = match req.username {
        Some(u) => u,
        None => return err_response(StatusCode::BAD_REQUEST, "Invalid username"),
    };
    let password = match req.password {
        Some(p) => p,
        None => return err_response(StatusCode::BAD_REQUEST, "Password too short"),
    };

    let username_regex = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    if username.len() < 3 || username.len() > 50 || !username_regex.is_match(&username) {
        return err_response(StatusCode::BAD_REQUEST, "Invalid username");
    }

    if password.len() < 8 {
        return err_response(StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut state_guard = state.lock().unwrap();
    if state_guard.users.values().any(|u| u.username == username) {
        return err_response(StatusCode::CONFLICT, "Username already exists");
    }

    let password_hash = hash(&password, DEFAULT_COST).unwrap();
    let user_id = state_guard.next_user_id;
    state_guard.next_user_id += 1;

    let user = User {
        id: user_id,
        username: username.clone(),
        password_hash,
    };
    state_guard.users.insert(user_id, user.clone());

    #[derive(Serialize)]
    struct RegisterResponse {
        id: i32,
        username: String,
    }

    (StatusCode::CREATED, Json(RegisterResponse { id: user_id, username })).into_response()
}

#[derive(Deserialize)]
struct LoginRequest {
    username: Option<String>,
    password: Option<String>,
}

async fn login(State(state): State<SharedState>, Json(req): Json<LoginRequest>) -> Response {
    let username = req.username.unwrap_or_default();
    let password = req.password.unwrap_or_default();

    let user = {
        let state_guard = state.lock().unwrap();
        state_guard.users.values().find(|u| u.username == username).cloned()
    };

    let user = match user {
        Some(u) => u,
        None => return err_response(StatusCode::UNAUTHORIZED, "Invalid credentials"),
    };

    if verify(&password, &user.password_hash).unwrap_or(false) {
        let token = Uuid::new_v4().to_string();
        {
            let mut state_guard = state.lock().unwrap();
            state_guard.sessions.insert(token.clone(), user.id);
        }

        let cookie = format!("session_id={}; Path=/; HttpOnly", token);
        #[derive(Serialize)]
        struct LoginResponse {
            id: i32,
            username: String,
        }
        let response = (
            StatusCode::OK,
            [(SET_COOKIE, cookie)],
            Json(LoginResponse {
                id: user.id,
                username: user.username,
            }),
        );
        response.into_response()
    } else {
        err_response(StatusCode::UNAUTHORIZED, "Invalid credentials")
    }
}

async fn logout(State(state): State<SharedState>, headers: HeaderMap) -> Response {
    if let Some(cookie_header) = headers.get("cookie") {
        let cookie_str = cookie_header.to_str().unwrap_or("");
        for cookie in cookie_str.split(';') {
            let cookie = cookie.trim();
            if cookie.starts_with("session_id=") {
                let token = cookie[11..].to_string();
                let mut state_guard = state.lock().unwrap();
                state_guard.sessions.remove(&token);
            }
        }
    }
    (StatusCode::OK, Json(serde_json::json!({}))).into_response()
}

async fn me(State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let user = match get_current_user(&state, &headers) {
        Ok(u) => u,
        Err(e) => return e,
    };

    #[derive(Serialize)]
    struct MeResponse {
        id: i32,
        username: String,
    }
    (
        StatusCode::OK,
        Json(MeResponse {
            id: user.id,
            username: user.username,
        }),
    )
        .into_response()
}

#[derive(Deserialize)]
struct PasswordRequest {
    old_password: Option<String>,
    new_password: Option<String>,
}

async fn update_password(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(req): Json<PasswordRequest>,
) -> Response {
    let user = match get_current_user(&state, &headers) {
        Ok(u) => u,
        Err(e) => return e,
    };

    let old_password = req.old_password.unwrap_or_default();
    let new_password = req.new_password.unwrap_or_default();

    if new_password.len() < 8 {
        return err_response(StatusCode::BAD_REQUEST, "Password too short");
    }

    let user_record = {
        let state_guard = state.lock().unwrap();
        state_guard.users.get(&user.id).unwrap().clone()
    };

    if !verify(&old_password, &user_record.password_hash).unwrap_or(false) {
        return err_response(StatusCode::UNAUTHORIZED, "Invalid credentials");
    }

    let new_hash = hash(&new_password, DEFAULT_COST).unwrap();
    {
        let mut state_guard = state.lock().unwrap();
        if let Some(u) = state_guard.users.get_mut(&user.id) {
            u.password_hash = new_hash;
        }
    }

    (StatusCode::OK, Json(serde_json::json!({}))).into_response()
}

async fn get_todos(State(state): State<SharedState>, headers: HeaderMap) -> Response {
    let user = match get_current_user(&state, &headers) {
        Ok(u) => u,
        Err(e) => return e,
    };

    let mut todos: Vec<Todo> = {
        let state_guard = state.lock().unwrap();
        state_guard
            .todos
            .values()
            .filter(|t| t.user_id == user.id)
            .cloned()
            .collect()
    };
    todos.sort_by_key(|t| t.id);

    (StatusCode::OK, Json(todos)).into_response()
}

#[derive(Deserialize)]
struct CreateTodoRequest {
    title: Option<String>,
    description: Option<String>,
}

async fn create_todo(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Json(req): Json<CreateTodoRequest>,
) -> Response {
    let user = match get_current_user(&state, &headers) {
        Ok(u) => u,
        Err(e) => return e,
    };

    let title = match req.title {
        Some(t) if !t.is_empty() => t,
        _ => return err_response(StatusCode::BAD_REQUEST, "Title is required"),
    };

    let description = req.description.unwrap_or_default();
    let now = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    let todo = {
        let mut state_guard = state.lock().unwrap();
        let todo_id = state_guard.next_todo_id;
        state_guard.next_todo_id += 1;

        let todo = Todo {
            id: todo_id,
            user_id: user.id,
            title,
            description,
            completed: false,
            created_at: now.clone(),
            updated_at: now,
        };
        state_guard.todos.insert(todo_id, todo.clone());
        todo
    };

    (StatusCode::CREATED, Json(todo)).into_response()
}

async fn get_todo(State(state): State<SharedState>, headers: HeaderMap, Path(id): Path<i32>) -> Response {
    let user = match get_current_user(&state, &headers) {
        Ok(u) => u,
        Err(e) => return e,
    };

    let state_guard = state.lock().unwrap();
    if let Some(todo) = state_guard.todos.get(&id) {
        if todo.user_id == user.id {
            return (StatusCode::OK, Json(todo.clone())).into_response();
        }
    }
    err_response(StatusCode::NOT_FOUND, "Todo not found")
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

async fn update_todo(
    State(state): State<SharedState>,
    headers: HeaderMap,
    Path(id): Path<i32>,
    Json(req): Json<UpdateTodoRequest>,
) -> Response {
    let user = match get_current_user(&state, &headers) {
        Ok(u) => u,
        Err(e) => return e,
    };

    if let Some(ref title) = req.title {
        if title.is_empty() {
            return err_response(StatusCode::BAD_REQUEST, "Title is required");
        }
    }

    let mut state_guard = state.lock().unwrap();
    let todo = match state_guard.todos.get_mut(&id) {
        Some(t) if t.user_id == user.id => t,
        _ => return err_response(StatusCode::NOT_FOUND, "Todo not found"),
    };

    if let Some(title) = req.title {
        todo.title = title;
    }
    if let Some(description) = req.description {
        todo.description = description;
    }
    if let Some(completed) = req.completed {
        todo.completed = completed;
    }
    todo.updated_at = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    (StatusCode::OK, Json(todo.clone())).into_response()
}

async fn delete_todo(State(state): State<SharedState>, headers: HeaderMap, Path(id): Path<i32>) -> Response {
    let user = match get_current_user(&state, &headers) {
        Ok(u) => u,
        Err(e) => return e,
    };

    let mut state_guard = state.lock().unwrap();
    if let Some(todo) = state_guard.todos.get(&id) {
        if todo.user_id != user.id {
            return err_response(StatusCode::NOT_FOUND, "Todo not found");
        }
    } else {
        return err_response(StatusCode::NOT_FOUND, "Todo not found");
    }

    state_guard.todos.remove(&id);
    StatusCode::NO_CONTENT.into_response()
}

#[tokio::main]
async fn main() {
    let args = Args::parse();

    let shared_state = Arc::new(Mutex::new(AppState {
        users: HashMap::new(),
        next_user_id: 1,
        todos: HashMap::new(),
        next_todo_id: 1,
        sessions: HashMap::new(),
    }));

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(update_password))
        .route("/todos", get(get_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(shared_state);

    let addr = format!("0.0.0.0:{}", args.port);
    println!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
