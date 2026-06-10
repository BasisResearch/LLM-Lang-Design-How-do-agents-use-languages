use actix_web::{web, App, HttpResponse, HttpServer, Result, middleware::Logger};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use chrono::{DateTime, Utc};
use regex::Regex;
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
    description: Option<String>,
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

// Application state with shared mutable data
struct AppState {
    users: Arc<Mutex<HashMap<u32, User>>>,
    todos: Arc<Mutex<HashMap<u32, HashMap<u32, Todo>>>>, // user_id -> { todo_id -> todo }
    sessions: Arc<Mutex<HashMap<String, u32>>>, // session_id -> user_id
    next_user_id: Arc<Mutex<u32>>,
    next_todo_id: Arc<Mutex<u32>>,
}

impl AppState {
    fn new() -> Self {
        Self {
            users: Arc::new(Mutex::new(HashMap::new())),
            todos: Arc::new(Mutex::new(HashMap::new())),
            sessions: Arc::new(Mutex::new(HashMap::new())),
            next_user_id: Arc::new(Mutex::new(1)),
            next_todo_id: Arc::new(Mutex::new(1)),
        }
    }
    
    fn create_user(&self, username: String, password: String) -> Result<User, String> {
        let mut users = self.users.lock().unwrap();
        
        // Check if username already exists
        for user in users.values() {
            if user.username == username {
                return Err("Username already exists".to_string());
            }
        }
        
        let user_id = *self.next_user_id.lock().unwrap();
        *self.next_user_id.lock().unwrap() += 1;
        
        let user = User {
            id: user_id,
            username,
            password,
        };
        
        users.insert(user.id, user.clone());
        Ok(user)
    }
    
    fn authenticate_user(&self, username: &str, password: &str) -> Option<User> {
        let users = self.users.lock().unwrap();
        for user in users.values() {
            if user.username == username && user.password == password {
                return Some(user.clone());
            }
        }
        None
    }
    
    fn validate_session(&self, session_id: &str) -> Option<u32> {
        let sessions = self.sessions.lock().unwrap();
        sessions.get(session_id).copied()
    }
    
    fn create_session(&self, user_id: u32) -> String {
        let session_id = Uuid::new_v4().as_simple().to_string();
        let mut sessions = self.sessions.lock().unwrap();
        sessions.insert(session_id.clone(), user_id);
        session_id
    }
    
    fn invalidate_session(&self, session_id: &str) -> bool {
        let mut sessions = self.sessions.lock().unwrap();
        sessions.remove(session_id).is_some()
    }
    
    fn change_password(&self, user_id: u32, old_password: &str, new_password: &str) -> Result<(), String> {
        let mut users = self.users.lock().unwrap();
        if let Some(user) = users.get_mut(&user_id) {
            if user.password != old_password {
                return Err("Invalid credentials".to_string());
            }
            if new_password.len() < 8 {
                return Err("Password too short".to_string());
            }
            user.password = new_password.to_string();
            Ok(())
        } else {
            Err("User not found".to_string())
        }
    }
    
    fn get_user_by_id(&self, user_id: u32) -> Option<User> {
        let users = self.users.lock().unwrap();
        users.get(&user_id).cloned()
    }
    
    fn create_todo(&self, user_id: u32, title: String, description: Option<String>) -> Todo {
        let todo_id = *self.next_todo_id.lock().unwrap();
        *self.next_todo_id.lock().unwrap() += 1;
        
        let now = Utc::now();
        let todo = Todo {
            id: todo_id,
            title,
            description: description.unwrap_or_default(),
            completed: false,
            created_at: now,
            updated_at: now,
        };
        
        let mut todos = self.todos.lock().unwrap();
        todos.entry(user_id).or_insert_with(HashMap::new).insert(todo_id, todo.clone());
        
        todo
    }
    
    fn get_todos_for_user(&self, user_id: u32) -> Vec<Todo> {
        let todos = self.todos.lock().unwrap();
        match todos.get(&user_id) {
            Some(user_todos) => {
                let mut result: Vec<Todo> = user_todos.values().cloned().collect();
                // Sort by id ascending
                result.sort_by(|a, b| a.id.cmp(&b.id));
                result
            }
            None => vec![],
        }
    }
    
    fn get_todo(&self, user_id: u32, todo_id: u32) -> Option<Todo> {
        let todos = self.todos.lock().unwrap();
        todos.get(&user_id)?.get(&todo_id).cloned()
    }
    
