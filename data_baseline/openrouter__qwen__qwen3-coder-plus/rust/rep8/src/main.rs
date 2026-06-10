use actix_web::{web, App, HttpResponse, HttpServer, HttpRequest, Result, middleware::Logger};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use uuid::Uuid;
use chrono::{DateTime, Utc, SubsecRound};
use std::collections::HashSet;

// State structure
#[derive(Clone)]
struct AppState {
    users: Arc<Mutex<HashMap<i32, User>>>,
    todos: Arc<Mutex<HashMap<i32, Todo>>>,
    sessions: Arc<Mutex<HashMap<String, i32>>>, // session_id -> user_id
    user_todos: Arc<Mutex<HashMap<i32, HashSet<i32>>>>, // user_id -> set of todo_ids
    next_user_id: Arc<Mutex<i32>>,
    next_todo_id: Arc<Mutex<i32>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct User {
    id: i32,
    username: String,
    password: String, // This would normally be hashed
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Todo {
    id: i32,
    title: String,
    description: String,
    completed: bool,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Deserialize)]
struct RegisterData {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct LoginData {
    username: String,
    password: String,
}

#[derive(Deserialize)]
struct ChangePasswordData {
    old_password: String,
    new_password: String,
}

#[derive(Deserialize)]
struct CreateTodoData {
    title: String,
    description: Option<String>,
}

#[derive(Deserialize)]
struct UpdateTodoData {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

impl AppState {
    fn new() -> Self {
        Self {
            users: Arc::new(Mutex::new(HashMap::new())),
            todos: Arc::new(Mutex::new(HashMap::new())),
            sessions: Arc::new(Mutex::new(HashMap::new())),
            user_todos: Arc::new(Mutex::new(HashMap::new())),
            next_user_id: Arc::new(Mutex::new(0)),
            next_todo_id: Arc::new(Mutex::new(0)),
        }
    }
}

// Helper functions
fn now() -> DateTime<Utc> {
    Utc::now().trunc_subsecs(0) // Truncate to seconds for consistent format
}

fn generate_session_id() -> String {
    Uuid::new_v4().to_string()
}

// Enhanced helper to extract session ID from cookies - corrected version
fn extract_session_id(req: &HttpRequest) -> Option<String> {
    use actix_web::http::header::COOKIE;
    
    if let Some(cookie_header) = req.headers().get(COOKIE) {
        if let Ok(cookie_str) = cookie_header.to_str() {
            for cookie_pair in cookie_str.split(';') {
                let trimmed = cookie_pair.trim();
                if let Some(pos) = trimmed.find('=') {
                    let (key, value) = trimmed.split_at(pos);
                    if key == "session_id" {
                        return Some(value[1..].to_string()); // skip the '='
                    }
                }
            }
        }
    }
    None
}

// Endpoint implementations
async fn register(data: web::Json<RegisterData>, state: web::Data<AppState>) -> Result<HttpResponse> {
    let reg_data = data.into_inner();
    
    // Validate username format (alphanumeric + underscore, 3-50 chars)
    if !reg_data.username.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') || 
       reg_data.username.len() < 3 || reg_data.username.len() > 50 {
        return Ok(HttpResponse::BadRequest().json(serde_json::json!({"error": "Invalid username"})));
    }
    
    // Validate password length
    if reg_data.password.len() < 8 {
        return Ok(HttpResponse::BadRequest().json(serde_json::json!({"error": "Password too short"})));
    }
    
    let mut users = state.users.lock().unwrap();
    
    // Check if username already exists
    for user in users.values() {
        if user.username == reg_data.username {
            return Ok(HttpResponse::Conflict().json(serde_json::json!({"error": "Username already exists"})));
        }
    }
    
    // Generate new user ID
    let user_id = {
        let mut id_counter = state.next_user_id.lock().unwrap();
        *id_counter += 1;
        *id_counter
    };
    
    let new_user = User {
        id: user_id,
        username: reg_data.username,
        password: reg_data.password,
    };
    
    users.insert(user_id, new_user.clone());
    
    // Initialize empty todo set for this user
    {
        let mut user_todos = state.user_todos.lock().unwrap();
        user_todos.insert(user_id, HashSet::new());
    }
    
    Ok(HttpResponse::Created().json(serde_json::json!({
        "id": new_user.id,
        "username": new_user.username
    })))
}

async fn login(data: web::Json<LoginData>, state: web::Data<AppState>) -> Result<HttpResponse> {
    let login_data = data.into_inner();
    
    let users = state.users.lock().unwrap();
    
    // Find user by username
    let user_id = {
        let mut found_user_id = None;
        for (id, user) in users.iter() {
            if user.username == login_data.username && user.password == login_data.password {
                found_user_id = Some(*id);
                break;
            }
        }
        
        if found_user_id.is_none() {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({"error": "Invalid credentials"})));
        }
        
        found_user_id.unwrap()
    };
    
    // Generate session ID
    let session_id = generate_session_id();
    
    // Store session
    {
        let mut sessions = state.sessions.lock().unwrap();
        sessions.insert(session_id.clone(), user_id);
    }
    
