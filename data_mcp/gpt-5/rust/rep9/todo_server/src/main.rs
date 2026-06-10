use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use axum_extra::extract::cookie::{Cookie, CookieJar};
use chrono::{Duration, NaiveDateTime, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeSet, HashMap},
    env,
    net::SocketAddr,
    sync::{Arc, Mutex},
};
use uuid::Uuid;

#[derive(Clone, Serialize)]
struct UserOut {
    id: i32,
    username: String,
}

#[derive(Clone)]
struct UserInternal {
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
struct TodoInternal {
    id: i32,
    user_id: i32,
    title: String,
    description: String,
    completed: bool,
    created_at: String,
    updated_at: String,
}

impl From<&TodoInternal> for Todo {
    fn from(t: &TodoInternal) -> Self {
        Todo {
            id: t.id,
            title: t.title.clone(),
            description: t.description.clone(),
            completed: t.completed,
            created_at: t.created_at.clone(),
            updated_at: t.updated_at.clone(),
        }
    }
}

#[derive(Default)]
struct AppState {
    users: HashMap<i32, UserInternal>,
    username_to_id: HashMap<String, i32>,
    next_user_id: i32,

    sessions: HashMap<String, i32>, // session_token -> user_id

    todos: HashMap<i32, TodoInternal>,
    user_todo_ids: HashMap<i32, BTreeSet<i32>>, // user_id -> ordered set of todo ids
    next_todo_id: i32,
}

type SharedState = Arc<Mutex<AppState>>;

#[derive(Deserialize)]
struct RegisterInput {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct LoginInput {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct PasswordChangeInput {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize)]
struct CreateTodoInput {
    title: Option<String>,
    description: Option<String>,
}

#[derive(Deserialize)]
struct UpdateTodoInput {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

#[derive(Serialize)]
struct ErrorOut {
    error: String,
}

fn json_response<T: Serialize>(status: StatusCode, value: &T) -> Response {
    (status, Json(value)).into_response()
}

fn json_error(status: StatusCode, msg: &str) -> Response {
    json_response(status, &ErrorOut {
        error: msg.to_string(),
    })
}

fn now_timestamp() -> String {
    Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

fn ensure_newer_than(prev: &str) -> String {
    let now = now_timestamp();
    if now != prev {
        return now;
    }
    // Bump by one second to ensure monotonic update at second precision
    if let Ok(naive) = NaiveDateTime::parse_from_str(prev, "%Y-%m-%dT%H:%M:%SZ") {
        let bumped = naive + Duration::seconds(1);
        return bumped.format("%Y-%m-%dT%H:%M:%SZ").to_string();
    }
    now // fallback
}

fn validate_username(name: &str) -> bool {
    if name.len() < 3 || name.len() > 50 {
        return false;
    }
    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    re.is_match(name)
}

async fn register(State(state): State<SharedState>, Json(input): Json<RegisterInput>) -> Response {
    if !validate_username(&input.username) {
        return json_error(StatusCode::BAD_REQUEST, "Invalid username");
    }
    if input.password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut st = state.lock().unwrap();
    if st.username_to_id.contains_key(&input.username) {
        return json_error(StatusCode::CONFLICT, "Username already exists");
    }
    st.next_user_id += 1;
    let id = st.next_user_id;
    let user = UserInternal {
        id,
        username: input.username.clone(),
        password: input.password.clone(),
    };
    st.username_to_id.insert(input.username.clone(), id);
    st.users.insert(id, user.clone());

    let out = UserOut {
        id,
        username: user.username,
    };
    json_response(StatusCode::CREATED, &out)
}

async fn login(State(state): State<SharedState>, jar: CookieJar, Json(input): Json<LoginInput>) -> Response {
    let mut st = state.lock().unwrap();
    let Some(&uid) = st.username_to_id.get(&input.username) else {
        return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
    };
    let Some(user) = st.users.get(&uid).cloned() else {
        return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
    };
    if user.password != input.password {
        return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
    }
    let token = Uuid::new_v4().simple().to_string();
    st.sessions.insert(token.clone(), uid);

    let cookie = Cookie::build(("session_id", token)).path("/").http_only(true).build();

    let out = UserOut {
        id: user.id,
        username: user.username.clone(),
    };
    (jar.add(cookie), Json(out)).into_response()
}

fn authenticate(jar: &CookieJar, state: &SharedState) -> Result<(i32, UserOut), Response> {
    let Some(cookie) = jar.get("session_id") else {
        return Err(json_error(
            StatusCode::UNAUTHORIZED,
            "Authentication required",
        ));
    };
    let token = cookie.value().to_string();
    let st = state.lock().unwrap();
    let Some(&uid) = st.sessions.get(&token) else {
        return Err(json_error(
            StatusCode::UNAUTHORIZED,
            "Authentication required",
        ));
    };
    let Some(user) = st.users.get(&uid) else {
        return Err(json_error(
            StatusCode::UNAUTHORIZED,
            "Authentication required",
        ));
    };
    Ok((
        uid,
        UserOut {
            id: user.id,
            username: user.username.clone(),
        },
    ))
}

async fn logout(State(state): State<SharedState>, jar: CookieJar) -> Response {
    match jar.get("session_id") {
        None => return json_error(StatusCode::UNAUTHORIZED, "Authentication required"),
        Some(c) => {
            let token = c.value().to_string();
            let mut st = state.lock().unwrap();
            if st.sessions.remove(&token).is_none() {
                return json_error(StatusCode::UNAUTHORIZED, "Authentication required");
            }
        }
    }
    let empty = serde_json::json!({});
    json_response(StatusCode::OK, &empty)
}

async fn me(State(state): State<SharedState>, jar: CookieJar) -> Response {
    match authenticate(&jar, &state) {
        Ok((_uid, user)) => json_response(StatusCode::OK, &user),
        Err(resp) => resp,
    }
}

async fn change_password(
    State(state): State<SharedState>,
    jar: CookieJar,
    Json(input): Json<PasswordChangeInput>,
) -> Response {
    let (uid, _) = match authenticate(&jar, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    if input.new_password.len() < 8 {
        return json_error(StatusCode::BAD_REQUEST, "Password too short");
    }
    let mut st = state.lock().unwrap();
    let Some(user) = st.users.get_mut(&uid) else {
        return json_error(StatusCode::UNAUTHORIZED, "Authentication required");
    };
    if user.password != input.old_password {
        return json_error(StatusCode::UNAUTHORIZED, "Invalid credentials");
    }
    user.password = input.new_password;
    let empty = serde_json::json!({});
    json_response(StatusCode::OK, &empty)
}

async fn list_todos(State(state): State<SharedState>, jar: CookieJar) -> Response {
    let (uid, _user) = match authenticate(&jar, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let st = state.lock().unwrap();
    let ids_opt = st.user_todo_ids.get(&uid).cloned().unwrap_or_default();
    let mut out: Vec<Todo> = Vec::new();
    for id in ids_opt.iter() {
        if let Some(t) = st.todos.get(id) {
            out.push(Todo::from(t));
        }
    }
    json_response(StatusCode::OK, &out)
}

async fn create_todo(
    State(state): State<SharedState>,
    jar: CookieJar,
    Json(input): Json<CreateTodoInput>,
) -> Response {
    let (uid, _user) = match authenticate(&jar, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };

    let title = match input.title {
        Some(t) if !t.trim().is_empty() => t,
        _ => return json_error(StatusCode::BAD_REQUEST, "Title is required"),
    };
    let description = input.description.unwrap_or_else(|| "".to_string());
    let mut st = state.lock().unwrap();
    st.next_todo_id += 1;
    let id = st.next_todo_id;
    let now = now_timestamp();
    let internal = TodoInternal {
        id,
        user_id: uid,
        title,
        description,
        completed: false,
        created_at: now.clone(),
        updated_at: now.clone(),
    };
    st.todos.insert(id, internal.clone());
    st.user_todo_ids.entry(uid).or_default().insert(id);
    let out = Todo::from(&internal);
    json_response(StatusCode::CREATED, &out)
}

fn find_user_todo_mut<'a>(st: &'a mut AppState, uid: i32, id: i32) -> Option<&'a mut TodoInternal> {
    if let Some(t) = st.todos.get_mut(&id) {
        if t.user_id == uid {
            return Some(t);
        }
    }
    None
}

async fn get_todo(Path(id): Path<i32>, State(state): State<SharedState>, jar: CookieJar) -> Response {
    let (uid, _user) = match authenticate(&jar, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let st = state.lock().unwrap();
    if let Some(t) = st.todos.get(&id) {
        if t.user_id == uid {
            let out = Todo::from(t);
            return json_response(StatusCode::OK, &out);
        }
    }
    json_error(StatusCode::NOT_FOUND, "Todo not found")
}

async fn update_todo(
    Path(id): Path<i32>,
    State(state): State<SharedState>,
    jar: CookieJar,
    Json(input): Json<UpdateTodoInput>,
) -> Response {
    let (uid, _user) = match authenticate(&jar, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let mut st = state.lock().unwrap();
    let Some(t) = find_user_todo_mut(&mut st, uid, id) else {
        return json_error(StatusCode::NOT_FOUND, "Todo not found");
    };

    let mut changed = false;
    if let Some(title) = input.title {
        if title.trim().is_empty() {
            return json_error(StatusCode::BAD_REQUEST, "Title is required");
        }
        if t.title != title { t.title = title; changed = true; }
    }
    if let Some(desc) = input.description {
        if t.description != desc { t.description = desc; changed = true; }
    }
    if let Some(comp) = input.completed {
        if t.completed != comp { t.completed = comp; changed = true; }
    }
    if changed {
        t.updated_at = ensure_newer_than(&t.updated_at);
    }
    let out = Todo::from(&*t);
    json_response(StatusCode::OK, &out)
}

async fn delete_todo(Path(id): Path<i32>, State(state): State<SharedState>, jar: CookieJar) -> Response {
    let (uid, _user) = match authenticate(&jar, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let mut st = state.lock().unwrap();
    // First check ownership/existence
    let owned = if let Some(t) = st.todos.get(&id) {
        t.user_id == uid
    } else {
        false
    };
    if !owned {
        return json_error(StatusCode::NOT_FOUND, "Todo not found");
    }
    st.todos.remove(&id);
    if let Some(set) = st.user_todo_ids.get_mut(&uid) {
        set.remove(&id);
    }
    // 204 No Content, with no body
    Response::builder()
        .status(StatusCode::NO_CONTENT)
        .body(axum::body::Body::empty())
        .unwrap()
}

#[tokio::main]
async fn main() {
    // Simple CLI parsing for --port PORT
    let mut args = env::args().skip(1);
    let mut port: u16 = 3000;
    while let Some(arg) = args.next() {
        if arg == "--port" {
            if let Some(p) = args.next() {
                port = p.parse::<u16>().expect("Invalid port");
            }
        }
    }

    let state = Arc::new(Mutex::new(AppState {
        next_user_id: 0,
        next_todo_id: 0,
        ..Default::default()
    }));

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
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .expect("bind failed");
    axum::serve(listener, app).await.expect("server error");
}
