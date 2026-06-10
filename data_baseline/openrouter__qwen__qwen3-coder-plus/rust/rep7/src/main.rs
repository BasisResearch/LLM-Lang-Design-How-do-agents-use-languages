use actix_web::{web, App, HttpResponse, HttpServer, middleware, Result, HttpRequest};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use chrono::{DateTime, Utc};
use uuid::Uuid;

// Data structures
#[derive(Serialize, Deserialize, Clone)]
pub struct User {
    pub id: u32,
    pub username: String,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Todo {
    pub id: u32,
    pub title: String,
    pub description: String,
    pub completed: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Todo {
    fn new(title: String, description: String) -> Self {
        let now = Utc::now();
        Todo {
            id: 0, // Will be assigned when stored
            title,
            description,
            completed: false,
            created_at: now,
            updated_at: now,
        }
    }
    
    fn update(&mut self, updates: TodoUpdate) {
        if let Some(title) = updates.title {
            self.title = title;
        }
        if let Some(description) = updates.description {
            self.description = description;
        }
        if let Some(completed) = updates.completed {
            self.completed = completed;
        }
        self.updated_at = Utc::now(); // Always update the updated_at time
    }
}

#[derive(Deserialize)]
pub struct TodoUpdate {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

#[derive(Deserialize)]
pub struct UserCredentials {
    username: String,
    password: String,
}

#[derive(Deserialize)]
pub struct ChangePasswordRequest {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize)]
pub struct NewTodo {
    title: String,
    description: Option<String>,
}

// Storage structure
struct AppState {
    users: HashMap<String, User>,
    user_passwords: HashMap<String, String>,
    todos: HashMap<u32, Todo>,
    user_todos: HashMap<u32, Vec<u32>>, // user_id -> list of todo_ids
    sessions: HashMap<String, String>, // session_id -> username
    next_user_id: u32,
    next_todo_id: u32,
}

impl AppState {
    fn new() -> Self {
        AppState {
            users: HashMap::new(),
            user_passwords: HashMap::new(),
            todos: HashMap::new(),
            user_todos: HashMap::new(),
            sessions: HashMap::new(),
            next_user_id: 1,
            next_todo_id: 1,
        }
    }

    fn register_user(&mut self, username: &str, password: &str) -> Result<User, &'static str> {
        if !is_valid_username(username) {
            return Err("Invalid username");
        }
        
        if self.user_passwords.contains_key(username) {
            return Err("Username already exists");
        }
        
        if password.len() < 8 {
            return Err("Password too short");
        }

        let user = User {
            id: self.next_user_id,
            username: username.to_string(),
        };

        self.users.insert(user.id.to_string(), user.clone());
        self.user_passwords.insert(username.to_string(), password.to_string());
        self.user_todos.insert(user.id, Vec::new());
        self.next_user_id += 1;
        
        Ok(user)
    }

    fn login(&mut self, username: &str, password: &str) -> Result<(User, String), &'static str> {
        if let Some(stored_password) = self.user_passwords.get(username) {
            if stored_password == password {
                if let Some(user) = self.users.values().find(|u| u.username == username) {
                    // Generate a new session ID and store it
                    let session_id = Uuid::new_v4().to_string();
                    self.sessions.insert(session_id.clone(), username.to_string());
                    
                    return Ok((user.clone(), session_id));
                }
            }
        }
        Err("Invalid credentials")
    }

