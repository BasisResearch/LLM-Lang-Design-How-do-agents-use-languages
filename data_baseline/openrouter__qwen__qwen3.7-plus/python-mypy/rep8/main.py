import json
import re
import secrets
import datetime
from typing import Dict, Optional, cast

from fastapi import FastAPI, Request, Response, Depends
from fastapi.responses import JSONResponse

class User:
    def __init__(self, id: int, username: str, password: str) -> None:
        self.id: int = id
        self.username: str = username
        self.password: str = password

class Todo:
    def __init__(self, id: int, title: str, description: str, completed: bool, created_at: str, updated_at: str, user_id: int) -> None:
        self.id: int = id
        self.title: str = title
        self.description: str = description
        self.completed: bool = completed
        self.created_at: str = created_at
        self.updated_at: str = updated_at
        self.user_id: int = user_id

users: Dict[int, User] = {}
usernames_to_ids: Dict[str, int] = {}
next_user_id: int = 1

todos: Dict[int, Todo] = {}
next_todo_id: int = 1

sessions: Dict[str, int] = {}

app = FastAPI()

class AuthError(Exception):
    pass

@app.exception_handler(AuthError)
async def auth_exception_handler(request: Request, exc: AuthError) -> JSONResponse:
    return JSONResponse(status_code=401, content={"error": "Authentication required"})

async def get_current_user(request: Request) -> User:
    session_id = request.cookies.get("session_id")
    if not session_id or session_id not in sessions:
        raise AuthError()
    user_id = sessions[session_id]
    user = users.get(user_id)
    if not user:
        raise AuthError()
    return user

def get_utc_now_str() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

async def get_json(request: Request) -> Optional[Dict[str, object]]:
    try:
        body = await request.body()
        if not body:
            return {}
        return cast(Dict[str, object], json.loads(body))
    except json.JSONDecodeError:
        return None

@app.post("/register")
async def register(request: Request) -> JSONResponse:
    data = await get_json(request)
    if not isinstance(data, dict):
        return JSONResponse(status_code=400, content={"error": "Invalid request"})
    
    username = data.get("username")
    password = data.get("password")
    
    if not isinstance(username, str) or not isinstance(password, str):
        return JSONResponse(status_code=400, content={"error": "Invalid request"})
        
    if not re.match(r'^[a-zA-Z0-9_]{3,50}$', username):
        return JSONResponse(status_code=400, content={"error": "Invalid username"})
    if len(password) < 8:
        return JSONResponse(status_code=400, content={"error": "Password too short"})
    if username in usernames_to_ids:
        return JSONResponse(status_code=409, content={"error": "Username already exists"})
    
    global next_user_id
    user_id = next_user_id
    next_user_id += 1
    
    users[user_id] = User(id=user_id, username=username, password=password)
    usernames_to_ids[username] = user_id
    
    return JSONResponse(status_code=201, content={"id": user_id, "username": username})

@app.post("/login")
async def login(request: Request) -> JSONResponse:
    data = await get_json(request)
    if not isinstance(data, dict):
        return JSONResponse(status_code=400, content={"error": "Invalid request"})
    
    username = data.get("username")
    password = data.get("password")
    
    if not isinstance(username, str) or not isinstance(password, str):
        return JSONResponse(status_code=401, content={"error": "Invalid credentials"})
    
    user_id = usernames_to_ids.get(username)
    if not user_id:
        return JSONResponse(status_code=401, content={"error": "Invalid credentials"})
    
    user = users[user_id]
    if user.password != password:
        return JSONResponse(status_code=401, content={"error": "Invalid credentials"})
    
    session_id = secrets.token_hex(32)
    sessions[session_id] = user_id
    
    res = JSONResponse(status_code=200, content={"id": user.id, "username": user.username})
    res.set_cookie(
        key="session_id",
        value=session_id,
        httponly=True,
        path="/"
    )
    return res

@app.post("/logout")
async def logout(request: Request, user: User = Depends(get_current_user)) -> JSONResponse:
    session_id = request.cookies.get("session_id")
    if session_id in sessions:
        del sessions[session_id]
    res = JSONResponse(status_code=200, content={})
    res.delete_cookie(key="session_id", path="/")
    return res

