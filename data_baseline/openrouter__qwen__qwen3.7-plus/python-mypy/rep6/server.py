import re
import uuid
import json
import argparse
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from datetime import datetime, timezone
from typing import Dict, Any, Optional

# In-memory storage
users: Dict[int, Dict[str, Any]] = {}
usernames: Dict[str, int] = {}
todos: Dict[int, Dict[str, Any]] = {}
sessions: Dict[str, int] = {}

next_user_id: int = 1
next_todo_id: int = 1

def get_utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

class TodoHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:
        pass

    def send_json(self, status_code: int, data: Any, include_content_type: bool = True) -> None:
        self.send_response(status_code)
        if include_content_type:
            self.send_header("Content-Type", "application/json")
        self.end_headers()
        if data is not None:
            self.wfile.write(json.dumps(data).encode("utf-8"))

    def get_session_user(self) -> Optional[Dict[str, Any]]:
        cookie_header = self.headers.get("Cookie", "")
        if not isinstance(cookie_header, str):
            cookie_header = ""
        session_id: Optional[str] = None
        for cookie in cookie_header.split(";"):
            cookie = cookie.strip()
            if cookie.startswith("session_id="):
                session_id = cookie[len("session_id="):]
                break
        
        if session_id and session_id in sessions:
            user_id = sessions[session_id]
            return users.get(user_id)
        return None

    def require_auth(self) -> Optional[Dict[str, Any]]:
        user = self.get_session_user()
        if not user:
            self.send_json(401, {"error": "Authentication required"})
            return None
        return user

    def read_json_body(self) -> Optional[Dict[str, Any]]:
        content_length = self.headers.get("Content-Length")
        if content_length is None:
            return {}
        try:
            length = int(content_length)
        except ValueError:
            return {}
        if length == 0:
            return {}
        body = self.rfile.read(length)
        try:
            data = json.loads(body.decode("utf-8"))
            if isinstance(data, dict):
                return data
            return {}
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/register":
            self.handle_register()
        elif path == "/login":
            self.handle_login()
        elif path == "/logout":
            self.handle_logout()
        elif path == "/todos":
            self.handle_create_todo()
        else:
            self.send_json(404, {"error": "Not found"})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/me":
            self.handle_me()
        elif path == "/todos":
            self.handle_get_todos()
        elif path.startswith("/todos/"):
            todo_id_str = path[len("/todos/"):]
            self.handle_get_todo(todo_id_str)
        else:
            self.send_json(404, {"error": "Not found"})

    def do_PUT(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/password":
            self.handle_change_password()
        elif path.startswith("/todos/"):
            todo_id_str = path[len("/todos/"):]
            self.handle_update_todo(todo_id_str)
        else:
            self.send_json(404, {"error": "Not found"})

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path

        if path.startswith("/todos/"):
            todo_id_str = path[len("/todos/"):]
            self.handle_delete_todo(todo_id_str)
        else:
            self.send_json(404, {"error": "Not found"})

    def handle_register(self) -> None:
        global next_user_id
        body = self.read_json_body()
        if body is None:
            self.send_json(400, {"error": "Invalid request"})
            return

        username = body.get("username")
        password = body.get("password")

        if not isinstance(username, str):
            self.send_json(400, {"error": "Invalid username"})
            return
        
        if not isinstance(password, str):
            self.send_json(400, {"error": "Password too short"})
            return

        if not re.match(r"^[a-zA-Z0-9_]{3,50}$", username):
            self.send_json(400, {"error": "Invalid username"})
            return

        if len(password) < 8:
            self.send_json(400, {"error": "Password too short"})
            return

        if username in usernames:
            self.send_json(409, {"error": "Username already exists"})
            return

        user_id = next_user_id
        next_user_id += 1

        users[user_id] = {
            "id": user_id,
            "username": username,
            "password": password
        }
        usernames[username] = user_id

        self.send_json(201, {"id": user_id, "username": username})

    def handle_login(self) -> None:
        body = self.read_json_body()
        if body is None:
            self.send_json(400, {"error": "Invalid request"})
            return

        username = body.get("username")
        password = body.get("password")

        if not isinstance(username, str) or not isinstance(password, str):
            self.send_json(401, {"error": "Invalid credentials"})
            return

        user_id = usernames.get(username)
        if not user_id:
            self.send_json(401, {"error": "Invalid credentials"})
            return

        user = users[user_id]
        if user["password"] != password:
            self.send_json(401, {"error": "Invalid credentials"})
            return

        session_id = uuid.uuid4().hex
        sessions[session_id] = user_id

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Set-Cookie", f"session_id={session_id}; Path=/; HttpOnly")
        self.end_headers()
        self.wfile.write(json.dumps({"id": user_id, "username": username}).encode("utf-8"))

    def handle_logout(self) -> None:
        user = self.require_auth()
        if not user:
            return

        cookie_header = self.headers.get("Cookie", "")
        if not isinstance(cookie_header, str):
            cookie_header = ""
        session_id: Optional[str] = None
        for cookie in cookie_header.split(";"):
            cookie = cookie.strip()
            if cookie.startswith("session_id="):
                session_id = cookie[len("session_id="):]
                break

        if session_id and session_id in sessions:
            del sessions[session_id]

        self.send_json(200, {})

    def handle_me(self) -> None:
        user = self.require_auth()
        if not user:
            return
        self.send_json(200, {"id": user["id"], "username": user["username"]})

    def handle_change_password(self) -> None:
        user = self.require_auth()
        if not user:
            return

        body = self.read_json_body()
        if body is None:
            self.send_json(400, {"error": "Invalid request"})
            return

        old_password = body.get("old_password")
        new_password = body.get("new_password")

        if not isinstance(old_password, str) or not isinstance(new_password, str):
            self.send_json(401, {"error": "Invalid credentials"})
            return

        if user["password"] != old_password:
            self.send_json(401, {"error": "Invalid credentials"})
            return

        if len(new_password) < 8:
            self.send_json(400, {"error": "Password too short"})
            return

        user["password"] = new_password
        self.send_json(200, {})

    def handle_get_todos(self) -> None:
        user = self.require_auth()
        if not user:
            return

        user_todos = [t for t in todos.values() if t["user_id"] == user["id"]]
        user_todos.sort(key=lambda x: x["id"])
        
        response_todos = [{k: v for k, v in t.items() if k != "user_id"} for t in user_todos]
        self.send_json(200, response_todos)

    def handle_create_todo(self) -> None:
        global next_todo_id
        user = self.require_auth()
        if not user:
            return

        body = self.read_json_body()
        if body is None:
            self.send_json(400, {"error": "Invalid request"})
            return

        title = body.get("title")
        if not isinstance(title, str) or not title:
            self.send_json(400, {"error": "Title is required"})
            return

        description = body.get("description", "")
        if not isinstance(description, str):
            description = ""

        now = get_utc_now()
        todo_id = next_todo_id
        next_todo_id += 1

        new_todo: Dict[str, Any] = {
            "id": todo_id,
            "user_id": user["id"],
            "title": title,
            "description": description,
            "completed": False,
            "created_at": now,
            "updated_at": now
        }
        todos[todo_id] = new_todo

        response_todo = {k: v for k, v in new_todo.items() if k != "user_id"}
        self.send_json(201, response_todo)

    def get_todo_for_user(self, todo_id_str: str, user: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            return None
        
        todo = todos.get(todo_id)
        if not todo or todo["user_id"] != user["id"]:
            return None
        return todo

    def handle_get_todo(self, todo_id_str: str) -> None:
        user = self.require_auth()
        if not user:
            return

        todo = self.get_todo_for_user(todo_id_str, user)
        if not todo:
            self.send_json(404, {"error": "Todo not found"})
            return

        response_todo = {k: v for k, v in todo.items() if k != "user_id"}
        self.send_json(200, response_todo)

    def handle_update_todo(self, todo_id_str: str) -> None:
        user = self.require_auth()
        if not user:
            return

        todo = self.get_todo_for_user(todo_id_str, user)
        if not todo:
            self.send_json(404, {"error": "Todo not found"})
            return

        body = self.read_json_body()
        if body is None:
            self.send_json(400, {"error": "Invalid request"})
            return

        if "title" in body:
            title = body["title"]
            if not isinstance(title, str) or not title:
                self.send_json(400, {"error": "Title is required"})
                return
            todo["title"] = title

        if "description" in body:
            desc = body["description"]
            todo["description"] = desc if isinstance(desc, str) else ""

        if "completed" in body:
            todo["completed"] = bool(body["completed"])

        todo["updated_at"] = get_utc_now()

        response_todo = {k: v for k, v in todo.items() if k != "user_id"}
        self.send_json(200, response_todo)

    def handle_delete_todo(self, todo_id_str: str) -> None:
        user = self.require_auth()
        if not user:
            return

        todo = self.get_todo_for_user(todo_id_str, user)
        if not todo:
            self.send_json(404, {"error": "Todo not found"})
            return

        del todos[todo["id"]]
        self.send_response(204)
        self.end_headers()

def run_server(port: int) -> None:
    server = HTTPServer(("0.0.0.0", port), TodoHandler)
    print(f"Server running on 0.0.0.0:{port}")
    server.serve_forever()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    run_server(args.port)
