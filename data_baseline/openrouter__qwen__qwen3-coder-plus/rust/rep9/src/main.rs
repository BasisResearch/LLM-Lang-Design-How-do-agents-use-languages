use actix_web::{web, App, HttpResponse, HttpServer, middleware, Result, HttpRequest};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use regex::Regex;
use chrono::{DateTime, Utc};
use uuid::Uuid;

// Data structures
#[derive(Serialize, Deserialize, Clone)]
struct User {
    id: u32,
    username: String,
    #[serde(skip)]
    password: String,
}

#[derive(Serialize, Deserialize, Clone)]
struct Todo {
    id: u32,
    title: String,
    description: String,
    completed: bool,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Deserialize)]
struct RegisterRequest {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct LoginRequest {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct ChangePasswordRequest {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize)]
struct CreateTodoRequest {
    title: String,
    description: String,
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

#[derive(Clone)]
struct AppState {
    users: Arc<Mutex<HashMap<u32, User>>>,
    todos: Arc<Mutex<HashMap<u32, HashMap<u32, Todo>>>>, // user_id -> todo_id -> todo
    sessions: Arc<Mutex<HashMap<String, u32>>>,         // session_id -> user_id
    next_user_id: Arc<Mutex<u32>>,
    next_todo_id: Arc<Mutex<u32>>,
}

// Helper function to validate username
fn validate_username(username: &str) -> bool {
    if username.len() < 3 || username.len() > 50 {
        return false;
    }
    
    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    re.is_match(username)
}

// Helper function to extract session ID from cookies
fn get_session_id(req: &HttpRequest) -> Option<String> {
    if let Some(cookie_header) = req.headers().get("cookie") {
        let cookie_str = cookie_header.to_str().ok()?;
        let cookies: Vec<&str> = cookie_str.split(';').collect();
        
        for cookie in cookies {
            let parts: Vec<&str> = cookie.trim().split('=').collect();
            if parts.len() == 2 && parts[0].trim() == "session_id" {
                return Some(parts[1].trim().to_string());
            }
        }
    }
    None
}

// Check user authentication from session ID
fn authenticate_user(state: web::Data<AppState>, session_id: &str) -> Option<u32> {
    let sessions = state.sessions.lock().unwrap();
    sessions.get(session_id).copied()
}

// GET / register
async fn register(
    state: web::Data<AppState>,
    req: web::Json<RegisterRequest>,
) -> Result<HttpResponse> {
    let username = &req.username;
    let password = &req.password;

    if !validate_username(username) {
        return Ok(HttpResponse::BadRequest().json(serde_json::json!({
            "error": "Invalid username"
        })));
    }

    if password.len() < 8 {
        return Ok(HttpResponse::BadRequest().json(serde_json::json!({
            "error": "Password too short"
        })));
    }

    let mut users = state.users.lock().unwrap();
    for user in users.values() {
        if user.username == *username {
            return Ok(HttpResponse::Conflict().json(serde_json::json!({
                "error": "Username already exists"
            })));
        }
    }

    let user_id = {
        let mut next_id = state.next_user_id.lock().unwrap();
        let id = *next_id;
        *next_id += 1;
        id
    };

    let new_user = User {
        id: user_id,
        username: username.clone(),
        password: password.clone(),
    };

    users.insert(user_id, new_user);

    Ok(HttpResponse::Created().json(serde_json::json!({
        "id": user_id,
        "username": username
    })))
}

// POST /login
async fn login(
    state: web::Data<AppState>,
    req: web::Json<LoginRequest>,
) -> Result<HttpResponse> {
    let username = &req.username;
    let password = &req.password;

    let users = state.users.lock().unwrap();
    let mut found_id = None;
    for (_, user) in users.iter() {
        if user.username == *username && user.password == *password {
            found_id = Some(user.id);
            break;
        }
    }
    drop(users);

    match found_id {
        Some(id) => {
            let session_id = Uuid::new_v4().as_hyphenated().to_string();

            let mut sessions = state.sessions.lock().unwrap();
            sessions.insert(session_id.clone(), id);

            let user = state.users.lock().unwrap().get(&id).cloned().unwrap();
            Ok(HttpResponse::Ok()
                .append_header(("Set-Cookie", format!("session_id={}; Path=/; HttpOnly", session_id)))
                .json(serde_json::json!({
                    "id": id,
                    "username": user.username
                })))
        }
        None => {
            Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Invalid credentials"
            })))
        }
    }
}