    fn update_todo(&self, user_id: u32, todo_id: u32, update_data: UpdateTodoRequest) -> Result<Todo, String> {
        let mut todos = self.todos.lock().unwrap();
        let user_todos = todos.get_mut(&user_id).ok_or("Todo not found")?;
        let todo = user_todos.get_mut(&todo_id).ok_or("Todo not found")?;
        
        if let Some(title) = update_data.title {
            if title.is_empty() {
                return Err("Title is required".to_string());
            }
            todo.title = title;
        }
        
        if let Some(description) = update_data.description {
            todo.description = description;
        }
        
        if let Some(completed) = update_data.completed {
            todo.completed = completed;
        }
        
        todo.updated_at = Utc::now();
        
        Ok(todo.clone())
    }
    
    fn delete_todo(&self, user_id: u32, todo_id: u32) -> bool {
        let mut todos = self.todos.lock().unwrap();
        if let Some(user_todos) = todos.get_mut(&user_id) {
            user_todos.remove(&todo_id).is_some()
        } else {
            false
        }
    }
}

// Helper function to extract session ID from headers
fn extract_session_id(req: &actix_web::HttpRequest) -> Option<String> {
    req.cookie("session_id")
        .map(|cookie| cookie.value().to_string())
}

// Error response helper
fn error_response(message: &str) -> HttpResponse {
    HttpResponse::BadRequest().json(serde_json::json!({ "error": message }))
}

// Authentication required error
fn auth_required_error() -> HttpResponse {
    HttpResponse::Unauthorized().json(serde_json::json!({ "error": "Authentication required" }))
}

// Validation helpers
fn validate_username(username: &str) -> bool {
    if username.len() < 3 || username.len() > 50 {
        return false;
    }
    
    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    re.is_match(username)
}

// Handler for registration
async fn register(
    data: web::Data<AppState>,
    req: web::Json<RegisterRequest>,
) -> Result<HttpResponse, actix_web::Error> {
    let username = req.username.trim();
    let password = req.password.as_str();
    
    if !validate_username(username) {
        return Ok(error_response("Invalid username"));
    }
    
    if password.len() < 8 {
        return Ok(error_response("Password too short"));
    }
    
    match data.create_user(username.to_string(), password.to_string()) {
        Ok(user) => Ok(HttpResponse::Created().json(serde_json::json!({
            "id": user.id,
            "username": user.username
        }))),
        Err(_) => Ok(HttpResponse::Conflict().json(serde_json::json!({
            "error": "Username already exists"
        }))),
    }
}

// Handler for login
async fn login(
    data: web::Data<AppState>,
    req: web::Json<LoginRequest>,
) -> Result<HttpResponse, actix_web::Error> {
    let user = data.authenticate_user(&req.username, &req.password);
    
    match user {
        Some(user) => {
            let session_id = data.create_session(user.id);
            
            Ok(HttpResponse::Ok()
                .append_header((
                    "Set-Cookie",
                    format!("session_id={}; Path=/; HttpOnly", session_id)
                ))
                .json(serde_json::json!({
                    "id": user.id,
                    "username": user.username
                })))
        }
        None => Ok(HttpResponse::Unauthorized().json(serde_json::json!({
            "error": "Invalid credentials"
        }))),
    }
}

// Middleware to check authentication
fn require_auth(data: &AppState, req: &actix_web::HttpRequest) -> Option<u32> {
    let session_id = extract_session_id(req)?;
    data.validate_session(&session_id)
}

// Handler for logout
async fn logout(
    data: web::Data<AppState>,
    req: actix_web::HttpRequest,
) -> Result<HttpResponse, actix_web::Error> {
    if let Some(session_id) = extract_session_id(&req) {
        data.invalidate_session(&session_id);
        Ok(HttpResponse::Ok().json(serde_json::json!({})))
    } else {
        Ok(auth_required_error())
    }
}

// Handler for getting user info
async fn get_current_user(
    data: web::Data<AppState>,
    req: actix_web::HttpRequest,
) -> Result<HttpResponse, actix_web::Error> {
    match require_auth(&data, &req) {
        Some(user_id) => {
            if let Some(user) = data.get_user_by_id(user_id) {
                Ok(HttpResponse::Ok().json(serde_json::json!({
                    "id": user.id,
                    "username": user.username
                })))
            } else {
                Ok(auth_required_error())
            }
        }
        None => Ok(auth_required_error()),
    }
}

// Handler for changing password
async fn change_password(
    data: web::Data<AppState>,
    req: actix_web::HttpRequest,
    password_change: web::Json<ChangePasswordRequest>,
) -> Result<HttpResponse, actix_web::Error> {
    match require_auth(&data, &req) {
        Some(user_id) => {
            match data.change_password(user_id, &password_change.old_password, &password_change.new_password) {
                Ok(()) => Ok(HttpResponse::Ok().json(serde_json::json!({}))),
                Err(err) => Ok(HttpResponse::Unauthorized().json(serde_json::json!({ "error": err }))),
            }
        }
        None => Ok(auth_required_error()),
    }
}