@app.get("/me")
async def me(user: User = Depends(get_current_user)) -> JSONResponse:
    return JSONResponse(status_code=200, content={"id": user.id, "username": user.username})

@app.put("/password")
async def change_password(request: Request, user: User = Depends(get_current_user)) -> JSONResponse:
    data = await get_json(request)
    if not isinstance(data, dict):
        return JSONResponse(status_code=400, content={"error": "Invalid request"})
    
    old_password = data.get("old_password")
    new_password = data.get("new_password")
    
    if not isinstance(old_password, str) or not isinstance(new_password, str):
        return JSONResponse(status_code=400, content={"error": "Invalid request"})
        
    if user.password != old_password:
        return JSONResponse(status_code=401, content={"error": "Invalid credentials"})
    
    if len(new_password) < 8:
        return JSONResponse(status_code=400, content={"error": "Password too short"})
    
    user.password = new_password
    return JSONResponse(status_code=200, content={})

@app.get("/todos")
async def get_todos(user: User = Depends(get_current_user)) -> JSONResponse:
    user_todos = [t for t in todos.values() if t.user_id == user.id]
    user_todos.sort(key=lambda x: x.id)
    
    result = [{
        "id": t.id,
        "title": t.title,
        "description": t.description,
        "completed": t.completed,
        "created_at": t.created_at,
        "updated_at": t.updated_at
    } for t in user_todos]
    return JSONResponse(status_code=200, content=result)

@app.post("/todos")
async def create_todo(request: Request, user: User = Depends(get_current_user)) -> JSONResponse:
    data = await get_json(request)
    if not isinstance(data, dict):
        return JSONResponse(status_code=400, content={"error": "Invalid request"})
    
    title = data.get("title")
    description = data.get("description", "")
    
    if not isinstance(title, str) or not title.strip():
        return JSONResponse(status_code=400, content={"error": "Title is required"})
    
    if not isinstance(description, str):
        description = ""
    
    global next_todo_id
    todo_id = next_todo_id
    next_todo_id += 1
    
    now = get_utc_now_str()
    todo = Todo(
        id=todo_id,
        title=title,
        description=description,
        completed=False,
        created_at=now,
        updated_at=now,
        user_id=user.id
    )
    todos[todo_id] = todo
    
    return JSONResponse(
        status_code=201,
        content={
            "id": todo.id,
            "title": todo.title,
            "description": todo.description,
            "completed": todo.completed,
            "created_at": todo.created_at,
            "updated_at": todo.updated_at
        }
    )

@app.get("/todos/{todo_id}")
async def get_todo(todo_id: int, user: User = Depends(get_current_user)) -> JSONResponse:
    todo = todos.get(todo_id)
    if not todo or todo.user_id != user.id:
        return JSONResponse(status_code=404, content={"error": "Todo not found"})
    
    return JSONResponse(status_code=200, content={
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at
    })

@app.put("/todos/{todo_id}")
async def update_todo(todo_id: int, request: Request, user: User = Depends(get_current_user)) -> JSONResponse:
    data = await get_json(request)
    if not isinstance(data, dict):
        return JSONResponse(status_code=400, content={"error": "Invalid request"})
        
    todo = todos.get(todo_id)
    if not todo or todo.user_id != user.id:
        return JSONResponse(status_code=404, content={"error": "Todo not found"})
    
    title = data.get("title")
    if title is not None:
        if not isinstance(title, str) or not title.strip():
            return JSONResponse(status_code=400, content={"error": "Title is required"})
        todo.title = title
        
    description = data.get("description")
    if description is not None:
        if isinstance(description, str):
            todo.description = description
            
    completed = data.get("completed")
    if completed is not None:
        if isinstance(completed, bool):
            todo.completed = completed
            
    todo.updated_at = get_utc_now_str()
    
    return JSONResponse(status_code=200, content={
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at
    })

@app.delete("/todos/{todo_id}")
async def delete_todo(todo_id: int, user: User = Depends(get_current_user)) -> Response:
    todo = todos.get(todo_id)
    if not todo or todo.user_id != user.id:
        return JSONResponse(status_code=404, content={"error": "Todo not found"})
    
    del todos[todo_id]
    return Response(status_code=204)