// POST /logout
async fn logout(state: web::Data<AppState>, req: HttpRequest) -> Result<HttpResponse> {
    let session_id = match get_session_id(&req) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let mut sessions = state.sessions.lock().unwrap();
    sessions.remove(&session_id);

    Ok(HttpResponse::Ok().json(serde_json::json!({})))
}

// GET /me
async fn get_me(state: web::Data<AppState>, req: HttpRequest) -> Result<HttpResponse> {
    let session_id = match get_session_id(&req) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let user_id = match authenticate_user(state.clone(), &session_id) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let users = state.users.lock().unwrap();
    match users.get(&user_id) {
        Some(user) => Ok(HttpResponse::Ok().json(serde_json::json!({
            "id": user.id,
            "username": user.username
        }))),
        None => {
            // This should never happen but we handle it just in case
            Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    }
}

// PUT /password
async fn change_password(
    state: web::Data<AppState>,
    req: HttpRequest,
    password_change: web::Json<ChangePasswordRequest>,
) -> Result<HttpResponse> {
    let session_id = match get_session_id(&req) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let user_id = match authenticate_user(state.clone(), &session_id) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let old_password = &password_change.old_password;
    let new_password = &password_change.new_password;

    if new_password.len() < 8 {
        return Ok(HttpResponse::BadRequest().json(serde_json::json!({
            "error": "Password too short"
        })));
    }

    let mut users = state.users.lock().unwrap();
    if let Some(user) = users.get_mut(&user_id) {
        if user.password != *old_password {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Invalid credentials"
            })));
        }

        user.password = new_password.clone();
    } else {
        return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
            "error": "Authentication required"
        })));
    }

    Ok(HttpResponse::Ok().json(serde_json::json!({})))
}

// GET /todos
async fn get_todos(state: web::Data<AppState>, req: HttpRequest) -> Result<HttpResponse> {
    let session_id = match get_session_id(&req) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let user_id = match authenticate_user(state.clone(), &session_id) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let todos_map = state.todos.lock().unwrap();
    let user_todos = todos_map.get(&user_id).unwrap_or(&HashMap::new()).clone();

    // Convert HashMap values to Vec and sort by ID
    let mut todos: Vec<Todo> = user_todos.into_values().collect();
    todos.sort_by(|a, b| a.id.cmp(&b.id));

    Ok(HttpResponse::Ok().json(todos))
}


// POST /todos
async fn create_todo(
    state: web::Data<AppState>,
    req: HttpRequest,
    todo_req: web::Json<CreateTodoRequest>,
) -> Result<HttpResponse> {
    let session_id = match get_session_id(&req) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let user_id = match authenticate_user(state.clone(), &session_id) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    if todo_req.title.is_empty() {
        return Ok(HttpResponse::BadRequest().json(serde_json::json!({
            "error": "Title is required"
        })));
    }

    let new_todo_id = {
        let mut next_id = state.next_todo_id.lock().unwrap();
        let id = *next_id;
        *next_id += 1;
        id
    };

    let now = Utc::now();
    let new_todo = Todo {
        id: new_todo_id,
        title: todo_req.title.clone(),
        description: todo_req.description.clone(),
        completed: false,
        created_at: now,
        updated_at: now,
    };

    let mut todos = state.todos.lock().unwrap();
    let user_todos = todos.entry(user_id).or_insert_with(HashMap::new);
    user_todos.insert(new_todo_id, new_todo.clone());

    Ok(HttpResponse::Created().json(new_todo))
}