    // Create response with Set-Cookie header
    let user = users.get(&user_id).unwrap().clone();
    
    Ok(HttpResponse::Ok()
        .append_header(("Set-Cookie", format!("session_id={}; Path=/; HttpOnly", session_id)))
        .json(serde_json::json!({
            "id": user.id,
            "username": user.username,
        })))
}

async fn logout(req: HttpRequest, state: web::Data<AppState>) -> Result<HttpResponse> {
    if let Some(session_id) = extract_session_id(&req) {
        {
            let mut sessions = state.sessions.lock().unwrap();
            sessions.remove(&session_id);
        }
        Ok(HttpResponse::Ok().json(serde_json::json!({})))
    } else {
        Ok(HttpResponse::Unauthorized().json(serde_json::json!({"error": "Authentication required"})))
    }
}

async fn get_current_user(req: HttpRequest, state: web::Data<AppState>) -> Result<HttpResponse> {
    let user_id = match get_auth_user_id(&req, &state) {
        Ok(id) => id,
        Err(resp) => return Ok(resp),
    };
    
    let users = state.users.lock().unwrap();
    
    if let Some(user) = users.get(&user_id) {
        Ok(HttpResponse::Ok().json(serde_json::json!({
            "id": user.id,
            "username": user.username,
        })))
    } else {
        Ok(HttpResponse::Unauthorized().json(serde_json::json!({"error": "Authentication required"})))
    }
}

async fn change_password(
    req: HttpRequest,
    data: web::Json<ChangePasswordData>,
    state: web::Data<AppState>
) -> Result<HttpResponse> {
    let user_id = match get_auth_user_id(&req, &state) {
        Ok(id) => id,
        Err(resp) => return Ok(resp),
    };
    
    let change_data = data.into_inner();
    
    if change_data.new_password.len() < 8 {
        return Ok(HttpResponse::BadRequest().json(serde_json::json!({"error": "Password too short"})));
    }
    
    let mut users = state.users.lock().unwrap();
    if let Some(user) = users.get_mut(&user_id) {
        // Verify old password
        if user.password != change_data.old_password {
            return Ok(HttpResponse::Unauthorized().json(serde_json::json!({"error": "Invalid credentials"})));
        }
        
        // Update password
        user.password = change_data.new_password;
        Ok(HttpResponse::Ok().json(serde_json::json!({})))
    } else {
        Ok(HttpResponse::Unauthorized().json(serde_json::json!({"error": "Authentication required"})))
    }
}

async fn get_todos(req: HttpRequest, state: web::Data<AppState>) -> Result<HttpResponse> {
    let user_id = match get_auth_user_id(&req, &state) {
        Ok(id) => id,
        Err(resp) => return Ok(resp),
    };
    
    let todos = state.todos.lock().unwrap();
    
    let user_todo_ids = {
        let user_todos = state.user_todos.lock().unwrap();
        user_todos.get(&user_id).cloned().unwrap_or_default()
    };
    
    let mut user_todos: Vec<Todo> = Vec::new();
    for todo_id in user_todo_ids {
        if let Some(todo) = todos.get(&todo_id) {
            user_todos.push(todo.clone());
        }
    }
    
    // Sort by ID
    user_todos.sort_by(|a, b| a.id.cmp(&b.id));
    
    Ok(HttpResponse::Ok().json(user_todos))
}

async fn create_todo(
    req: HttpRequest,
    data: web::Json<CreateTodoData>,
    state: web::Data<AppState>
) -> Result<HttpResponse> {
    let user_id = match get_auth_user_id(&req, &state) {
        Ok(id) => id,
        Err(resp) => return Ok(resp),
    };
    
    let todo_data = data.into_inner();
    
    // Validate title
    if todo_data.title.is_empty() {
        return Ok(HttpResponse::BadRequest().json(serde_json::json!({"error": "Title is required"})));
    }
    
    let todo_id = {
        let mut id_counter = state.next_todo_id.lock().unwrap();
        *id_counter += 1;
        *id_counter
    };
    
    let now_time = now();
    
    let new_todo = Todo {
        id: todo_id,
        title: todo_data.title,
        description: todo_data.description.unwrap_or_else(|| String::new()),
        completed: false,
        created_at: now_time,
        updated_at: now_time,
    };
    
    {
        let mut todos = state.todos.lock().unwrap();
        todos.insert(todo_id, new_todo.clone());
        
        // Add to user's todo list
        let mut user_todos = state.user_todos.lock().unwrap();
        if let Some(todo_set) = user_todos.get_mut(&user_id) {
            todo_set.insert(todo_id);
        }
    }
    
    Ok(HttpResponse::Created().json(new_todo))
}

async fn get_todo(
    req: HttpRequest,
    path: web::Path<i32>,
    state: web::Data<AppState>
) -> Result<HttpResponse> {
    let user_id = match get_auth_user_id(&req, &state) {
        Ok(id) => id,
        Err(resp) => return Ok(resp),
    };
    let todo_id = path.into_inner();
    
    let todo = {
        let todos = state.todos.lock().unwrap();
        todos.get(&todo_id).cloned()
    };
    
    if let Some(todo) = todo {
        // Check if this todo belongs to the authenticated user
        let user_todo_ids = {
            let user_todos = state.user_todos.lock().unwrap();
            user_todos.get(&user_id).cloned().unwrap_or_default()
        };
        
        if !user_todo_ids.contains(&todo_id) {
            return Ok(HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"})));
        }
        
        Ok(HttpResponse::Ok().json(todo))
    } else {
        Ok(HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"})))
    }
}

async fn update_todo(
    req: HttpRequest,
    path: web::Path<i32>,
    data: web::Json<UpdateTodoData>,
    state: web::Data<AppState>
) -> Result<HttpResponse> {
    let user_id = match get_auth_user_id(&req, &state) {
        Ok(id) => id,
        Err(resp) => return Ok(resp),
    };
    let todo_id = path.into_inner();
    let update_data = data.into_inner();
    
    // Validate title if provided
    if let Some(title) = &update_data.title {
        if title.is_empty() {
            return Ok(HttpResponse::BadRequest().json(serde_json::json!({"error": "Title is required"})));
        }
    }
    
    let mut todos = state.todos.lock().unwrap();
    
    // Check if this todo belongs to the authenticated user
    {
        let user_todo_ids = state.user_todos.lock().unwrap();
        if let Some(todo_set) = user_todo_ids.get(&user_id) {
            if !todo_set.contains(&todo_id) {
                return Ok(HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"})));
            }
        } else {
            return Ok(HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"})));
        }
    }
    
    if let Some(todo_ref) = todos.get(&todo_id) {
        // Make a mutable copy of the todo to update
        let mut todo = todo_ref.clone();
        
        // Update fields based on what was provided
        if let Some(title) = update_data.title {
            todo.title = title;
        }
        if let Some(description) = update_data.description {
            todo.description = description;
        }
        if let Some(completed) = update_data.completed {
            todo.completed = completed;
        }
        
        // Update timestamp
        todo.updated_at = now();
        
        // Insert the updated todo back into the map
        todos.insert(todo_id, todo.clone());
        
        Ok(HttpResponse::Ok().json(todo))
    } else {
        Ok(HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"})))
    }
}

async fn delete_todo(
    req: HttpRequest,
    path: web::Path<i32>,
    state: web::Data<AppState>
) -> Result<HttpResponse> {
    let user_id = match get_auth_user_id(&req, &state) {
        Ok(id) => id,
        Err(resp) => return Ok(resp),
    };
    let todo_id = path.into_inner();
    
    {
        let user_todo_ids = state.user_todos.lock().unwrap();
        if let Some(todo_set) = user_todo_ids.get(&user_id) {
            if !todo_set.contains(&todo_id) {
                return Ok(HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"})));
            }
        } else {
            return Ok(HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"})));
        }
    }
    
    let mut todos = state.todos.lock().unwrap();
    
    if todos.contains_key(&todo_id) {
        // Remove the todo from both maps
        todos.remove(&todo_id);
        {
            let mut user_todos = state.user_todos.lock().unwrap();
            if let Some(todo_list) = user_todos.get_mut(&user_id) {
                todo_list.remove(&todo_id);
            }
        }
        Ok(HttpResponse::NoContent().finish())
    } else {
        Ok(HttpResponse::NotFound().json(serde_json::json!({"error": "Todo not found"})))
    }
}

// Helper function to get the authenticated user's ID
fn get_auth_user_id(req: &HttpRequest, state: &AppState) -> Result<i32, HttpResponse> {
    let session_id = extract_session_id(req)
        .ok_or_else(|| HttpResponse::Unauthorized().json(serde_json::json!({"error": "Authentication required"})))?;
    
    let sessions = state.sessions.lock().unwrap();
    let user_id = *sessions.get(&session_id)
        .ok_or_else(|| HttpResponse::Unauthorized().json(serde_json::json!({"error": "Authentication required"})))?;
    
    Ok(user_id)
}

// Main function - parse command line args and start server
#[actix_web::main]
async fn main() -> std::io::Result<()> {
    // Initialize logging
    std::env::set_var("RUST_LOG", "actix_web=info");
    env_logger::init();

    // Parse command line arguments to get the port
    let mut port = 8080u16;
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse().expect("--port value must be a number");
            break;
        }
        i += 1;
    }

    // Create shared state
    let state = AppState::new();

    println!("Starting server on 0.0.0.0:{}", port);

    HttpServer::new(move || {
        App::new()
            .app_data(web::Data::new(state.clone()))
            .wrap(Logger::default())
            .service(
                web::resource("/register")
                    .route(web::post().to(register))
            )
            .service(
                web::resource("/login")
                    .route(web::post().to(login))
            )
            .service(
                web::resource("/logout")
                    .route(web::post().to(logout))
            )
            .service(
                web::resource("/me")
                    .route(web::get().to(get_current_user))
            )
            .service(
                web::resource("/password")
                    .route(web::put().to(change_password))
            )
            .service(
                web::resource("/todos")
                    .route(web::get().to(get_todos))
                    .route(web::post().to(create_todo))
            )
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