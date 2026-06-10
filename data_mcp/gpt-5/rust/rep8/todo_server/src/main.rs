use axum::{
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use chrono::{SecondsFormat, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use uuid::Uuid;

#[derive(Clone, Serialize)]
struct UserPublic {
    id: u64,
    username: String,
}

#[derive(Clone)]
struct User {
    id: u64,
    username: String,
    password: String,
}

#[derive(Clone, Serialize)]
struct Todo {
    id: u64,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

#[derive(Default)]
struct AppState {
    users: HashMap<u64, User>,
    username_to_id: HashMap<String, u64>,
    user_auto: u64,

    sessions: HashMap<String, u64>, // session_id -> user_id

    todos: HashMap<u64, Vec<Todo>>, // user_id -> todos
    todo_auto: HashMap<u64, u64>,   // user_id -> next todo id
}

type Shared = Arc<Mutex<AppState>>;

#[derive(Deserialize)]
struct RegisterReq {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct LoginReq {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct PasswordReq {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize)]
struct CreateTodoReq {
    title: Option<String>,
    description: Option<String>,
}

#[derive(Deserialize)]
struct UpdateTodoReq {
    title: Option<Option<String>>,
    description: Option<Option<String>>,
    completed: Option<bool>,
}

fn json_error(status: StatusCode, msg: &str) -> Response {
    let body = serde_json::json!({"error": msg});
    let mut res = (status, Json(body)).into_response();
    let headers = res.headers_mut();
    headers.insert(
        axum::http::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    res
}

fn now_ts() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn validate_username(name: &str) -> bool {
    let re = Regex::new(r"^[a-zA-Z0-9_]{3,50}$").unwrap();
    re.is_match(name)
}

fn with_json_content_type(mut res: Response) -> Response {
    res.headers_mut().insert(
        axum::http::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    res
}

fn get_session_user_id(state: &mut AppState, headers: &HeaderMap) -> Result<u64, Response> {
    if let Some(cookie_header) = headers.get(axum::http::header::COOKIE) {
        if let Ok(cookie_str) = cookie_header.to_str() {
            for part in cookie_str.split(';') {
                let kv = part.trim();
                if let Some(rest) = kv.strip_prefix("session_id=") {
                    if let Some(uid) = state.sessions.get(rest).copied() {
                        return Ok(uid);
                    } else {
                        return Err(json_error(
                            StatusCode::UNAUTHORIZED,
                            "Authentication required",
                        ));
                    }
                }
            }
        }
    }
    Err(json_error(
        StatusCode::UNAUTHORIZED,
        "Authentication required",
    ))
}

async fn register(State(shared): State<Shared>, Json(payload): Json<RegisterReq>) -> Response {
    if !validate_username(&payload.username) {
        return json_error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if payload.password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }
    let mut st = shared.lock().unwrap();
    if st.username_to_id.contains_key(&payload.username) {
        return json_error(StatusCode::CONFLICT, "Username already exists");
    }
    st.user_auto += 1;
    let id = st.user_auto;
    let user = User {
        id,
        username: payload.username.clone(),
        password: payload.password.clone(),
    };
    st.username_to_id.insert(payload.username.clone(), id);
    st.users.insert(id, user.clone());
    let resp = UserPublic {
        id,
        username: payload.username,
    };
    with_json_content_type((StatusCode::CREATED, Json(resp)).into_response())
}

async fn login(State(shared): State<Shared>, Json(payload): Json<LoginReq>) -> Response {
    // We do this in steps to avoid holding any borrows while mutating sessions
    let (uid, username_ok) = {
        let st = shared.lock().unwrap();
        if let Some(&uid) = st.username_to_id.get(&payload.username) {
            if let Some(user) = st.users.get(&uid) {
                if user.password == payload.password {
                    (Some(uid), Some(user.username.clone()))
                } else {
                    (None, None)
                }
            } else {
                (None, None)
            }
        } else {
            (None, None)
        }
    };

    if let (Some(uid), Some(username)) = (uid, username_ok) {
        let token = Uuid::new_v4().to_string();
        let mut st = shared.lock().unwrap();
        st.sessions.insert(token.clone(), uid);
        let resp = UserPublic { id: uid, username };
        let mut res = (StatusCode::OK, Json(resp)).into_response();
        res.headers_mut().insert(
            axum::http::header::CONTENT_TYPE,
            HeaderValue::from_static("application/json"),
        );
        let cookie = format!("session_id={}; Path=/; HttpOnly", token);
        res.headers_mut()
            .insert(axum::http::header::SET_COOKIE, HeaderValue::from_str(&cookie).unwrap());
        res
    } else {
        json_error(StatusCode::UNAUTHORIZED, "Invalid credentials")
    }
}

async fn logout(State(shared): State<Shared>, headers: HeaderMap) -> Response {
    let mut st = shared.lock().unwrap();
    match get_session_user_id(&mut st, &headers) {
        Ok(_uid) => {
            // find token in cookie and remove
            if let Some(cookie_header) = headers.get(axum::http::header::COOKIE) {
                if let Ok(cookie_str) = cookie_header.to_str() {
                    for part in cookie_str.split(';') {
                        let kv = part.trim();
                        if let Some(token) = kv.strip_prefix("session_id=") {
                            st.sessions.remove(token);
                            break;
                        }
                    }
                }
            }
            with_json_content_type((StatusCode::OK, Json(serde_json::json!({}))).into_response())
        }
        Err(resp) => resp,
    }
}

async fn me(State(shared): State<Shared>, headers: HeaderMap) -> Response {
    let mut st = shared.lock().unwrap();
    match get_session_user_id(&mut st, &headers) {
        Ok(uid) => {
            if let Some(user) = st.users.get(&uid) {
                let resp = UserPublic { id: user.id, username: user.username.clone() };
                with_json_content_type((StatusCode::OK, Json(resp)).into_response())
            } else {
                json_error(StatusCode::UNAUTHORIZED, "Authentication required")
            }
        }
        Err(resp) => resp,
    }
}

async fn change_password(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Json(payload): Json<PasswordReq>,
) -> Response {
    if payload.new_password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }
    let mut st = shared.lock().unwrap();
    match get_session_user_id(&mut st, &headers) {
        Ok(uid) => {
            if let Some(user) = st.users.get_mut(&uid) {
                if user.password != payload.old_password {
                    return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
                }
                user.password = payload.new_password;
                with_json_content_type((StatusCode::OK, Json(serde_json::json!({}))).into_response())
            } else {
                json_error(StatusCode::UNAUTHORIZED, "Authentication required")
            }
        }
        Err(resp) => resp,
    }
}

async fn list_todos(State(shared): State<Shared>, headers: HeaderMap) -> Response {
    let mut st = shared.lock().unwrap();
    match get_session_user_id(&mut st, &headers) {
        Ok(uid) => {
            let todos = st.todos.get(&uid).cloned().unwrap_or_default();
            let mut sorted = todos;
            sorted.sort_by_key(|t| t.id);
            with_json_content_type((StatusCode::OK, Json(sorted)).into_response())
        }
        Err(resp) => resp,
    }
}

async fn create_todo(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Json(payload): Json<CreateTodoReq>,
) -> Response {
    let title = match payload.title {
        Some(t) if !t.trim().is_empty() => t,
        _ => return json_error(StatusCode::BAD_REQUEST, "Title is required"),
    };
    let description = payload.description.unwrap_or_else(|| "".to_string());

    let mut st = shared.lock().unwrap();
    match get_session_user_id(&mut st, &headers) {
        Ok(uid) => {
            let next = st.todo_auto.entry(uid).or_insert(0);
            *next += 1;
            let id = *next;
            let ts = now_ts();
            let todo = Todo {
                id,
                title,
                description,
                completed: false,
                created_at: ts.clone(),
                updated_at: ts,
            };
            let entry = st.todos.entry(uid).or_insert_with(Vec::new);
            entry.push(todo.clone());
            with_json_content_type((StatusCode::CREATED, Json(todo)).into_response())
        }
        Err(resp) => resp,
    }
}

async fn get_todo(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<u64>,
) -> Response {
    let mut st = shared.lock().unwrap();
    match get_session_user_id(&mut st, &headers) {
        Ok(uid) => {
            if let Some(list) = st.todos.get(&uid) {
                if let Some(todo) = list.iter().find(|t| t.id == id) {
                    return with_json_content_type((StatusCode::OK, Json(todo.clone())).into_response());
                }
            }
            json_error(StatusCode::NOT_FOUND, "Todo not found")
        }
        Err(resp) => resp,
    }
}

async fn update_todo(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<u64>,
    Json(payload): Json<UpdateTodoReq>,
) -> Response {
    let mut st = shared.lock().unwrap();
    match get_session_user_id(&mut st, &headers) {
        Ok(uid) => {
            if let Some(list) = st.todos.get_mut(&uid) {
                if let Some(todo) = list.iter_mut().find(|t| t.id == id) {
                    if let Some(t_opt) = payload.title {
                        if let Some(t) = t_opt {
                            if t.trim().is_empty() {
                                return json_error(StatusCode::BAD_REQUEST, "Title is required");
                            }
                            todo.title = t;
                        } else {
                            // explicitly null -> ignore
                        }
                    }
                    if let Some(d_opt) = payload.description {
                        if let Some(d) = d_opt {
                            todo.description = d;
                        }
                    }
                    if let Some(c) = payload.completed {
                        todo.completed = c;
                    }
                    todo.updated_at = now_ts();
                    return with_json_content_type((StatusCode::OK, Json(todo.clone())).into_response());
                }
            }
            json_error(StatusCode::NOT_FOUND, "Todo not found")
        }
        Err(resp) => resp,
    }
}

async fn delete_todo(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Path(id): Path<u64>,
) -> Response {
    let mut st = shared.lock().unwrap();
    match get_session_user_id(&mut st, &headers) {
        Ok(uid) => {
            if let Some(list) = st.todos.get_mut(&uid) {
                let len_before = list.len();
                list.retain(|t| t.id != id);
                if list.len() != len_before {
                    let res = Response::builder()
                        .status(StatusCode::NO_CONTENT)
                        .body(axum::body::Body::empty())
                        .unwrap();
                    // no body; do not set content-type per spec
                    return res;
                }
            }
            json_error(StatusCode::NOT_FOUND, "Todo not found")
        }
        Err(resp) => resp,
    }
}

#[tokio::main]
async fn main() {
    let shared: Shared = Arc::new(Mutex::new(AppState::default()));

    let app = Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/password", put(change_password))
        .route("/todos", get(list_todos).post(create_todo))
        .route("/todos/:id", get(get_todo).put(update_todo).delete(delete_todo))
        .with_state(shared);

    let mut port: u16 = 8080;
    let args = std::env::args().collect::<Vec<_>>();
    let mut i = 1;
    while i + 1 < args.len() {
        if args[i] == "--port" {
            if let Ok(p) = args[i + 1].parse::<u16>() {
                port = p;
            }
            i += 2;
        } else {
            i += 1;
        }
    }

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    println!("Listening on http://{}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app.into_make_service())
        .await
        .unwrap();
}
