import re
import uuid
from datetime import datetime, timezone
from typing import Optional, Any, List, Dict

from fastapi import FastAPI, Request, HTTPException, Depends, Cookie
from fastapi.responses import JSONResponse, Response
from fastapi.exceptions import RequestValidationError
from pydantic import BaseModel

app = FastAPI()

class UserRecord:
    def __init__(self, user_id: int, username: str, password: str):
        self.id: int = user_id
        self.username: str = username
        self.password: str = password

class TodoRecord:
    def __init__(self, todo_id: int, user_id: int, title: str, description: str):
        self.id: int = todo_id
        self.user_id: int = user_id
        self.title: str = title
        self.description: str = description
        self.completed: bool = False
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.created_at: str = now
        self.updated_at: str = now

# Global state
users: Dict[int, UserRecord] = {}
usernames: Dict[str, int] = {}
todos: Dict[int, TodoRecord] = {}
sessions: Dict[str, int] = {}

next_user_id: int = 1
next_todo_id: int = 1

class RegisterRequest(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None

class LoginRequest(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None

class TodoCreateRequest(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = ""

class TodoUpdateRequest(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    completed: Optional[bool] = None

class PasswordUpdateRequest(BaseModel):
    old_password: Optional[str] = None
    new_password: Optional[str] = None

def get_current_user(session_id: Optional[str] = Cookie(default=None)) -> UserRecord:
    if not session_id or session_id not in sessions:
        raise HTTPException(status_code=401, detail="Authentication required")
    user_id = sessions[session_id]
    user = users.get(user_id)
    if not user:
        raise HTTPException(status_code=401, detail="Authentication required")
    return user

@app.exception_handler(HTTPException)
async def custom_http_exception_handler(request: Request, exc: HTTPException) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.detail},
    )

@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=400,
        content={"error": "Invalid request payload"},
    )

@app.post("/register", status_code=201)
async def register(req: RegisterRequest) -> Dict[str, Any]:
    if req.username is None or not re.match(r"^[a-zA-Z0-9_]{3,50}$", req.username):
        raise HTTPException(status_code=400, detail="Invalid username")
    if req.password is None or len(req.password) < 8:
        raise HTTPException(status_code=400, detail="Password too short")
    if req.username in usernames:
        raise HTTPException(status_code=409, detail="Username already exists")
    
    global next_user_id
    user_id = next_user_id
    next_user_id += 1
    users[user_id] = UserRecord(user_id, req.username, req.password)
    usernames[req.username] = user_id
    
    return {"id": user_id, "username": req.username}

@app.post("/login")
async def login(req: LoginRequest, response: Response) -> Dict[str, Any]:
    if req.username is None or req.password is None:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    
    user_id = usernames.get(req.username)
    if user_id is None:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    
    user = users[user_id]
    if user.password != req.password:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    
    token = uuid.uuid4().hex
    sessions[token] = user.id
    response.set_cookie(key="session_id", value=token, httponly=True, path="/")
    
    return {"id": user.id, "username": user.username}

@app.post("/logout")
async def logout(user: UserRecord = Depends(get_current_user), session_id: Optional[str] = Cookie(default=None)) -> Dict[str, Any]:
    if session_id and session_id in sessions:
        del sessions[session_id]
    return {}

@app.get("/me")
async def get_me(user: UserRecord = Depends(get_current_user)) -> Dict[str, Any]:
    return {"id": user.id, "username": user.username}

@app.put("/password")
async def update_password(req: PasswordUpdateRequest, user: UserRecord = Depends(get_current_user)) -> Dict[str, Any]:
    if req.old_password is None or user.password != req.old_password:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    if req.new_password is None or len(req.new_password) < 8:
        raise HTTPException(status_code=400, detail="Password too short")
    
    user.password = req.new_password
    return {}

@app.get("/todos")
async def get_todos(user: UserRecord = Depends(get_current_user)) -> List[Dict[str, Any]]:
    user_todos = [todo for todo in todos.values() if todo.user_id == user.id]
    user_todos.sort(key=lambda t: t.id)
    
    return [
        {
            "id": t.id,
            "title": t.title,
            "description": t.description,
            "completed": t.completed,
            "created_at": t.created_at,
            "updated_at": t.updated_at
        }
        for t in user_todos
    ]

@app.post("/todos", status_code=201)
async def create_todo(req: TodoCreateRequest, user: UserRecord = Depends(get_current_user)) -> Dict[str, Any]:
    if req.title is None or req.title == "":
        raise HTTPException(status_code=400, detail="Title is required")
    
    global next_todo_id
    todo_id = next_todo_id
    next_todo_id += 1
    
    description = req.description if req.description is not None else ""
    
    todo = TodoRecord(todo_id, user.id, req.title, description)
    todos[todo_id] = todo
    
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at
    }

@app.get("/todos/{todo_id}")
async def get_todo(todo_id: int, user: UserRecord = Depends(get_current_user)) -> Dict[str, Any]:
    todo = todos.get(todo_id)
    if not todo or todo.user_id != user.id:
        raise HTTPException(status_code=404, detail="Todo not found")
    
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at
    }

@app.put("/todos/{todo_id}")
async def update_todo(todo_id: int, req: TodoUpdateRequest, user: UserRecord = Depends(get_current_user)) -> Dict[str, Any]:
    todo = todos.get(todo_id)
    if not todo or todo.user_id != user.id:
        raise HTTPException(status_code=404, detail="Todo not found")
    
    if req.title is not None and req.title == "":
        raise HTTPException(status_code=400, detail="Title is required")
    
    if req.title is not None:
        todo.title = req.title
    if req.description is not None:
        todo.description = req.description
    if req.completed is not None:
        todo.completed = req.completed
        
    todo.updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at
    }

@app.delete("/todos/{todo_id}", status_code=204)
async def delete_todo(todo_id: int, user: UserRecord = Depends(get_current_user)) -> Response:
    todo = todos.get(todo_id)
    if not todo or todo.user_id != user.id:
        raise HTTPException(status_code=404, detail="Todo not found")
    
    del todos[todo_id]
    return Response(status_code=204)