    fn logout(&mut self, session_id: &str) -> Result<(), &'static str> {
        if self.sessions.remove(session_id).is_some() {
            Ok(())
        } else {
            Err("Session not found")
        }
    }

    fn get_user_by_session(&self, session_id: &str) -> Option<&User> {
        if let Some(username) = self.sessions.get(session_id) {
            self.users.values().find(|user| &user.username == username)
        } else {
            None
        }
    }

    fn get_user_id_from_session(&self, session_id: &str) -> Option<u32> {
        if let Some(username) = self.sessions.get(session_id) {
            if let Some(user) = self.users.values().find(|u| &u.username == username) {
                return Some(user.id);
            }
        }
        None
    }

    fn change_password(&mut self, session_id: &str, old_password: &str, new_password: &str) -> Result<(), &'static str> {
        if let Some(username) = self.sessions.get(session_id) {
            if let Some(stored_password) = self.user_passwords.get(username) {
                if stored_password != old_password {
                    return Err("Invalid credentials");
                }
                
                if new_password.len() < 8 {
                    return Err("Password too short");
                }
                
                self.user_passwords.insert(username.to_string(), new_password.to_string());
                return Ok(());
            }
        }
        Err("Authentication required")
    }

    fn create_todo(&mut self, user_id: u32, title: String, description: String) -> Todo {
        let mut todo = Todo::new(title, description);
        todo.id = self.next_todo_id;
        
        self.todos.insert(todo.id, todo.clone());
        
        // Add todo id to user's todo list
        if let Some(todos) = self.user_todos.get_mut(&user_id) {
            todos.push(todo.id);
        }
        
        self.next_todo_id += 1;
        todo
    }

    fn get_all_todos_for_user(&self, user_id: u32) -> Vec<Todo> {
        let mut result = Vec::new();
        
        if let Some(todo_ids) = self.user_todos.get(&user_id) {
            for todo_id in todo_ids {
                if let Some(todo) = self.todos.get(todo_id) {
                    result.push(todo.clone());
                }
            }
        }
        
        result.sort_by(|a, b| a.id.cmp(&b.id));
        result
    }

    fn get_todo_by_user_and_id(&self, user_id: u32, todo_id: u32) -> Option<Todo> {
        if let Some(todo_ids) = self.user_todos.get(&user_id) {
            if todo_ids.contains(&todo_id) {
                return self.todos.get(&todo_id).cloned();
            }
        }
        None
    }

    fn update_todo(&mut self, user_id: u32, todo_id: u32, updates: TodoUpdate) -> Result<Todo, &'static str> {
        if let Some(todo_ids) = self.user_todos.get(&user_id) {
            if todo_ids.contains(&todo_id) {
                if let Some(todo) = self.todos.get_mut(&todo_id) {
                    // Validate if title is provided and is empty
                    if let Some(ref title) = updates.title {
                        if title.is_empty() {
                            return Err("Title is required");
                        }
                    }
                    
                    todo.update(updates);
                    return Ok(todo.clone());
                }
            }
        }
        Err("Todo not found")
    }

    fn delete_todo(&mut self, user_id: u32, todo_id: u32) -> bool {
        if let Some(todo_ids) = self.user_todos.get_mut(&user_id) {
            if let Some(pos) = todo_ids.iter().position(|&x| x == todo_id) {
                todo_ids.remove(pos);
                self.todos.remove(&todo_id);
                return true;
            }
        }
        false
    }
}

fn is_valid_username(username: &str) -> bool {
    if username.len() < 3 || username.len() > 50 {
        return false;
    }
    regex::Regex::new(r"^[a-zA-Z0-9_]+$").unwrap().is_match(username)
}

fn get_session_id(req: &HttpRequest) -> Option<String> {
    req.cookie("session_id")
        .map(|cookie| cookie.value().to_string())
}

// Helper function to convert errors to HTTP responses
fn error_response(status: actix_web::http::StatusCode, message: &str) -> HttpResponse {
    HttpResponse::build(status).json(serde_json::json!({"error": message}))
}

async fn register(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: web::Json<UserCredentials>,
) -> HttpResponse {
    let mut state_lock = state.lock().unwrap();
    
    match state_lock.register_user(&req.username, &req.password) {
        Ok(user) => HttpResponse::Created().json(user),
        Err(error_msg) => match error_msg {
            "Invalid username" => error_response(actix_web::http::StatusCode::BAD_REQUEST, "Invalid username"),
            "Password too short" => error_response(actix_web::http::StatusCode::BAD_REQUEST, "Password too short"),
            "Username already exists" => error_response(actix_web::http::StatusCode::CONFLICT, "Username already exists"),
            _ => error_response(actix_web::http::StatusCode::INTERNAL_SERVER_ERROR, "Internal server error"),
        }
    }
}

async fn login(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: web::Json<UserCredentials>,
) -> HttpResponse {
    let mut state_lock = state.lock().unwrap();
    
    match state_lock.login(&req.username, &req.password) {
        Ok((user, session_id)) => {
            let cookie_str = format!("session_id={}; Path=/; HttpOnly", session_id);
            HttpResponse::Ok()
                .append_header(("Set-Cookie", cookie_str))
                .json(user)
        },
        Err(_) => error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Invalid credentials"),
    }
}

