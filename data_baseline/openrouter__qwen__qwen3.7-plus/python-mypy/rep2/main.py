import re
import secrets
from datetime import datetime, timezone
from typing import Any, Optional
from dataclasses import dataclass

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel
from fastapi.exceptions import RequestValidationError

class APIError(Exception):
    def __init__(self, status_code: int, message: str):
        self.status_code = status_code
        self.message = message

app = FastAPI()

@app.exception_handler(APIError)
async def api_error_handler(request: Request, exc: APIError) -> Response:
    return JSONResponse(status_code=exc.status_code, content={"error": exc.message})

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError) -> Response:
    return JSONResponse(status_code=400, content={"error": "Invalid request"})

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception) -> Response:
    return JSONResponse(status_code=500, content={"error": "Internal server error"})

@dataclass
class User:
    id: int
    username: str
    password: str

@dataclass
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str

next_user_id: int = 1
next_todo_id: int = 1
users: dict[int, User] = {}
sessions: dict[str, int] = {}
todos: dict[int, Todo] = {}
username_to_id: dict[str, int] = {}

def get_utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def format_user(user: User) -> dict[str, Any]:
    return {
        "id": user.id,
        "username": user.username
    }

def format_todo(todo: Todo) -> dict[str, Any]:
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at
    }

def get_current_user_id(request: Request) -> int:
    session_id = request.cookies.get("session_id")
    if not session_id or session_id not in sessions:
        raise APIError(status_code=401, message="Authentication required")
    return sessions[session_id]

class RegisterRequest(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None

class LoginRequest(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None

class PasswordRequest(BaseModel):
    old_password: Optional[str] = None
    new_password: Optional[str] = None

class TodoCreateRequest(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None

class TodoUpdateRequest(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    completed: Optional[bool] = None

@app.post("/register", status_code=201)
async def register(req: RegisterRequest) -> Response:
    global next_user_id
    if not isinstance(req.username, str) or not re.match(r"^[a-zA-Z0-9_]{3,50}$", req.username):
        raise APIError(status_code=400, message="Invalid username")
    if not isinstance(req.password, str) or len(req.password) < 8:
        raise APIError(status_code=400, message="Password too short")
    if req.username in username_to_id:
        raise APIError(status_code=409, message="Username already exists")
    
    user_id = next_user_id
    next_user_id += 1
    user = User(id=user_id, username=req.username, password=req.password)
    users[user_id] = user
    username_to_id[user.username] = user_id
    
    return JSONResponse(status_code=201, content=format_user(user))

@app.post("/login")
async def login(req: LoginRequest) -> Response:
    if not isinstance(req.username, str) or not isinstance(req.password, str):
        raise APIError(status_code=401, message="Invalid credentials")
    
    user_id = username_to_id.get(req.username)
    if not user_id:
        raise APIError(status_code=401, message="Invalid credentials")
    user = users[user_id]
    if user.password != req.password:
        raise APIError(status_code=401, message="Invalid credentials")
    
    session_token = secrets.token_hex(32)
    sessions[session_token] = user_id
    
    response = JSONResponse(status_code=200, content=format_user(user))
    response.set_cookie(key="session_id", value=session_token, httponly=True, path="/")
    return response

@app.post("/logout")
async def logout(request: Request) -> Response:
    get_current_user_id(request)
    session_id = request.cookies.get("session_id")
    if session_id:
        sessions.pop(session_id, None)
    
    response = JSONResponse(status_code=200, content={})
    response.delete_cookie(key="session_id", path="/")
    return response

@app.get("/me")
async def get_me(request: Request) -> Response:
    user_id = get_current_user_id(request)
    user = users[user_id]
    return JSONResponse(status_code=200, content=format_user(user))

@app.put("/password")
async def change_password(req: PasswordRequest, request: Request) -> Response:
    user_id = get_current_user_id(request)
    user = users[user_id]
    
    if not isinstance(req.old_password, str) or not isinstance(req.new_password, str):
        raise APIError(status_code=400, message="Invalid request")
    
    if user.password != req.old_password:
        raise APIError(status_code=401, message="Invalid credentials")
    if len(req.new_password) < 8:
        raise APIError(status_code=400, message="Password too short")
        
    user.password = req.new_password
    return JSONResponse(status_code=200, content={})

@app.get("/todos")
async def get_todos(request: Request) -> Response:
    user_id = get_current_user_id(request)
    user_todos = [format_todo(t) for t in todos.values() if t.user_id == user_id]
    user_todos.sort(key=lambda x: x["id"])
    return JSONResponse(status_code=200, content=user_todos)

@app.post("/todos", status_code=201)
async def create_todo(req: TodoCreateRequest, request: Request) -> Response:
    global next_todo_id
    user_id = get_current_user_id(request)
    
    if not isinstance(req.title, str) or not req.title.strip():
        raise APIError(status_code=400, message="Title is required")
    
    description = req.description if isinstance(req.description, str) else ""
    
    todo_id = next_todo_id
    next_todo_id += 1
    now = get_utc_now()
    todo = Todo(
        id=todo_id,
        user_id=user_id,
        title=req.title,
        description=description,
        completed=False,
        created_at=now,
        updated_at=now
    )
    todos[todo_id] = todo
    return JSONResponse(status_code=201, content=format_todo(todo))

@app.get("/todos/{todo_id}")
async def get_todo(todo_id: int, request: Request) -> Response:
    user_id = get_current_user_id(request)
    todo = todos.get(todo_id)
    if not todo or todo.user_id != user_id:
        raise APIError(status_code=404, message="Todo not found")
    return JSONResponse(status_code=200, content=format_todo(todo))

@app.put("/todos/{todo_id}")
async def update_todo(todo_id: int, req: TodoUpdateRequest, request: Request) -> Response:
    user_id = get_current_user_id(request)
    todo = todos.get(todo_id)
    if not todo or todo.user_id != user_id:
        raise APIError(status_code=404, message="Todo not found")
    
    if req.title is not None:
        if not isinstance(req.title, str) or not req.title.strip():
            raise APIError(status_code=400, message="Title is required")
        todo.title = req.title
        
    if req.description is not None:
        todo.description = req.description if isinstance(req.description, str) else ""
        
    if req.completed is not None:
        todo.completed = bool(req.completed)
        
    todo.updated_at = get_utc_now()
    return JSONResponse(status_code=200, content=format_todo(todo))

@app.delete("/todos/{todo_id}", status_code=204)
async def delete_todo(todo_id: int, request: Request) -> Response:
    user_id = get_current_user_id(request)
    todo = todos.get(todo_id)
    if not todo or todo.user_id != user_id:
        raise APIError(status_code=404, message="Todo not found")
    
    del todos[todo_id]
    return Response(status_code=204)
