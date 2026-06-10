from typing import Any, Dict, List, Optional
import argparse
import re
import uuid
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.responses import JSONResponse, Response
from fastapi.exceptions import RequestValidationError
from pydantic import BaseModel
import uvicorn

class CustomHTTPException(HTTPException):
    def __init__(self, status_code: int, error: str, headers: Optional[Dict[str, str]] = None) -> None:
        super().__init__(status_code=status_code, detail=error, headers=headers)

class User:
    def __init__(self, user_id: int, username: str, password: str) -> None:
        self.id: int = user_id
        self.username: str = username
        self.password: str = password

    def to_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "username": self.username}

class Todo:
    def __init__(self, todo_id: int, user_id: int, title: str, description: str) -> None:
        self.id: int = todo_id
        self.user_id: int = user_id
        self.title: str = title
        self.description: str = description
        self.completed: bool = False
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.created_at: str = now
        self.updated_at: str = now

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
            "completed": self.completed,
            "created_at": self.created_at,
            "updated_at": self.updated_at
        }

class AppState:
    def __init__(self) -> None:
        self.users: Dict[int, User] = {}
        self.username_to_user: Dict[str, User] = {}
        self.sessions: Dict[str, int] = {}
        self.todos: Dict[int, Todo] = {}
        self.user_id_counter: int = 0
        self.todo_id_counter: int = 0

state = AppState()

app = FastAPI()

@app.exception_handler(CustomHTTPException)
def custom_exception_handler(request: Request, exc: CustomHTTPException) -> JSONResponse:
    headers = dict(exc.headers) if exc.headers else {}
    headers["Content-Type"] = "application/json"
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.detail},
        headers=headers
    )

@app.exception_handler(RequestValidationError)
def validation_exception_handler(request: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=400,
        content={"error": "Invalid request"},
        headers={"Content-Type": "application/json"}
    )

@app.exception_handler(Exception)
def general_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error"},
        headers={"Content-Type": "application/json"}
    )

def get_session_id(request: Request) -> str:
    session_id = request.cookies.get("session_id")
    if not session_id or session_id not in state.sessions:
        raise CustomHTTPException(status_code=401, error="Authentication required")
    return session_id

def get_current_user(session_id: str = Depends(get_session_id)) -> User:
    user_id = state.sessions[session_id]
    user = state.users.get(user_id)
    if not user:
        raise CustomHTTPException(status_code=401, error="Authentication required")
    return user