async fn logout(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: HttpRequest,
) -> HttpResponse {
    if let Some(session_id) = get_session_id(&req) {
        let mut state_lock = state.lock().unwrap();
        
        match state_lock.logout(&session_id) {
            Ok(()) => HttpResponse::Ok().json(serde_json::json!({})),
            Err(_) => error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required"),
        }
    } else {
        error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

async fn get_me(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: HttpRequest,
) -> HttpResponse {
    if let Some(session_id) = get_session_id(&req) {
        let state_lock = state.lock().unwrap();
        if let Some(user) = state_lock.get_user_by_session(&session_id) {
            HttpResponse::Ok().json(user.clone())
        } else {
            error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
        }
    } else {
        error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

async fn change_password(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: HttpRequest,
    body: web::Json<ChangePasswordRequest>,
) -> HttpResponse {
    if let Some(session_id) = get_session_id(&req) {
        let mut state_lock = state.lock().unwrap();
        
        match state_lock.change_password(&session_id, &body.old_password, &body.new_password) {
            Ok(()) => HttpResponse::Ok().json(serde_json::json!({})),
            Err(msg) => {
                if msg == "Invalid credentials" {
                    error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Invalid credentials")
                } else if msg == "Password too short" {
                    error_response(actix_web::http::StatusCode::BAD_REQUEST, "Password too short")
                } else {
                    error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
                }
            }
        }
    } else {
        error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

async fn get_todos(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: HttpRequest,
) -> HttpResponse {
    if let Some(session_id) = get_session_id(&req) {
        let state_lock = state.lock().unwrap();
        if let Some(user_id) = state_lock.get_user_id_from_session(&session_id) {
            let todos = state_lock.get_all_todos_for_user(user_id);
            HttpResponse::Ok().json(todos)
        } else {
            error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
        }
    } else {
        error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

async fn create_todo(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: HttpRequest,
    body: web::Json<NewTodo>,
) -> HttpResponse {
    if let Some(session_id) = get_session_id(&req) {
        let mut state_lock = state.lock().unwrap();
        if let Some(user_id) = state_lock.get_user_id_from_session(&session_id) {
            // Validate input
            if body.title.is_empty() {
                return error_response(actix_web::http::StatusCode::BAD_REQUEST, "Title is required");
            }
            
            let description = body.description.clone().unwrap_or_default();
            let todo = state_lock.create_todo(user_id, body.title.clone(), description);
            
            HttpResponse::Created().json(todo)
        } else {
            error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
        }
    } else {
        error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

async fn get_todo(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: HttpRequest,
    path: web::Path<u32>,
) -> HttpResponse {
    let todo_id = path.into_inner();
    
    if let Some(session_id) = get_session_id(&req) {
        let state_lock = state.lock().unwrap();
        if let Some(user_id) = state_lock.get_user_id_from_session(&session_id) {
            if let Some(todo) = state_lock.get_todo_by_user_and_id(user_id, todo_id) {
                HttpResponse::Ok().json(todo)
            } else {
                error_response(actix_web::http::StatusCode::NOT_FOUND, "Todo not found")
            }
        } else {
            error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
        }
    } else {
        error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

async fn update_todo(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: HttpRequest,
    path: web::Path<u32>,
    body: web::Json<TodoUpdate>,
) -> HttpResponse {
    let todo_id = path.into_inner();
    
    if let Some(session_id) = get_session_id(&req) {
        let mut state_lock = state.lock().unwrap();
        if let Some(user_id) = state_lock.get_user_id_from_session(&session_id) {
            match state_lock.update_todo(user_id, todo_id, body.into_inner()) {
                Ok(updated_todo) => HttpResponse::Ok().json(updated_todo),
                Err("Todo not found") => error_response(actix_web::http::StatusCode::NOT_FOUND, "Todo not found"),
                Err("Title is required") => error_response(actix_web::http::StatusCode::BAD_REQUEST, "Title is required"),
                _ => error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required"),
            }
        } else {
            error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
        }
    } else {
        error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

async fn delete_todo(
    state: web::Data<Arc<Mutex<AppState>>>,
    req: HttpRequest,
    path: web::Path<u32>,
) -> HttpResponse {
    let todo_id = path.into_inner();
    
    if let Some(session_id) = get_session_id(&req) {
        let mut state_lock = state.lock().unwrap();
        if let Some(user_id) = state_lock.get_user_id_from_session(&session_id) {
            if state_lock.delete_todo(user_id, todo_id) {
                HttpResponse::NoContent().finish()
            } else {
                error_response(actix_web::http::StatusCode::NOT_FOUND, "Todo not found")
            }
        } else {
            error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
        }
    } else {
        error_response(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
    }
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    // Parse command line arguments
    let args: Vec<String> = std::env::args().collect();
    let mut port = 8080; // Default port
    
    for i in 0..args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse().expect("Port must be a number");
            break;
        }
    }
    
    println!("Starting server on port {}", port);

    let app_state = web::Data::new(Arc::new(Mutex::new(AppState::new())));
    
    HttpServer::new(move || {
        App::new()
            .app_data(app_state.clone())
            .wrap(middleware::DefaultHeaders::new().add(("Content-Type", "application/json")))
            .route("/register", web::post().to(register))
            .route("/login", web::post().to(login))
            .route("/logout", web::post().to(logout))
            .route("/me", web::get().to(get_me))
            .route("/password", web::put().to(change_password))
            .route("/todos", web::get().to(get_todos))
            .route("/todos", web::post().to(create_todo))
            .route("/todos/{id}", web::get().to(get_todo))
            .route("/todos/{id}", web::put().to(update_todo))
            .route("/todos/{id}", web::delete().to(delete_todo))
    })
    .bind(format!("0.0.0.0:{}", port))?
    .run()
    .await
}