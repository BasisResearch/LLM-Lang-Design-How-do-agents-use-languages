use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Json, Router,
};
use axum_extra::extract::cookie::{Cookie, CookieJar};
use chrono::{SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use uuid::Uuid;

#[derive(Clone, Serialize, Deserialize)]
struct UserPublic {
    id: i32,
    username: String,
}

#[derive(Clone)]
struct UserRecord {
    id: i32,
    username: String,
    password: String,
}

#[derive(Clone, Serialize, Deserialize)]
struct Todo {
    id: i32,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Clone)]
struct TodoRecord {
    owner_id: i32,
    todo: Todo,
}

#[derive(Default)]
struct AppState {
    users: HashMap<i32, UserRecord>,
    usernames: HashMap<String, i32>,
    next_user_id: i32,

    sessions: HashMap<String, i32>, // token -> user_id

    todos: HashMap<i32, TodoRecord>,
    next_todo_id: i32,
}

type SharedState = Arc<Mutex<AppState>>;

#[derive(Serialize)]
struct ErrorResponse {
    error: String,
}

fn error(status: StatusCode, msg: &str) -> Response {
    (status, Json(ErrorResponse { error: msg.to_string() })).into_response()
}

fn now_ts() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

#[derive(Deserialize)]
struct RegisterReq {
    username: String,
    password: String,
}

