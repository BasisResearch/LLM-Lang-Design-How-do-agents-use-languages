import http.server
import json
import re
import uuid
import hashlib
import secrets
import argparse
import socketserver
from datetime import datetime, timezone
from typing import Dict, Optional, Any

class User:
    def __init__(self, id: int, username: str, password: str) -> None:
        self.id = id
        self.username = username
        self.password = password

class Todo:
    def __init__(self, id: int, user_id: int, title: str, description: str, completed: bool, created_at: str, updated_at: str) -> None:
        self.id = id
        self.user_id = user_id
        self.title = title
        self.description = description
        self.completed = completed
        self.created_at = created_at
        self.updated_at = updated_at

class AppState:
    def __init__(self) -> None:
        self.users: Dict[int, User] = {}
        self.usernames: Dict[str, int] = {}
        self.todos: Dict[int, Todo] = {}
        self.sessions: Dict[str, int] = {}
        self.user_id_counter: int = 1
        self.todo_id_counter: int = 1

app_state = AppState()

def get_utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    hashed = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), 100000)
    return f"{salt}:{hashed.hex()}"

def verify_password(password: str, hashed: str) -> bool:
    try:
        salt, hex_hash = hashed.split(':')
        new_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), 100000).hex()
        return secrets.compare_digest(new_hash, hex_hash)
    except ValueError:
        return False

class RequestHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: Any) -> None:
        pass

    def send_json_response(self, status_code: int, data: Any) -> None:
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        body = json.dumps(data).encode("utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_no_content(self) -> None:
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def get_session_user(self) -> Optional[User]:
        cookie_header = self.headers.get("Cookie", "")
        session_id: Optional[str] = None
        if isinstance(cookie_header, str):
            for cookie in cookie_header.split(";"):
                cookie = cookie.strip()
                if cookie.startswith("session_id="):
                    session_id = cookie[len("session_id="):]
                    break
        
        if session_id and session_id in app_state.sessions:
            user_id = app_state.sessions[session_id]
            return app_state.users.get(user_id)
        return None

    def read_json_body(self) -> Optional[Dict[str, Any]]:
        content_length_str = self.headers.get("Content-Length")
        if content_length_str is None:
            return {}
        try:
            length = int(content_length_str)
        except ValueError:
            return None
        
        if length == 0:
            return {}
            
        body = self.rfile.read(length)
        try:
            data = json.loads(body.decode("utf-8"))
            if isinstance(data, dict):
                return data
            return None
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    def get_path(self) -> str:
        return self.path.split("?")[0]

    def do_POST(self) -> None:
        path = self.get_path()
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
        path = self.get_path()
        if path == "/me":
            self.handle_me()
        elif path == "/todos":
            self.handle_get_todos()
        elif path.startswith("/todos/"):
            self.handle_get_todo(path[7:])
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_PUT(self) -> None:
        path = self.get_path()
        if path == "/password":
            self.handle_change_password()
        elif path.startswith("/todos/"):
            self.handle_update_todo(path[7:])
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_DELETE(self) -> None:
        path = self.get_path()
        if path.startswith("/todos/"):
            self.handle_delete_todo(path[7:])
        else:
            self.send_json_response(404, {"error": "Not found"})

    def handle_register(self) -> None:
        body = self.read_json_body()
        if body is None:
            self.send_json_response(400, {"error": "Invalid JSON"})
            return
        
        username = body.get("username")
        password = body.get("password")

        if not isinstance(username, str) or not re.match(r"^[a-zA-Z0-9_]{3,50}$", username):
            self.send_json_response(400, {"error": "Invalid username"})
            return
        
        if not isinstance(password, str) or len(password) < 8:
            self.send_json_response(400, {"error": "Password too short"})
            return
        
        if username in app_state.usernames:
            self.send_json_response(409, {"error": "Username already exists"})
            return
        
        new_user = User(app_state.user_id_counter, username, hash_password(password))
        app_state.users[app_state.user_id_counter] = new_user
        app_state.usernames[username] = app_state.user_id_counter
        app_state.user_id_counter += 1

        self.send_json_response(201, {"id": new_user.id, "username": new_user.username})

    def handle_login(self) -> None:
        body = self.read_json_body()
        if body is None:
            self.send_json_response(400, {"error": "Invalid JSON"})
            return
        
        username = body.get("username")
        password = body.get("password")

        if not isinstance(username, str) or not isinstance(password, str):
            self.send_json_response(401, {"error": "Invalid credentials"})
            return
        
        user_id = app_state.usernames.get(username)
        if user_id is None:
            self.send_json_response(401, {"error": "Invalid credentials"})
            return
        
        user = app_state.users.get(user_id)
        if user is None or not verify_password(password, user.password):
            self.send_json_response(401, {"error": "Invalid credentials"})
            return
        
        session_id = uuid.uuid4().hex
        app_state.sessions[session_id] = user.id
        
        body_bytes = json.dumps({"id": user.id, "username": user.username}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.send_header("Set-Cookie", f"session_id={session_id}; Path=/; HttpOnly")
        self.end_headers()
        self.wfile.write(body_bytes)

    def handle_logout(self) -> None:
        user = self.get_session_user()
        if user is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return
        
        cookie_header = self.headers.get("Cookie", "")
        if isinstance(cookie_header, str):
            for cookie in cookie_header.split(";"):
                cookie = cookie.strip()
                if cookie.startswith("session_id="):
                    session_id = cookie[len("session_id="):]
                    if session_id in app_state.sessions:
                        del app_state.sessions[session_id]
                    break
        
        self.send_json_response(200, {})

    def handle_me(self) -> None:
        user = self.get_session_user()
        if user is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return
        self.send_json_response(200, {"id": user.id, "username": user.username})

    def handle_change_password(self) -> None:
        user = self.get_session_user()
        if user is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return
        
        body = self.read_json_body()
        if body is None:
            self.send_json_response(400, {"error": "Invalid JSON"})
            return
        
        old_password = body.get("old_password")
        new_password = body.get("new_password")

        if not isinstance(old_password, str) or not verify_password(old_password, user.password):
            self.send_json_response(401, {"error": "Invalid credentials"})
            return
        
        if not isinstance(new_password, str) or len(new_password) < 8:
            self.send_json_response(400, {"error": "Password too short"})
            return
        
        user.password = hash_password(new_password)
        self.send_json_response(200, {})

    def handle_get_todos(self) -> None:
        user = self.get_session_user()
        if user is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return
        
        user_todos = [t for t in app_state.todos.values() if t.user_id == user.id]
        user_todos.sort(key=lambda t: t.id)
        
        result = [{
            "id": t.id,
            "title": t.title,
            "description": t.description,
            "completed": t.completed,
            "created_at": t.created_at,
            "updated_at": t.updated_at
        } for t in user_todos]
        
        self.send_json_response(200, result)

    def handle_create_todo(self) -> None:
        user = self.get_session_user()
        if user is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return
        
        body = self.read_json_body()
        if body is None:
            self.send_json_response(400, {"error": "Invalid JSON"})
            return
        
        title = body.get("title")
        if not isinstance(title, str) or len(title) == 0:
            self.send_json_response(400, {"error": "Title is required"})
            return
        
        description = body.get("description")
        if not isinstance(description, str):
            description = ""
        
        new_todo = Todo(app_state.todo_id_counter, user.id, title, description, False, get_utc_now(), get_utc_now())
        app_state.todos[app_state.todo_id_counter] = new_todo
        app_state.todo_id_counter += 1
        
        self.send_json_response(201, {
            "id": new_todo.id,
            "title": new_todo.title,
            "description": new_todo.description,
            "completed": new_todo.completed,
            "created_at": new_todo.created_at,
            "updated_at": new_todo.updated_at
        })

    def handle_get_todo(self, todo_id_str: str) -> None:
        user = self.get_session_user()
        if user is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return
        
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        todo = app_state.todos.get(todo_id)
        if todo is None or todo.user_id != user.id:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        self.send_json_response(200, {
            "id": todo.id,
            "title": todo.title,
            "description": todo.description,
            "completed": todo.completed,
            "created_at": todo.created_at,
            "updated_at": todo.updated_at
        })

    def handle_update_todo(self, todo_id_str: str) -> None:
        user = self.get_session_user()
        if user is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return
        
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        todo = app_state.todos.get(todo_id)
        if todo is None or todo.user_id != user.id:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        body = self.read_json_body()
        if body is None:
            self.send_json_response(400, {"error": "Invalid JSON"})
            return
        
        if "title" in body:
            title = body["title"]
            if not isinstance(title, str) or len(title) == 0:
                self.send_json_response(400, {"error": "Title is required"})
                return
            todo.title = title
            
        if "description" in body:
            desc = body["description"]
            if isinstance(desc, str):
                todo.description = desc
                
        if "completed" in body:
            comp = body["completed"]
            if isinstance(comp, bool):
                todo.completed = comp
                
        todo.updated_at = get_utc_now()
        
        self.send_json_response(200, {
            "id": todo.id,
            "title": todo.title,
            "description": todo.description,
            "completed": todo.completed,
            "created_at": todo.created_at,
            "updated_at": todo.updated_at
        })

    def handle_delete_todo(self, todo_id_str: str) -> None:
        user = self.get_session_user()
        if user is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return
        
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        todo = app_state.todos.get(todo_id)
        if todo is None or todo.user_id != user.id:
            self.send_json_response(404, {"error": "Todo not found"})
            return
        
        del app_state.todos[todo_id]
        self.send_no_content()

def main() -> None:
    parser = argparse.ArgumentParser(description="Todo API Server")
    parser.add_argument("--port", type=int, default=8000, help="Port to listen on")
    args = parser.parse_args()

    class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
        allow_reuse_address: bool = True

    server = ThreadedHTTPServer(("0.0.0.0", args.port), RequestHandler)
    print(f"Server running on http://0.0.0.0:{args.port}")
    server.serve_forever()

if __name__ == "__main__":
    main()
