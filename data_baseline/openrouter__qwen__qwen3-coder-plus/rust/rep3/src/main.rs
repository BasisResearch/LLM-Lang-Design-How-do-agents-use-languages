use actix_web::{web, App, HttpResponse, HttpServer, middleware, HttpRequest, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use regex::Regex;
use chrono::{DateTime, Utc, SecondsFormat};
use uuid::Uuid;

// Data structures
#[derive(Serialize, Deserialize, Clone)]
struct User {
    id: u32,
    username: String,
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
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    completed: Option<bool>,
}

// Application state
#[derive(Clone)]
struct AppState {
    users: Arc<Mutex<HashMap<u32, User>>>,
    user_credentials: Arc<Mutex<HashMap<String, String>>>, // username -> password
    todos: Arc<Mutex<HashMap<u32, HashMap<u32, Todo>>>>,   // user_id -> todo_id -> Todo
    sessions: Arc<Mutex<HashMap<String, u32>>>,            // session_token -> user_id
    next_user_id: Arc<Mutex<u32>>,
    next_todo_id: Arc<Mutex<u32>>,
}

impl AppState {
    fn new() -> Self {
        AppState {
            users: Arc::new(Mutex::new(HashMap::new())),
            user_credentials: Arc::new(Mutex::new(HashMap::new())),
            todos: Arc::new(Mutex::new(HashMap::new())),
            sessions: Arc::new(Mutex::new(HashMap::new())),
            next_user_id: Arc::new(Mutex::new(1)),
            next_todo_id: Arc::new(Mutex::new(1)),
        }
    }

    fn get_user_id_from_session(&self, req: &HttpRequest) -> Option<u32> {
        if let Some(cookie) = req.cookie("session_id") {
            let sessions = self.sessions.lock().unwrap();
            if let Some(&user_id) = sessions.get(cookie.value()) {
                return Some(user_id);
            }
        }
        None
    }
}

fn validate_username(username: &str) -> bool {
    if username.len() < 3 || username.len() > 50 {
        return false;
    }
    
    let re = Regex::new(r"^[a-zA-Z0-9_]+$").unwrap();
    re.is_match(username)
}

async fn register(
    data: web::Data<AppState>,
    req: web::Json<RegisterRequest>,
) -> Result<HttpResponse> {
    let username = &req.username;
    let password = &req.password;

    if !validate_username(username) {
        return Ok(HttpResponse::BadRequest()
            .json(serde_json::json!({"error": "Invalid username"})));
    }

    if password.len() < 8 {
        return Ok(HttpResponse::BadRequest()
            .json(serde_json::json!({"error": "Password too short"})));
    }

    let mut users = data.users.lock().unwrap();
    let mut user_credentials = data.user_credentials.lock().unwrap();

    if user_credentials.contains_key(username) {
        return Ok(HttpResponse::Conflict()
            .json(serde_json::json!({"error": "Username already exists"})));
    }

    let user_id = *data.next_user_id.lock().unwrap();
    *data.next_user_id.lock().unwrap() += 1;

    let user = User {
        id: user_id,
        username: username.clone(),
    };

    users.insert(user_id, user.clone());
    user_credentials.insert(username.clone(), password.clone());

    // Initialize empty todos map for this user
    data.todos.lock().unwrap().insert(user_id, HashMap::new());

    Ok(HttpResponse::Created()
        .json(serde_json::json!({ "id": user.id, "username": user.username })))
}

async fn login(
    data: web::Data<AppState>,
    req: web::Json<LoginRequest>,
) -> Result<HttpResponse> {
    let username = &req.username;
    let password = &req.password;

    let user_credentials = data.user_credentials.lock().unwrap();
    let correct_pass = user_credentials.get(username);

    if correct_pass != Some(password) {
        return Ok(HttpResponse::Unauthorized()
            .json(serde_json::json!({"error": "Invalid credentials"})));
    }

    // Find the user id for the username
    let users = data.users.lock().unwrap();
    let user_id = match users.values().find(|u| &u.username == username).map(|u| u.id) {
        Some(id) => id,
        None => {
            return Ok(HttpResponse::Unauthorized()
                .json(serde_json::json!({"error": "Invalid credentials"})));
        }
    };
    
    drop(users);
    drop(user_credentials);

    // Generate session ID and store it
    let session_id = Uuid::new_v4().to_string();
    {
        let mut sessions = data.sessions.lock().unwrap();
        sessions.insert(session_id.clone(), user_id);
    }

    let users = data.users.lock().unwrap();
    let user = match users.get(&user_id) {
        Some(u) => u.clone(),
        None => {
            return Ok(HttpResponse::InternalServerError().json(serde_json::json!({"error": "User lookup failed"})));
        }
    };
    
    drop(users);

    Ok(HttpResponse::Ok()
        .append_header(("Set-Cookie", format!("session_id={}; Path=/; HttpOnly", session_id)))
        .json(serde_json::json!({ "id": user.id, "username": user.username })))
}

async fn logout(data: web::Data<AppState>, req: HttpRequest) -> Result<HttpResponse> {
    if let Some(cookie) = req.cookie("session_id") {
        let session_id = cookie.value();
        let mut sessions = data.sessions.lock().unwrap();
        sessions.remove(session_id);
    }

    Ok(HttpResponse::Ok().json(serde_json::json!({})))
}

async fn get_current_user(data: web::Data<AppState>, req: HttpRequest) -> Result<HttpResponse> {
    if let Some(user_id) = data.get_user_id_from_session(&req) {
        let users = data.users.lock().unwrap();
        if let Some(user) = users.get(&user_id) {
            let response = serde_json::json!({ "id": user.id, "username": user.username });
            drop(users);
            return Ok(HttpResponse::Ok().json(response));
        }
    }

    Ok(HttpResponse::Unauthorized()
        .json(serde_json::json!({"error": "Authentication required"})))
}

async fn change_password(
    data: web::Data<AppState>,
    req: HttpRequest,
    payload: web::Json<ChangePasswordRequest>,
) -> Result<HttpResponse> {
    let old_password = &payload.old_password;
    let new_password = &payload.new_password;

    if let Some(user_id) = data.get_user_id_from_session(&req) {
        let users = data.users.lock().unwrap();
        let username = match users.get(&user_id) {
            Some(user) => user.username.clone(),
            None => return Ok(HttpResponse::InternalServerError().json(serde_json::json!({"error": "User lookup failed"}))),
        };
        drop(users);

        let mut user_credentials = data.user_credentials.lock().unwrap();
        let current_password = match user_credentials.get(&username) {
            Some(pass) => pass.clone(),
            None => return Ok(HttpResponse::InternalServerError().json(serde_json::json!({"error": "Credentials lookup failed"}))),
        };

        if current_password != *old_password {
            return Ok(HttpResponse::Unauthorized()
                .json(serde_json::json!({"error": "Invalid credentials"})));
        }

        if new_password.len() < 8 {
            return Ok(HttpResponse::BadRequest()
                .json(serde_json::json!({"error": "Password too short"})));
        }

        user_credentials.insert(username, new_password.clone());
        drop(user_credentials);

        return Ok(HttpResponse::Ok().json(serde_json::json!({})));
    }

    Ok(HttpResponse::Unauthorized()
        .json(serde_json::json!({"error": "Authentication required"})))
}

async fn get_todos(data: web::Data<AppState>, req: HttpRequest) -> Result<HttpResponse> {
    if let Some(user_id) = data.get_user_id_from_session(&req) {
        let todos = data.todos.lock().unwrap();
        if let Some(user_todos_map) = todos.get(&user_id) {
            let mut result: Vec<Todo> = user_todos_map.values().cloned().collect();
            // Sort by ID ascending as requested
            result.sort_by(|a, b| a.id.cmp(&b.id));
            
            let todos_json: Vec<serde_json::Value> = result
                .iter()
                .map(|t| serde_json::json!({
                    "id": t.id,
                    "title": t.title,
                    "description": t.description,
                    "completed": t.completed,
                    "created_at": t.created_at.to_rfc3339_opts(SecondsFormat::Secs, true),
                    "updated_at": t.updated_at.to_rfc3339_opts(SecondsFormat::Secs, true)
                }))
                .collect();

            drop(todos);
            return Ok(HttpResponse::Ok().json(todos_json));
        }
    }

    Ok(HttpResponse::Unauthorized()
        .json(serde_json::json!({"error": "Authentication required"})))
}

async fn create_todo(
    data: web::Data<AppState>,
    req: HttpRequest,
    payload: web::Json<CreateTodoRequest>,
) -> Result<HttpResponse> {
    if payload.title.trim().is_empty() {
        return Ok(HttpResponse::BadRequest()
            .json(serde_json::json!({"error": "Title is required"})));
    }

    if let Some(user_id) = data.get_user_id_from_session(&req) {
        let now = Utc::now();
        let todo_id = *data.next_todo_id.lock().unwrap();
        *data.next_todo_id.lock().unwrap() += 1;

        let todo = Todo {
            id: todo_id,
            title: payload.title.clone(),
            description: payload.description.clone().unwrap_or_default(),
            completed: false,
            created_at: now,
            updated_at: now,
        };

        {
            let mut todos = data.todos.lock().unwrap();
            let user_todos = todos.entry(user_id).or_insert_with(HashMap::new);
            user_todos.insert(todo_id, todo.clone());
        } // Explicity drop the lock before serializing

        return Ok(HttpResponse::Created().json(serde_json::json!({
            "id": todo.id,
            "title": todo.title,
            "description": todo.description,
            "completed": todo.completed,
            "created_at": todo.created_at.to_rfc3339_opts(SecondsFormat::Secs, true),
            "updated_at": todo.updated_at.to_rfc3339_opts(SecondsFormat::Secs, true)
        })));
    }

    Ok(HttpResponse::Unauthorized()
        .json(serde_json::json!({"error": "Authentication required"})))
}

async fn get_todo(
    data: web::Data<AppState>,
    req: HttpRequest,
    path: web::Path<u32>,
) -> Result<HttpResponse> {
    let todo_id = path.into_inner();

    if let Some(user_id) = data.get_user_id_from_session(&req) {
        let todos = data.todos.lock().unwrap();
        if let Some(user_todos) = todos.get(&user_id) {
            if let Some(todo) = user_todos.get(&todo_id) {
                let response = serde_json::json!({
                    "id": todo.id,
                    "title": todo.title,
                    "description": todo.description,
                    "completed": todo.completed,
                    "created_at": todo.created_at.to_rfc3339_opts(SecondsFormat::Secs, true),
                    "updated_at": todo.updated_at.to_rfc3339_opts(SecondsFormat::Secs, true)
                });
                drop(todos);
                return Ok(HttpResponse::Ok().json(response));
            }
        }
    }

    Ok(HttpResponse::NotFound()
        .json(serde_json::json!({"error": "Todo not found"})))
}

async fn update_todo(
    data: web::Data<AppState>,
    req: HttpRequest,
    path: web::Path<u32>,
    payload: web::Json<UpdateTodoRequest>,
) -> Result<HttpResponse> {
    let todo_id = path.into_inner();

    if let Some(user_id) = data.get_user_id_from_session(&req) {
        let mut todos = data.todos.lock().unwrap();
        if let Some(user_todos) = todos.get_mut(&user_id) {
            if let Some(todo) = user_todos.get_mut(&todo_id) {
                // Validate title if present
                if let Some(ref new_title) = payload.title {
                    if new_title.trim().is_empty() {
                        drop(todos);
                        return Ok(HttpResponse::BadRequest()
                            .json(serde_json::json!({"error": "Title is required"})));
                    }
                    todo.title = new_title.clone();
                }
                
                // Update other fields if present
                if let Some(ref new_description) = payload.description {
                    todo.description = new_description.clone();
                }
                
                if let Some(new_completed) = payload.completed {
                    todo.completed = new_completed;
                }
                
                // Update the updated_at field
                todo.updated_at = Utc::now();
                
                // Serialize the updated todo
                let response = serde_json::json!({
                    "id": todo.id,
                    "title": todo.title.clone(),
                    "description": todo.description.clone(),
                    "completed": todo.completed,
                    "created_at": todo.created_at.to_rfc3339_opts(SecondsFormat::Secs, true),
                    "updated_at": todo.updated_at.to_rfc3339_opts(SecondsFormat::Secs, true)
                });
                
                drop(todos);
                return Ok(HttpResponse::Ok().json(response));
            }
        }
    }

    Ok(HttpResponse::NotFound()
        .json(serde_json::json!({"error": "Todo not found"})))
}

async fn delete_todo(
    data: web::Data<AppState>,
    req: HttpRequest,
    path: web::Path<u32>,
) -> Result<HttpResponse> {
    let todo_id = path.into_inner();

    if let Some(user_id) = data.get_user_id_from_session(&req) {
        let mut todos = data.todos.lock().unwrap();
        if let Some(user_todos) = todos.get_mut(&user_id) {
            if user_todos.contains_key(&todo_id) {
                user_todos.remove(&todo_id);
                drop(todos);
                return Ok(HttpResponse::NoContent().finish());
            } else {
                drop(todos);
                return Ok(HttpResponse::NotFound()
                    .json(serde_json::json!({"error": "Todo not found"})));
            }
        } else {
            drop(todos);
            return Ok(HttpResponse::NotFound()
                .json(serde_json::json!({"error": "Todo not found"})));
        }
    }

    Ok(HttpResponse::NotFound()
        .json(serde_json::json!({"error": "Todo not found"})))
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mut port = 8080;

    for i in 0..args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse::<u16>().expect("Port must be a valid number");
            break;
        }
    }

    let app_state = web::Data::new(AppState::new());
    
    println!("Starting server on 0.0.0.0:{}", port);
    
    HttpServer::new(move || {
        App::new()
            .app_data(app_state.clone())
            .wrap(middleware::DefaultHeaders::new().add(("Content-Type", "application/json")))
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