// GET /todos/:id
async fn get_todo(state: web::Data<AppState>, req: HttpRequest, path: web::Path<u32>) -> Result<HttpResponse> {
    let session_id = match get_session_id(&req) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let user_id = match authenticate_user(state.clone(), &session_id) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let todo_id = path.into_inner();
    let todos = state.todos.lock().unwrap();

    if let Some(user_todos) = todos.get(&user_id) {
        if let Some(todo) = user_todos.get(&todo_id) {
            return Ok(HttpResponse::Ok().json(todo));
        }
    }

    Ok(HttpResponse::NotFound().json(serde_json::json!({
        "error": "Todo not found"
    })))
}

// PUT /todos/:id
async fn update_todo(
    state: web::Data<AppState>,
    req: HttpRequest,
    path: web::Path<u32>,
    update_data: web::Json<UpdateTodoRequest>,
) -> Result<HttpResponse> {
    let session_id = match get_session_id(&req) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let user_id = match authenticate_user(state.clone(), &session_id) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let todo_id = path.into_inner();
    let mut todos = state.todos.lock().unwrap();

    if let Some(user_todos) = todos.get_mut(&user_id) {
        if let Some(todo) = user_todos.get_mut(&todo_id) {
            if let Some(ref new_title) = update_data.title {
                if new_title.is_empty() {
                    return Ok(HttpResponse::BadRequest().json(serde_json::json!({
                        "error": "Title is required"
                    })));
                }
                todo.title = new_title.clone();
            }

            if let Some(ref new_description) = update_data.description {
                todo.description = new_description.clone();
            }

            if let Some(new_completed) = update_data.completed {
                todo.completed = new_completed;
            }

            todo.updated_at = Utc::now();

            return Ok(HttpResponse::Ok().json(todo.clone()));
        }
    }

    Ok(HttpResponse::NotFound().json(serde_json::json!({
        "error": "Todo not found"
    })))
}

// DELETE /todos/:id
async fn delete_todo(state: web::Data<AppState>, req: HttpRequest, path: web::Path<u32>) -> Result<HttpResponse> {
    let session_id = match get_session_id(&req) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let user_id = match authenticate_user(state.clone(), &session_id) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({
                "error": "Authentication required"
            })))
        }
    };

    let todo_id = path.into_inner();
    let mut todos = state.todos.lock().unwrap();

    if let Some(user_todos) = todos.get_mut(&user_id) {
        if user_todos.remove(&todo_id).is_some() {
            return Ok(HttpResponse::NoContent().finish());
        }
    }

    Ok(HttpResponse::NotFound().json(serde_json::json!({
        "error": "Todo not found"
    })))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    
    let mut port = 8080; // Default port
    
    for i in 0..args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse::<u16>().expect("Port should be a number");
            break;
        }
    }
    
    println!("Starting server on 0.0.0.0:{}", port);

    // Initialize shared state
    let app_state = AppState {
        users: Arc::new(Mutex::new(HashMap::new())),
        todos: Arc::new(Mutex::new(HashMap::new())),
        sessions: Arc::new(Mutex::new(HashMap::new())),
        next_user_id: Arc::new(Mutex::new(1)),
        next_todo_id: Arc::new(Mutex::new(1)),
    };

    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(app_state.clone()))
            .wrap(middleware::Logger::default())
            .service(web::resource("/register").route(web::post().to(register)))
            .service(web::resource("/login").route(web::post().to(login)))
            .service(web::resource("/logout").route(web::post().to(logout)))
            .service(web::resource("/me").route(web::get().to(get_me)))
            .service(web::resource("/password").route(web::put().to(change_password)))
            .service(web::resource("/todos").route(web::get().to(get_todos)).route(web::post().to(create_todo)))
            .service(
                web::resource("/todos/{id}")
                    .route(web::get().to(get_todo))
                    .route(web::put().to(update_todo))
                    .route(web::delete().to(delete_todo))
            )
    })
    .bind(("0.0.0.0", port))?
    .run()
    .await
}