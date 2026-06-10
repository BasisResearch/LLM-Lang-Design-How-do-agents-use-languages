use actix_web::{web, App, HttpResponse, HttpServer, Result, middleware, cookie::Cookie};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use chrono::{Utc, DateTime};
use regex::Regex;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct User {
    id: u32,
    username: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Todo {
    id: u32,
    title: String,
    description: String,
    completed: bool,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct NewTodo {
    title: String,
    description: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct UpdateTodo {
    title: Option<String>,
    description: Option<String>,
    completed: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RegisterData {
    username: String,
    password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct LoginData {
    username: String,
    password: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PasswordUpdateData {
    old_password: String,
    new_password: String,
}

// Application state: stores users, todos, sessions and passwords
struct AppState {
    users: Arc<Mutex<HashMap<u32, User>>>,
    todos: Arc<Mutex<HashMap<u32, HashMap<u32, Todo>>>>, // user_id -> todo_id -> Todo
    sessions: Arc<Mutex<HashMap<String, u32>>>, // session_token -> user_id
    passwords: Arc<Mutex<HashMap<u32, String>>>, // user_id -> password
    next_user_id: Arc<Mutex<u32>>,
    next_todo_id: Arc<Mutex<u32>>,
}

fn json_response<T: Serialize>(data: T) -> Result<HttpResponse> {
    Ok(HttpResponse::Ok()
        .content_type("application/json")
        .json(data))
}

fn json_error(status: actix_web::http::StatusCode, message: &str) -> Result<HttpResponse> {
    Ok(HttpResponse::build(status)
        .content_type("application/json")
        .json(serde_json::json!({"error": message})))
}

fn auth_check(req: &actix_web::HttpRequest, sessions: &Arc<Mutex<HashMap<String, u32>>>) -> Option<u32> {
    if let Some(cookie) = req.cookie("session_id") {
        let session_token = cookie.value();
        let sessions_lock = sessions.lock().unwrap();
        if let Some(user_id) = sessions_lock.get(session_token).cloned() {
            return Some(user_id);
        }
    }
    None
}

fn validate_username(username: &str) -> bool {
    if username.len() < 3 || username.len() > 50 {
        return false;
    }
    Regex::new(r"^[a-zA-Z0-9_]+$").unwrap().is_match(username)
}

async fn register(
    data: web::Json<RegisterData>,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    if !validate_username(&data.username) {
        return json_error(actix_web::http::StatusCode::BAD_REQUEST, "Invalid username");
    }

    if data.password.len() < 8 {
        return json_error(actix_web::http::StatusCode::BAD_REQUEST, "Password too short");
    }

    let mut users = app_state.users.lock().unwrap();
    
    // Check if username already exists
    for (_, user) in users.iter() {
        if user.username == data.username {
            return json_error(actix_web::http::StatusCode::CONFLICT, "Username already exists");
        }
    }

    let user_id = *app_state.next_user_id.lock().unwrap();
    *app_state.next_user_id.lock().unwrap() += 1;

    let user = User {
        id: user_id,
        username: data.username.clone(),
    };

    users.insert(user_id, user);

    let mut passwords = app_state.passwords.lock().unwrap();
    passwords.insert(user_id, data.password.clone());

    let user_todos_map = HashMap::new();
    app_state.todos.lock().unwrap().insert(user_id, user_todos_map);

    let response = User {
        id: user_id,
        username: data.username.clone(),
    };

    Ok(HttpResponse::Created()
        .content_type("application/json")
        .json(response))
}

async fn login(
    data: web::Json<LoginData>,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    let users = app_state.users.lock().unwrap();
    let mut user_id_opt = None;
    
    for (id, user) in users.iter() {
        if user.username == data.username {
            let passwords = app_state.passwords.lock().unwrap();
            if let Some(password) = passwords.get(id) {
                if password == &data.password {
                    user_id_opt = Some(*id);
                    break;
                }
            }
        }
    }

    if let Some(user_id) = user_id_opt {
        let session_id = uuid::Uuid::new_v4().to_string();
        
        {
            let mut sessions = app_state.sessions.lock().unwrap();
            sessions.insert(session_id.clone(), user_id);
        }
        
        let _cookies = app_state.sessions.lock().unwrap();
        let response_data = User {
            id: user_id,
            username: data.username.clone(),
        };
        
        let mut cookie = Cookie::new("session_id", &session_id);
        cookie.set_path("/");
        cookie.set_http_only(true);
        
        Ok(HttpResponse::Ok()
            .content_type("application/json")
            .cookie(cookie)
            .json(response_data))
    } else {
        json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Invalid credentials")
    }
}

async fn logout(
    req: actix_web::HttpRequest,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    let sessions = app_state.sessions.clone();
    let user_id = auth_check(&req, &sessions);
    
    if user_id.is_none() {
        return json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required");
    }

    // Remove the session token server-side
    if let Some(cookie) = req.cookie("session_id") {
        let session_token = cookie.value();
        let mut sessions_lock = app_state.sessions.lock().unwrap();
        sessions_lock.remove(session_token);
    }

    Ok(HttpResponse::Ok()
        .content_type("application/json")
        .json(serde_json::json!({})))
}

async fn get_user_info(
    req: actix_web::HttpRequest,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    let sessions = app_state.sessions.clone();
    let user_id = auth_check(&req, &sessions);
    
    if user_id.is_none() {
        return json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required");
    }

    let users = app_state.users.lock().unwrap();
    if let Some(user) = users.get(&user_id.unwrap()) {
        return json_response(User {
            id: user.id,
            username: user.username.clone(),
        });
    }

    json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required")
}

async fn update_password(
    req: actix_web::HttpRequest,
    data: web::Json<PasswordUpdateData>,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    let sessions = app_state.sessions.clone();
    let user_id = auth_check(&req, &sessions);
    
    if user_id.is_none() {
        return json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required");
    }

    let user_id = user_id.unwrap();

    // Check if old password matches
    let passwords = app_state.passwords.lock().unwrap();
    let current_password = passwords.get(&user_id).unwrap();

    if current_password != &data.old_password {
        return json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Invalid credentials");
    }

    if data.new_password.len() < 8 {
        return json_error(actix_web::http::StatusCode::BAD_REQUEST, "Password too short");
    }

    drop(passwords);
    
    let mut passwords = app_state.passwords.lock().unwrap();
    passwords.insert(user_id, data.new_password.clone());

    Ok(HttpResponse::Ok()
        .content_type("application/json")
        .json(serde_json::json!({})))
}

async fn get_todos(
    req: actix_web::HttpRequest,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    let sessions = app_state.sessions.clone();
    let user_id = auth_check(&req, &sessions);
    
    if user_id.is_none() {
        return json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required");
    }

    let user_id = user_id.unwrap();
    
    let todos = app_state.todos.lock().unwrap();
    let user_todos = todos.get(&user_id).unwrap();
    
    let mut todos_list: Vec<Todo> = user_todos.values().cloned().collect();
    todos_list.sort_by(|a, b| a.id.cmp(&b.id));  // Sort by id ascending

    json_response(todos_list)
}

async fn create_todo(
    req: actix_web::HttpRequest,
    data: web::Json<NewTodo>,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    let sessions = app_state.sessions.clone();
    let user_id = auth_check(&req, &sessions);
    
    if user_id.is_none() {
        return json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required");
    }

    if data.title.is_empty() {
        return json_error(actix_web::http::StatusCode::BAD_REQUEST, "Title is required");
    }

    let todo_id = *app_state.next_todo_id.lock().unwrap();
    *app_state.next_todo_id.lock().unwrap() += 1;

    let now = Utc::now();

    let todo = Todo {
        id: todo_id,
        title: data.title.clone(),
        description: data.description.as_ref().cloned().unwrap_or_else(|| "".to_string()),
        completed: false,
        created_at: now,
        updated_at: now,
    };

    let mut todos = app_state.todos.lock().unwrap();
    let user_todos = todos.get_mut(&user_id.unwrap()).unwrap();
    user_todos.insert(todo_id, todo);

    let response = todos.get(&user_id.unwrap()).unwrap().get(&todo_id).unwrap();

    Ok(HttpResponse::Created()
        .content_type("application/json")
        .json(response))
}

async fn get_todo(
    req: actix_web::HttpRequest,
    path: web::Path<u32>,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    let sessions = app_state.sessions.clone();
    let user_id = auth_check(&req, &sessions);
    
    if user_id.is_none() {
        return json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required");
    }

    let todo_id = path.into_inner();
    
    let todos = app_state.todos.lock().unwrap();
    let user_todos = todos.get(&user_id.unwrap());
    
    if let Some(user_todos) = user_todos {
        if let Some(todo) = user_todos.get(&todo_id) {
            return json_response(todo);
        }
    }
    
    json_error(actix_web::http::StatusCode::NOT_FOUND, "Todo not found")
}

async fn update_todo(
    req: actix_web::HttpRequest,
    path: web::Path<u32>,
    data: web::Json<UpdateTodo>,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    let sessions = app_state.sessions.clone();
    let user_id = auth_check(&req, &sessions);
    
    if user_id.is_none() {
        return json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required");
    }

    let user_id = user_id.unwrap();
    let todo_id = path.into_inner();

    if let Some(ref title) = data.title {
        if title.is_empty() {
            return json_error(actix_web::http::StatusCode::BAD_REQUEST, "Title is required");
        }
    }

    let mut todos = app_state.todos.lock().unwrap();
    
    if let Some(user_todos) = todos.get_mut(&user_id) {
        if let Some(todo) = user_todos.get_mut(&todo_id) {
            // Update fields if they're provided
            if let Some(title) = &data.title {
                todo.title = title.clone();
            }
            if let Some(description) = &data.description {
                todo.description = description.clone();
            }
            if let Some(completed) = data.completed {
                todo.completed = completed;
            }
            
            // Update timestamps
            todo.updated_at = Utc::now();
            
            let updated_todo = user_todos.get(&todo_id).unwrap().clone();
            return json_response(updated_todo);
        }
    }
    
    json_error(actix_web::http::StatusCode::NOT_FOUND, "Todo not found")
}

async fn delete_todo(
    req: actix_web::HttpRequest,
    path: web::Path<u32>,
    app_state: web::Data<AppState>,
) -> Result<HttpResponse> {
    let sessions = app_state.sessions.clone();
    let user_id = auth_check(&req, &sessions);
    
    if user_id.is_none() {
        return json_error(actix_web::http::StatusCode::UNAUTHORIZED, "Authentication required");
    }

    let user_id = user_id.unwrap();
    let todo_id = path.into_inner();

    let mut todos = app_state.todos.lock().unwrap();
    if let Some(user_todos) = todos.get_mut(&user_id) {
        if user_todos.contains_key(&todo_id) {
            user_todos.remove(&todo_id);
            return Ok(HttpResponse::NoContent().finish());
        }
    }
    
    json_error(actix_web::http::StatusCode::NOT_FOUND, "Todo not found")
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    
    let mut port = 8080; // default port
    for i in 0..args.len() {
        if args[i] == "--port" && i + 1 < args.len() {
            port = args[i + 1].parse::<u16>().expect("Invalid port number");
            break;
        }
    }

    let state = web::Data::new(AppState {
        users: Arc::new(Mutex::new(HashMap::new())),
        todos: Arc::new(Mutex::new(HashMap::new())),
        sessions: Arc::new(Mutex::new(HashMap::new())),
        passwords: Arc::new(Mutex::new(HashMap::new())),
        next_user_id: Arc::new(Mutex::new(1)),
        next_todo_id: Arc::new(Mutex::new(1)),
    });

    println!("Starting server on 0.0.0.0:{}", port);

    HttpServer::new(move || {
        App::new()
            .app_data(state.clone())
            .wrap(middleware::Logger::default())
            .route("/register", web::post().to(register))
            .route("/login", web::post().to(login))
            .route("/logout", web::post().to(logout))
            .route("/me", web::get().to(get_user_info))
            .route("/password", web::put().to(update_password))
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