class RegisterRequest(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None

class LoginRequest(BaseModel):
    username: Optional[str] = None
    password: Optional[str] = None

class ChangePasswordRequest(BaseModel):
    old_password: Optional[str] = None
    new_password: Optional[str] = None

class CreateTodoRequest(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None

class UpdateTodoRequest(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    completed: Optional[bool] = None

@app.post("/register", status_code=201)
def register(req: RegisterRequest) -> Dict[str, Any]:
    if not isinstance(req.username, str) or not isinstance(req.password, str):
        raise CustomHTTPException(status_code=400, error="Invalid request")
    if not (3 <= len(req.username) <= 50) or not re.match(r'^[a-zA-Z0-9_]+$', req.username):
        raise CustomHTTPException(status_code=400, error="Invalid username")
    if len(req.password) < 8:
        raise CustomHTTPException(status_code=400, error="Password too short")
    if req.username in state.username_to_user:
        raise CustomHTTPException(status_code=409, error="Username already exists")
    
    state.user_id_counter += 1
    new_user = User(state.user_id_counter, req.username, req.password)
    state.users[state.user_id_counter] = new_user
    state.username_to_user[req.username] = new_user
    return {"id": new_user.id, "username": new_user.username}

@app.post("/login")
def login(req: LoginRequest, response: Response) -> Dict[str, Any]:
    if not isinstance(req.username, str) or not isinstance(req.password, str):
        raise CustomHTTPException(status_code=401, error="Invalid credentials")
    user = state.username_to_user.get(req.username)
    if not user or user.password != req.password:
        raise CustomHTTPException(status_code=401, error="Invalid credentials")
    
    token = uuid.uuid4().hex
    state.sessions[token] = user.id
    response.set_cookie(key="session_id", value=token, path="/", httponly=True)
    return {"id": user.id, "username": user.username}

@app.post("/logout")
def logout(response: Response, session_id: str = Depends(get_session_id)) -> Dict[str, Any]:
    del state.sessions[session_id]
    response.delete_cookie(key="session_id", path="/")
    return {}

@app.get("/me")
def me(user: User = Depends(get_current_user)) -> Dict[str, Any]:
    return user.to_dict()

@app.put("/password")
def change_password(req: ChangePasswordRequest, user: User = Depends(get_current_user)) -> Dict[str, Any]:
    if not isinstance(req.old_password, str) or not isinstance(req.new_password, str):
        raise CustomHTTPException(status_code=400, error="Invalid request")
    if user.password != req.old_password:
        raise CustomHTTPException(status_code=401, error="Invalid credentials")
    if len(req.new_password) < 8:
        raise CustomHTTPException(status_code=400, error="Password too short")
    
    user.password = req.new_password
    return {}

@app.get("/todos")
def get_todos(user: User = Depends(get_current_user)) -> List[Dict[str, Any]]:
    user_todos = [todo for todo in state.todos.values() if todo.user_id == user.id]
    user_todos.sort(key=lambda t: t.id)
    return [todo.to_dict() for todo in user_todos]

@app.post("/todos", status_code=201)
def create_todo(req: CreateTodoRequest, user: User = Depends(get_current_user)) -> Dict[str, Any]:
    if not isinstance(req.title, str) or not req.title:
        raise CustomHTTPException(status_code=400, error="Title is required")
    
    desc = req.description if isinstance(req.description, str) else ""
    state.todo_id_counter += 1
    new_todo = Todo(state.todo_id_counter, user.id, req.title, desc)
    state.todos[state.todo_id_counter] = new_todo
    return new_todo.to_dict()

@app.get("/todos/{todo_id}")
def get_todo(todo_id: int, user: User = Depends(get_current_user)) -> Dict[str, Any]:
    todo = state.todos.get(todo_id)
    if not todo or todo.user_id != user.id:
        raise CustomHTTPException(status_code=404, error="Todo not found")
    return todo.to_dict()

@app.put("/todos/{todo_id}")
def update_todo(todo_id: int, req: UpdateTodoRequest, user: User = Depends(get_current_user)) -> Dict[str, Any]:
    todo = state.todos.get(todo_id)
    if not todo or todo.user_id != user.id:
        raise CustomHTTPException(status_code=404, error="Todo not found")
    
    if req.title is not None:
        if not isinstance(req.title, str) or not req.title:
            raise CustomHTTPException(status_code=400, error="Title is required")
        todo.title = req.title
        
    if req.description is not None:
        if not isinstance(req.description, str):
            raise CustomHTTPException(status_code=400, error="Invalid request")
        todo.description = req.description
        
    if req.completed is not None:
        if not isinstance(req.completed, bool):
            raise CustomHTTPException(status_code=400, error="Invalid request")
        todo.completed = req.completed
        
    todo.updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return todo.to_dict()

@app.delete("/todos/{todo_id}", status_code=204)
def delete_todo(todo_id: int, user: User = Depends(get_current_user)) -> Response:
    todo = state.todos.get(todo_id)
    if not todo or todo.user_id != user.id:
        raise CustomHTTPException(status_code=404, error="Todo not found")
    
    del state.todos[todo_id]
    return Response(status_code=204)

def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, default=8000, help="Port to run the server on")
    args = parser.parse_args()
    uvicorn.run(app, host="0.0.0.0", port=args.port)

if __name__ == "__main__":
    main()
