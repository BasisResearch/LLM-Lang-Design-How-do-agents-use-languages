from typing import Dict, Optional, TypedDict, Any, List
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
import re
import uuid
from datetime import datetime, timezone

class UserType(TypedDict):
    id: int
    username: str
    password: str

class TodoType(TypedDict):
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str

app = FastAPI()

users: Dict[int, UserType] = {}
next_user_id: int = 1
username_to_id: Dict[str, int] = {}

todos: Dict[int, TodoType] = {}
next_todo_id: int = 1

sessions: Dict[str, int] = {}

def get_current_time() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def error_response(message: str, status_code: int) -> JSONResponse:
    return JSONResponse(status_code=status_code, content={"error": message})

def get_current_user(request: Request) -> Optional[UserType]:
    session_id = request.cookies.get("session_id")
    if session_id is None:
        return None
    user_id = sessions.get(session_id)
    if user_id is None:
        return None
    return users.get(user_id)

@app.post("/register", status_code=201)
async def register(payload: Dict[str, Any]) -> JSONResponse:
    global next_user_id
    username = payload.get("username")
    password = payload.get("password")
    
    if not isinstance(username, str) or not re.match(r"^[a-zA-Z0-9_]+$", username) or not (3 <= len(username) <= 50):
        return error_response("Invalid username", 400)
    
    if not isinstance(password, str) or len(password) < 8:
        return error_response("Password too short", 400)
        
    if username in username_to_id:
        return error_response("Username already exists", 409)
        
    user_id = next_user_id
    next_user_id += 1
    users[user_id] = {"id": user_id, "username": username, "password": password}
    username_to_id[username] = user_id
    
    return JSONResponse(status_code=201, content={"id": user_id, "username": username})

@app.post("/login", status_code=200)
async def login(payload: Dict[str, Any]) -> JSONResponse:
    username = payload.get("username")
    password = payload.get("password")
    
    if not isinstance(username, str) or not isinstance(password, str):
        return error_response("Invalid credentials", 401)
        
    user_id = username_to_id.get(username)
    if user_id is None:
        return error_response("Invalid credentials", 401)
        
    user = users[user_id]
    if user["password"] != password:
        return error_response("Invalid credentials", 401)
        
    token = uuid.uuid4().hex
    sessions[token] = user["id"]
    
    response = JSONResponse(status_code=200, content={"id": user["id"], "username": user["username"]})
    response.set_cookie(
        key="session_id",
        value=token,
        httponly=True,
        path="/",
        samesite="lax"
    )
    return response

@app.post("/logout", status_code=200)
async def logout(request: Request) -> JSONResponse:
    user = get_current_user(request)
    if user is None:
        return error_response("Authentication required", 401)
        
    session_id = request.cookies.get("session_id")
    if session_id is not None and session_id in sessions:
        del sessions[session_id]
        
    response = JSONResponse(status_code=200, content={})
    response.delete_cookie(key="session_id", path="/")
    return response

@app.get("/me", status_code=200)
async def get_me(request: Request) -> JSONResponse:
    user = get_current_user(request)
    if user is None:
        return error_response("Authentication required", 401)
    return JSONResponse(status_code=200, content={"id": user["id"], "username": user["username"]})

@app.put("/password", status_code=200)
async def change_password(payload: Dict[str, Any], request: Request) -> JSONResponse:
    user = get_current_user(request)
    if user is None:
        return error_response("Authentication required", 401)
        
    old_password = payload.get("old_password")
    new_password = payload.get("new_password")
    
    if not isinstance(old_password, str) or not isinstance(new_password, str):
        return error_response("Invalid credentials", 401)
        
    if user["password"] != old_password:
        return error_response("Invalid credentials", 401)
        
    if len(new_password) < 8:
        return error_response("Password too short", 400)
        
    user["password"] = new_password
    return JSONResponse(status_code=200, content={})

@app.get("/todos", status_code=200)
async def get_todos(request: Request) -> JSONResponse:
    user = get_current_user(request)
    if user is None:
        return error_response("Authentication required", 401)
        
    user_todos: List[Dict[str, Any]] = [
        {
            "id": t["id"],
            "title": t["title"],
            "description": t["description"],
            "completed": t["completed"],
            "created_at": t["created_at"],
            "updated_at": t["updated_at"]
        }
        for t in todos.values() if t["user_id"] == user["id"]
    ]
    user_todos.sort(key=lambda x: int(x["id"]))
    return JSONResponse(status_code=200, content=user_todos)

@app.post("/todos", status_code=201)
async def create_todo(payload: Dict[str, Any], request: Request) -> JSONResponse:
    global next_todo_id
    user = get_current_user(request)
    if user is None:
        return error_response("Authentication required", 401)
        
    title = payload.get("title")
    if not isinstance(title, str) or title == "":
        return error_response("Title is required", 400)
        
    description = payload.get("description", "")
    if not isinstance(description, str):
        description = ""
        
    now = get_current_time()
    todo_id = next_todo_id
    next_todo_id += 1
    
    new_todo: TodoType = {
        "id": todo_id,
        "user_id": user["id"],
        "title": title,
        "description": description,
        "completed": False,
        "created_at": now,
        "updated_at": now
    }
    todos[todo_id] = new_todo
    
    return JSONResponse(
        status_code=201, 
        content={
            "id": new_todo["id"],
            "title": new_todo["title"],
            "description": new_todo["description"],
            "completed": new_todo["completed"],
            "created_at": new_todo["created_at"],
            "updated_at": new_todo["updated_at"]
        }
    )

@app.get("/todos/{todo_id}", status_code=200)
async def get_todo(todo_id: int, request: Request) -> JSONResponse:
    user = get_current_user(request)
    if user is None:
        return error_response("Authentication required", 401)
        
    todo = todos.get(todo_id)
    if todo is None or todo["user_id"] != user["id"]:
        return error_response("Todo not found", 404)
        
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

@app.put("/todos/{todo_id}", status_code=200)
async def update_todo(todo_id: int, payload: Dict[str, Any], request: Request) -> JSONResponse:
    user = get_current_user(request)
    if user is None:
        return error_response("Authentication required", 401)
        
    todo = todos.get(todo_id)
    if todo is None or todo["user_id"] != user["id"]:
        return error_response("Todo not found", 404)
        
    if "title" in payload:
        title = payload["title"]
        if not isinstance(title, str) or title == "":
            return error_response("Title is required", 400)
        todo["title"] = title
        
    if "description" in payload:
        description = payload["description"]
        if isinstance(description, str):
            todo["description"] = description
            
    if "completed" in payload:
        completed = payload["completed"]
        if isinstance(completed, bool):
            todo["completed"] = completed
            
    todo["updated_at"] = get_current_time()
    todos[todo_id] = todo
    
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

@app.delete("/todos/{todo_id}", status_code=204)
async def delete_todo(todo_id: int, request: Request) -> Response:
    user = get_current_user(request)
    if user is None:
        return error_response("Authentication required", 401)
        
    todo = todos.get(todo_id)
    if todo is None or todo["user_id"] != user["id"]:
        return error_response("Todo not found", 404)
        
    del todos[todo_id]
    return Response(status_code=204, media_type="application/json")