// Handler for listing todos
async fn get_todos(
    data: web::Data<AppState>,
    req: actix_web::HttpRequest,
) -> Result<HttpResponse, actix_web::Error> {
    match require_auth(&data, &req) {
        Some(user_id) => {
            let todos = data.get_todos_for_user(user_id);
            Ok(HttpResponse::Ok().json(todos))
        }
        None => Ok(auth_required_error()),
    }
}

// Handler for creating a new todo
async fn create_todo(
    data: web::Data<AppState>,
    req: actix_web::HttpRequest,
    input: web::Json<CreateTodoRequest>,
) -> Result<HttpResponse, actix_web::Error> {
    match require_auth(&data, &req) {
        Some(user_id) => {
            if input.title.trim().is_empty() {
                return Ok(error_response("Title is required"));
            }
            
            let todo = data.create_todo(user_id, input.title.trim().to_string(), input.description.clone());
            Ok(HttpResponse::Created().json(todo))
        }
        None => Ok(auth_required_error()),
    }
}

// Handler for getting a specific todo
async fn get_todo(
    data: web::Data<AppState>,
    req: actix_web::HttpRequest,
    path: web::Path<u32>,
) -> Result<HttpResponse, actix_web::Error> {
    let todo_id = path.into_inner();
    
    match require_auth(&data, &req) {
        Some(user_id) => {
            if let Some(todo) = data.get_todo(user_id, todo_id) {
                Ok(HttpResponse::Ok().json(todo))
            } else {
                Ok(HttpResponse::NotFound().json(serde_json::json!({ "error": "Todo not found" })))
            }
        }
        None => Ok(auth_required_error()),
    }
}

// Handler for updating a specific todo
async fn update_todo(
    data: web::Data<AppState>,
    req: actix_web::HttpRequest,
    path: web::Path<u32>,
    input: web::Json<UpdateTodoRequest>,
) -> Result<HttpResponse, actix_web::Error> {
    let todo_id = path.into_inner();
    
    match require_auth(&data, &req) {
        Some(user_id) => {
            match data.update_todo(user_id, todo_id, input.into_inner()) {
                Ok(todo) => Ok(HttpResponse::Ok().json(todo)),
                Err(msg) => {
                    if msg == "Todo not found" {
                        Ok(HttpResponse::NotFound().json(serde_json::json!({ "error": "Todo not found" })))
                    } else {
                        Ok(error_response(&msg))
                    }
                }
            }
        }
        None => Ok(auth_required_error()),
    }
}

// Handler for deleting a specific todo
async fn delete_todo(
    data: web::Data<AppState>,
    req: actix_web::HttpRequest,
    path: web::Path<u32>,
) -> Result<HttpResponse, actix_web::Error> {
    let todo_id = path.into_inner();
    
    match require_auth(&data, &req) {
        Some(user_id) => {
            if data.delete_todo(user_id, todo_id) {
                Ok(HttpResponse::NoContent().finish())
            } else {
                Ok(HttpResponse::NotFound().json(serde_json::json!({ "error": "Todo not found" })))
            }
        }
        None => Ok(auth_required_error()),
    }
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    env_logger::init();
    
    let args: Vec<String> = std::env::args().collect();
    
    let port = if args.contains(&"--port".to_string()) {
        let port_index = args.iter().position(|x| x == "--port").unwrap();
        args[port_index + 1].parse::<u16>().expect("--port argument must be a number")
    } else {
        8080 // Default port
    };
    
    let app_state = web::Data::new(AppState::new());
    
    println!("Starting server on 0.0.0.0:{}", port);
    
    HttpServer::new(move || {
        App::new()
            .app_data(app_state.clone())
            .wrap(Logger::default())
            .route("/register", web::post().to(register))
            .route("/login", web::post().to(login))
            .route("/logout", web::post().to(logout))
            .route("/me", web::get().to(get_current_user))
            .route("/password", web::put().to(change_password))
            .route("/todos", web::get().to(get_todos))
            .route("/todos", web::post().to(create_todo))
            .route("/todos/{id}", web::get().to(get_todo))
            .route("/todos/{id}", web::put().to(update_todo))
            .route("/todos/{id}", web::delete().to(delete_todo))
    })
    .bind(("0.0.0.0", port))?
    .run()
    .await
}