import re
import uuid
import datetime
from typing import Dict, Optional, Any

from fastapi import FastAPI, Request
from fastapi.responses import Response, JSONResponse
from pydantic import BaseModel

app = FastAPI()

# In-memory storage
users: Dict[int, Dict[str, str]] = {}
usernames_to_id: Dict[str, int] = {}
todos: Dict[int, Dict[str, Any]] = {}
sessions: Dict[str, int] = {}

next_user_id: int = 1
next_todo_id: int = 1


def get_current_timestamp() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def get_user_id(request: Request) -> Optional[int]:
    session_id: Optional[str] = request.cookies.get("session_id")
    if not session_id or session_id not in sessions:
        return None
    return sessions[session_id]


class RegisterRequest(BaseModel):
    username: str
    password: str


class LoginRequest(BaseModel):
    username: str
    password: str


class PasswordChangeRequest(BaseModel):
    old_password: str
    new_password: str


class TodoCreateRequest(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None


class TodoUpdateRequest(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    completed: Optional[bool] = None


@app.post("/register")
async def register(req: RegisterRequest) -> Response:
    global next_user_id
    if not re.fullmatch(r"[a-zA-Z0-9_]+", req.username) or not (3 <= len(req.username) <= 50):
        return JSONResponse(status_code=400, content={"error": "Invalid username"})
    if len(req.password) < 8:
        return JSONResponse(status_code=400, content={"error": "Password too short"})
    if req.username in usernames_to_id:
        return JSONResponse(status_code=409, content={"error": "Username already exists"})
    
    user_id = next_user_id
    next_user_id += 1
    users[user_id] = {"username": req.username, "password": req.password}
    usernames_to_id[req.username] = user_id
    
    return JSONResponse(status_code=201, content={"id": user_id, "username": req.username})


@app.post("/login")
async def login(req: LoginRequest) -> Response:
    user_id = usernames_to_id.get(req.username)
    if not user_id or users[user_id]["password"] != req.password:
        return JSONResponse(status_code=401, content={"error": "Invalid credentials"})
    
    session_id = uuid.uuid4().hex
    sessions[session_id] = user_id
    
    response = JSONResponse(status_code=200, content={"id": user_id, "username": req.username})
    response.set_cookie(key="session_id", value=session_id, httponly=True, path="/")
    return response


@app.post("/logout")
async def logout(request: Request) -> Response:
    user_id = get_user_id(request)
    if user_id is None:
        return JSONResponse(status_code=401, content={"error": "Authentication required"})
    
    session_id = request.cookies.get("session_id")
    if session_id and session_id in sessions:
        del sessions[session_id]
    
    response = JSONResponse(status_code=200, content={})
    response.delete_cookie(key="session_id", path="/")
    return response


@app.get("/me")
async def get_me(request: Request) -> Response:
    user_id = get_user_id(request)
    if user_id is None:
        return JSONResponse(status_code=401, content={"error": "Authentication required"})
    
    user = users[user_id]
    return JSONResponse(status_code=200, content={"id": user_id, "username": user["username"]})


@app.put("/password")
async def change_password(request: Request, req: PasswordChangeRequest) -> Response:
    user_id = get_user_id(request)
    if user_id is None:
        return JSONResponse(status_code=401, content={"error": "Authentication required"})
    
    user = users[user_id]
    if user["password"] != req.old_password:
        return JSONResponse(status_code=401, content={"error": "Invalid credentials"})
    if len(req.new_password) < 8:
        return JSONResponse(status_code=400, content={"error": "Password too short"})
    
    user["password"] = req.new_password
    return JSONResponse(status_code=200, content={})


@app.get("/todos")
async def get_todos(request: Request) -> Response:
    user_id = get_user_id(request)
    if user_id is None:
        return JSONResponse(status_code=401, content={"error": "Authentication required"})
    
    user_todos = [todo for todo in todos.values() if todo["user_id"] == user_id]
    user_todos.sort(key=lambda x: x["id"])
    
    result = [
        {
            "id": t["id"],
            "title": t["title"],
            "description": t["description"],
            "completed": t["completed"],
            "created_at": t["created_at"],
            "updated_at": t["updated_at"]
        }
        for t in user_todos
    ]
    return JSONResponse(status_code=200, content=result)


@app.post("/todos")
async def create_todo(request: Request, req: TodoCreateRequest) -> Response:
    global next_todo_id
    user_id = get_user_id(request)
    if user_id is None:
        return JSONResponse(status_code=401, content={"error": "Authentication required"})
    
    if not req.title or not req.title.strip():
        return JSONResponse(status_code=400, content={"error": "Title is required"})
    
    now = get_current_timestamp()
    todo_id = next_todo_id
    next_todo_id += 1
    
    description = req.description if req.description is not None else ""
    
    todo: Dict[str, Any] = {
        "id": todo_id,
        "title": req.title,
        "description": description,
        "completed": False,
        "created_at": now,
        "updated_at": now,
        "user_id": user_id
    }
    todos[todo_id] = todo
    
    return JSONResponse(
        status_code=201,
        content={
            "id": todo["id"],
            "title": todo["title"],
            "description": todo["description"],
            "completed": todo["completed"],
            "created_at": todo["created_at"],
            "updated_at": todo["updated_at"]
        }
    )


@app.get("/todos/{todo_id}")
async def get_todo(request: Request, todo_id: int) -> Response:
    user_id = get_user_id(request)
    if user_id is None:
        return JSONResponse(status_code=401, content={"error": "Authentication required"})
    
    todo = todos.get(todo_id)
    if not todo or todo["user_id"] != user_id:
        return JSONResponse(status_code=404, content={"error": "Todo not found"})
    
    return JSONResponse(
        status_code=200,
        content={
            "id": todo["id"],
            "title": todo["title"],
            "description": todo["description"],
            "completed": todo["completed"],
            "created_at": todo["created_at"],
            "updated_at": todo["updated_at"]
        }
    )


@app.put("/todos/{todo_id}")
async def update_todo(request: Request, todo_id: int, req: TodoUpdateRequest) -> Response:
    user_id = get_user_id(request)
    if user_id is None:
        return JSONResponse(status_code=401, content={"error": "Authentication required"})
    
    todo = todos.get(todo_id)
    if not todo or todo["user_id"] != user_id:
        return JSONResponse(status_code=404, content={"error": "Todo not found"})
    
    if req.title is not None and not req.title.strip():
        return JSONResponse(status_code=400, content={"error": "Title is required"})
    
    if req.title is not None:
        todo["title"] = req.title
    if req.description is not None:
        todo["description"] = req.description
    if req.completed is not None:
        todo["completed"] = req.completed
        
    todo["updated_at"] = get_current_timestamp()
    
    return JSONResponse(
        status_code=200,
        content={
            "id": todo["id"],
            "title": todo["title"],
            "description": todo["description"],
            "completed": todo["completed"],
            "created_at": todo["created_at"],
            "updated_at": todo["updated_at"]
        }
    )


@app.delete("/todos/{todo_id}")
async def delete_todo(request: Request, todo_id: int) -> Response:
    user_id = get_user_id(request)
    if user_id is None:
        return Response(status_code=401, content='{"error": "Authentication required"}')
    
    todo = todos.get(todo_id)
    if not todo or todo["user_id"] != user_id:
        return Response(status_code=404, content='{"error": "Todo not found"}')
    
    del todos[todo_id]
    return Response(status_code=204)