async fn register(State(state): State<SharedState>, Json(body): Json<RegisterReq>) -> Response {
    // Validate username
    let re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    if !re.is_match(&body.username) {
        return error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if body.password.len() < 8 {
        return error(StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut st = state.lock().unwrap();
    if st.usernames.contains_key(&body.username) {
        return error(StatusCode::CONFLICT, "Username already exists");
    }
    st.next_user_id += 1;
    let id = st.next_user_id;
    let user = UserRecord {
        id,
        username: body.username.clone(),
        password: body.password.clone(),
    };
    st.usernames.insert(body.username.clone(), id);
    st.users.insert(id, user);
    let resp = UserPublic {
        id,
        username: body.username,
    };
    (StatusCode::CREATED, Json(resp)).into_response()
}

#[derive(Deserialize)]
struct LoginReq {
    username: String,
    password: String,
}

async fn login(
    State(state): State<SharedState>,
    jar: CookieJar,
    Json(body): Json<LoginReq>,
) -> Response {
    let mut st = state.lock().unwrap();
    let uid = match st.usernames.get(&body.username).copied() {
        Some(id) => id,
        None => {
            return error(StatusCode::UNAUTHORIZED, "Invalid credentials");
        }
    };
    // Clone out required user fields to avoid holding an immutable borrow across mutation
    let (uid_copy, username_copy) = {
        let u = st.users.get(&uid).unwrap().clone();
        (u.id, u.username)
    };
    if st.users.get(&uid).unwrap().password != body.password {
        return error(StatusCode::UNAUTHORIZED, "Invalid credentials");
    }
    let token = Uuid::new_v4().simple().to_string();
    st.sessions.insert(token.clone(), uid);
    let cookie = Cookie::build(("session_id", token))
        .path("/")
        .http_only(true)
        .build();
    let jar = jar.add(cookie);
    let resp = UserPublic {
        id: uid_copy,
        username: username_copy,
    };
    (jar, (StatusCode::OK, Json(resp))).into_response()
}

fn auth_user_id(state: &SharedState, jar: &CookieJar) -> Result<i32, Response> {
    if let Some(cookie) = jar.get("session_id") {
        let token = cookie.value().to_string();
        let st = state.lock().unwrap();
        if let Some(uid) = st.sessions.get(&token) {
            return Ok(*uid);
        }
    }
    Err(error(
        StatusCode::UNAUTHORIZED,
        "Authentication required",
    ))
}

async fn logout(State(state): State<SharedState>, jar: CookieJar) -> Response {
    let token_opt = jar.get("session_id").map(|c| c.value().to_string());
    if token_opt.is_none() {
        return error(StatusCode::UNAUTHORIZED, "Authentication required");
    }
    let token = token_opt.unwrap();
    let mut st = state.lock().unwrap();
    if st.sessions.remove(&token).is_none() {
        return error(StatusCode::UNAUTHORIZED, "Authentication required");
    }
    let empty = serde_json::json!({});
    (StatusCode::OK, Json(empty)).into_response()
}

async fn me(State(state): State<SharedState>, jar: CookieJar) -> Response {
    let uid = match auth_user_id(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    let st = state.lock().unwrap();
    if let Some(user) = st.users.get(&uid) {
        let resp = UserPublic {
            id: user.id,
            username: user.username.clone(),
        };
        return (StatusCode::OK, Json(resp)).into_response();
    }
    error(StatusCode::UNAUTHORIZED, "Authentication required")
}

#[derive(Deserialize)]
struct PasswordReq {
    old_password: String,
    new_password: String,
}

async fn change_password(
    State(state): State<SharedState>,
    jar: CookieJar,
    Json(body): Json<PasswordReq>,
) -> Response {
    let uid = match auth_user_id(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    if body.new_password.len() < 8 {
        return error(StatusCode::BAD_REQUEST, "Password too short");
    }
    let mut st = state.lock().unwrap();
    let user = st.users.get_mut(&uid).unwrap();
    if user.password != body.old_password {
        return error(StatusCode::UNAUTHORIZED, "Invalid credentials");
    }
    user.password = body.new_password;
    let empty = serde_json::json!({});
    (StatusCode::OK, Json(empty)).into_response()
}

async fn list_todos(State(state): State<SharedState>, jar: CookieJar) -> Response {
    let uid = match auth_user_id(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    let st = state.lock().unwrap();
    let mut items: Vec<&TodoRecord> = st.todos.values().filter(|tr| tr.owner_id == uid).collect();
    items.sort_by_key(|tr| tr.todo.id);
    let todos: Vec<Todo> = items.into_iter().map(|tr| tr.todo.clone()).collect();
    (StatusCode::OK, Json(todos)).into_response()
}

#[derive(Deserialize)]
struct CreateTodoReq {
    title: Option<String>,
    description: Option<String>,
}

async fn create_todo(
    State(state): State<SharedState>,
    jar: CookieJar,
    Json(body): Json<CreateTodoReq>,
) -> Response {
    let uid = match auth_user_id(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    let title = match body.title {
        Some(t) if !t.trim().is_empty() => t,
        _ => return error(StatusCode::BAD_REQUEST, "Title is required"),
    };
    let description = body.description.unwrap_or_else(|| "".to_string());
    let mut st = state.lock().unwrap();
    st.next_todo_id += 1;
    let id = st.next_todo_id;
    let ts = now_ts();
    let todo = Todo {
        id,
        title,
        description,
        completed: false,
        created_at: ts.clone(),
        updated_at: ts,
    };
    let rec = TodoRecord {
        owner_id: uid,
        todo: todo.clone(),
    };
    st.todos.insert(id, rec);
    (StatusCode::CREATED, Json(todo)).into_response()
}

async fn get_todo(State(state): State<SharedState>, jar: CookieJar, Path(id): Path<i32>) -> Response {
    let uid = match auth_user_id(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    let st = state.lock().unwrap();
    if let Some(rec) = st.todos.get(&id) {
        if rec.owner_id != uid {
            return error(StatusCode::NOT_FOUND, "Todo not found");
        }
        return (StatusCode::OK, Json(rec.todo.clone())).into_response();
    }
    error(StatusCode::NOT_FOUND, "Todo not found")
}

#[derive(Deserialize)]
struct UpdateTodoReq {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

async fn update_todo(
    State(state): State<SharedState>,
    jar: CookieJar,
    Path(id): Path<i32>,
    Json(body): Json<UpdateTodoReq>,
) -> Response {
    let uid = match auth_user_id(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    let mut st = state.lock().unwrap();
    if let Some(rec) = st.todos.get_mut(&id) {
        if rec.owner_id != uid {
            return error(StatusCode::NOT_FOUND, "Todo not found");
        }
        if let Some(t) = body.title {
            if t.trim().is_empty() {
                return error(StatusCode::BAD_REQUEST, "Title is required");
            }
            rec.todo.title = t;
        }
        if let Some(d) = body.description {
            rec.todo.description = d;
        }
        if let Some(c) = body.completed {
            rec.todo.completed = c;
        }
        rec.todo.updated_at = now_ts();
        return (StatusCode::OK, Json(rec.todo.clone())).into_response();
    }
    error(StatusCode::NOT_FOUND, "Todo not found")
}

async fn delete_todo(State(state): State<SharedState>, jar: CookieJar, Path(id): Path<i32>) -> Response {
    let uid = match auth_user_id(&state, &jar) {
        Ok(u) => u,
        Err(e) => return e,
    };
    let mut st = state.lock().unwrap();
    if let Some(rec) = st.todos.get(&id) {
        if rec.owner_id != uid {
            return error(StatusCode::NOT_FOUND, "Todo not found");
        }
    } else {
        return error(StatusCode::NOT_FOUND, "Todo not found");
    }
    st.todos.remove(&id);
    StatusCode::NO_CONTENT.into_response()
}

#[tokio::main]
async fn main() {
    // Simple args parse
    let mut port: u16 = 8080;
    let mut args = std::env::args().skip(1).collect::<Vec<_>>();
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--port" {
            if i + 1 >= args.len() {
                eprintln!("--port requires a value");
                std::process::exit(1);
            }
            port = args[i + 1].parse().expect("Invalid port");
            i += 2;
        } else {
            eprintln!("Unknown argument: {}", args[i]);
            std::process::exit(1);
        }
    }

    let state = AppState {
        users: HashMap::new(),
        usernames: HashMap::new(),
        next_user_id: 0,
        sessions: HashMap::new(),
        todos: HashMap::new(),
        next_todo_id: 0,
    };

    let shared: SharedState = Arc::new(Mutex::new(state));

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(shared);

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    println!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
