from __future__ import annotations

import argparse
import json
import re
import uuid
from datetime import datetime, timezone
from typing import Optional, Dict, Any, List
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

class User:
    def __init__(self, user_id: int, username: str, password: str) -> None:
        self.id: int = user_id
        self.username: str = username
        self.password: str = password

class Todo:
    def __init__(self, todo_id: int, user_id: int, title: str, description: str, completed: bool, created_at: str, updated_at: str) -> None:
        self.id: int = todo_id
        self.user_id: int = user_id
        self.title: str = title
        self.description: str = description
        self.completed: bool = completed
        self.created_at: str = created_at
        self.updated_at: str = updated_at

class Store:
    def __init__(self) -> None:
        self.users: Dict[int, User] = {}
        self.next_user_id: int = 1
        self.todos: Dict[int, Todo] = {}
        self.next_todo_id: int = 1
        self.sessions: Dict[str, int] = {}

    def create_user(self, username: str, password: str) -> User:
        user = User(user_id=self.next_user_id, username=username, password=password)
        self.users[self.next_user_id] = user
        self.next_user_id += 1
        return user

    def get_user_by_username(self, username: str) -> Optional[User]:
        for user in self.users.values():
            if user.username == username:
                return user
        return None

    def create_session(self, user_id: int) -> str:
        session_id: str = uuid.uuid4().hex
        self.sessions[session_id] = user_id
        return session_id

    def invalidate_session(self, session_id: str) -> None:
        if session_id in self.sessions:
            del self.sessions[session_id]

    def get_user_by_session(self, session_id: str) -> Optional[User]:
        user_id: Optional[int] = self.sessions.get(session_id)
        if user_id is not None:
            return self.users.get(user_id)
        return None

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        now: str = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        todo = Todo(
            todo_id=self.next_todo_id,
            user_id=user_id,
            title=title,
            description=description,
            completed=False,
            created_at=now,
            updated_at=now
        )
        self.todos[self.next_todo_id] = todo
        self.next_todo_id += 1
        return todo

    def get_todo_by_id(self, todo_id: int) -> Optional[Todo]:
        return self.todos.get(todo_id)

    def get_todos_by_user(self, user_id: int) -> List[Todo]:
        return sorted([todo for todo in self.todos.values() if todo.user_id == user_id], key=lambda t: t.id)

store: Store = Store()
username_pattern: re.Pattern[str] = re.compile(r"^[a-zA-Z0-9_]+$")

class RequestHandler(BaseHTTPRequestHandler):
    protocol_version: str = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:
        pass

    def send_json_response(self, status_code: int, data: Any) -> None:
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        body: bytes = json.dumps(data).encode("utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_no_content_response(self) -> None:
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def get_session_user(self) -> Optional[User]:
        cookie_header: str = self.headers.get("Cookie", "")
        session_id: Optional[str] = None
        for part in cookie_header.split(";"):
            part = part.strip()
            if part.startswith("session_id="):
                session_id = part[len("session_id="):]
                break
        
        if session_id:
            return store.get_user_by_session(session_id)
        return None

    def require_auth(self) -> Optional[User]:
        user: Optional[User] = self.get_session_user()
        if user is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return None
        return user

    def read_json_body(self) -> Optional[Dict[str, Any]]:
        content_length_str: str = self.headers.get("Content-Length", "0")
        try:
            content_length: int = int(content_length_str)
        except ValueError:
            return None
        if content_length == 0:
            return None
        body: bytes = self.rfile.read(content_length)
        try:
            parsed: Any = json.loads(body.decode("utf-8"))
            if isinstance(parsed, dict):
                return parsed
            return None
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path: str = parsed.path

        if path == "/register":
            self.handle_register()
        elif path == "/login":
            self.handle_login()
        elif path == "/logout":
            self.handle_logout()
        elif path == "/todos":
            self.handle_create_todo()
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path: str = parsed.path

        if path == "/me":
            self.handle_me()
        elif path == "/todos":
            self.handle_get_todos()
        elif path.startswith("/todos/"):
            todo_id_str: str = path[7:]
            self.handle_get_todo(todo_id_str)
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_PUT(self) -> None:
        parsed = urlparse(self.path)
        path: str = parsed.path

        if path == "/password":
            self.handle_update_password()
        elif path.startswith("/todos/"):
            todo_id_str: str = path[7:]
            self.handle_update_todo(todo_id_str)
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        path: str = parsed.path

        if path.startswith("/todos/"):
            todo_id_str: str = path[7:]
            self.handle_delete_todo(todo_id_str)
        else:
            self.send_json_response(404, {"error": "Not found"})

    def handle_register(self) -> None:
        body: Optional[Dict[str, Any]] = self.read_json_body()
        if body is None:
            self.send_json_response(400, {"error": "Invalid request body"})
            return
        
        username: Any = body.get("username")
        password: Any = body.get("password")
        
        if not isinstance(username, str) or not (3 <= len(username) <= 50) or not username_pattern.match(username):
            self.send_json_response(400, {"error": "Invalid username"})
            return
        
        if not isinstance(password, str) or len(password) < 8:
            self.send_json_response(400, {"error": "Password too short"})
            return
        
        if store.get_user_by_username(username) is not None:
            self.send_json_response(409, {"error": "Username already exists"})
            return
        
        user: User = store.create_user(username, password)
        self.send_json_response(201, {"id": user.id, "username": user.username})

    def handle_login(self) -> None:
        body: Optional[Dict[str, Any]] = self.read_json_body()
        if body is None:
            self.send_json_response(400, {"error": "Invalid request body"})
            return
        
        username: Any = body.get("username")
        password: Any = body.get("password")
        
        if not isinstance(username, str) or not isinstance(password, str):
            self.send_json_response(401, {"error": "Invalid credentials"})
            return
        
        user: Optional[User] = store.get_user_by_username(username)
        if user is None or user.password != password:
            self.send_json_response(401, {"error": "Invalid credentials"})
            return
        
        session_token: str = store.create_session(user.id)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", f"session_id={session_token}; Path=/; HttpOnly")
        body_bytes: bytes = json.dumps({"id": user.id, "username": user.username}).encode("utf-8")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def handle_logout(self) -> None:
        user: Optional[User] = self.require_auth()
        if user is None:
            return
        
        cookie_header: str = self.headers.get("Cookie", "")
        session_id: Optional[str] = None
        for part in cookie_header.split(";"):
            part = part.strip()
            if part.startswith("session_id="):
                session_id = part[len("session_id="):]
                break
        
        if session_id:
            store.invalidate_session(session_id)
        
        self.send_json_response(200, {})

    def handle_me(self) -> None:
        user: Optional[User] = self.require_auth()
        if user is None:
            return
        self.send_json_response(200, {"id": user.id, "username": user.username})

    def handle_update_password(self) -> None:
        user: Optional[User] = self.require_auth()
        if user is None:
            return
        
        body: Optional[Dict[str, Any]] = self.read_json_body()
        if body is None:
            self.send_json_response(400, {"error": "Invalid request body"})
            return
        
        old_password: Any = body.get("old_password")
        new_password: Any = body.get("new_password")
        
        if not isinstance(old_password, str) or not isinstance(new_password, str):
            self.send_json_response(401, {"error": "Invalid credentials"})
            return
        
        if old_password != user.password:
            self.send_json_response(401, {"error": "Invalid credentials"})
            return
        
        if len(new_password) < 8:
            self.send_json_response(400, {"error": "Password too short"})
            return
        
        user.password = new_password
        self.send_json_response(200, {})

    def handle_get_todos(self) -> None:
        user: Optional[User] = self.require_auth()
        if user is None:
            return
        
        todos: List[Todo] = store.get_todos_by_user(user.id)
        result: List[Dict[str, Any]] = [
            {
                "id": t.id,
                "title": t.title,
                "description": t.description,
                "completed": t.completed,
                "created_at": t.created_at,
                "updated_at": t.updated_at
            }
            for t in todos
        ]
        self.send_json_response(200, result)

    def handle_create_todo(self) -> None:
        user: Optional[User] = self.require_auth()
        if user is None:
            return
        
        body: Optional[Dict[str, Any]] = self.read_json_body()
        if body is None:
            self.send_json_response(400, {"error": "Invalid request body"})
            return
        
        title: Any = body.get("title")
        if not isinstance(title, str) or len(title) == 0:
            self.send_json_response(400, {"error": "Title is required"})
            return
        
        description: Any = body.get("description", "")
        if not isinstance(description, str):
            description = ""
        
        todo: Todo = store.create_todo(user.id, title, description)
        result: Dict[str, Any] = {
            "id": todo.id,
            "title": todo.title,
            "description": todo.description,
            "completed": todo.completed,
            "created_at": todo.created_at,
            "updated_at": todo.updated_at
        }
        self.send_json_response(201, result)

    def handle_get_todo(self, todo_id_str: str) -> None:
        user: Optional[User] = self.require_auth()
        if user is None:
            return
        
        try:
            todo_id: int = int(todo_id_str)
        except ValueError:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        todo: Optional[Todo] = store.get_todo_by_id(todo_id)
        if todo is None or todo.user_id != user.id:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        result: Dict[str, Any] = {
            "id": todo.id,
            "title": todo.title,
            "description": todo.description,
            "completed": todo.completed,
            "created_at": todo.created_at,
            "updated_at": todo.updated_at
        }
        self.send_json_response(200, result)

    def handle_update_todo(self, todo_id_str: str) -> None:
        user: Optional[User] = self.require_auth()
        if user is None:
            return
        
        try:
            todo_id: int = int(todo_id_str)
        except ValueError:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        todo: Optional[Todo] = store.get_todo_by_id(todo_id)
        if todo is None or todo.user_id != user.id:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        body: Optional[Dict[str, Any]] = self.read_json_body()
        if body is not None and not isinstance(body, dict):
            self.send_json_response(400, {"error": "Invalid request body"})
            return
        
        if body is None:
            body = {}
        
        if "title" in body:
            title: Any = body["title"]
            if not isinstance(title, str) or len(title) == 0:
                self.send_json_response(400, {"error": "Title is required"})
                return
            todo.title = title
        
        if "description" in body:
            description: Any = body["description"]
            if isinstance(description, str):
                todo.description = description
        
        if "completed" in body:
            completed: Any = body["completed"]
            if isinstance(completed, bool):
                todo.completed = completed
        
        todo.updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        
        result: Dict[str, Any] = {
            "id": todo.id,
            "title": todo.title,
            "description": todo.description,
            "completed": todo.completed,
            "created_at": todo.created_at,
            "updated_at": todo.updated_at
        }
        self.send_json_response(200, result)

    def handle_delete_todo(self, todo_id_str: str) -> None:
        user: Optional[User] = self.require_auth()
        if user is None:
            return
        
        try:
            todo_id: int = int(todo_id_str)
        except ValueError:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        todo: Optional[Todo] = store.get_todo_by_id(todo_id)
        if todo is None or todo.user_id != user.id:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        del store.todos[todo_id]
        self.send_no_content_response()

def run_server(port: int) -> None:
    server: HTTPServer = HTTPServer(("0.0.0.0", port), RequestHandler)
    print(f"Server running on 0.0.0.0:{port}")
    server.serve_forever()

if __name__ == "__main__":
    parser: argparse.ArgumentParser = argparse.ArgumentParser(description="Todo App REST API")
    parser.add_argument("--port", type=int, default=8080, help="Port to run the server on")
    args: argparse.Namespace = parser.parse_args()
    run_server(args.port)
