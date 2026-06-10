import argparse
import json
import re
import secrets
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# In-memory storage
users = {}  # id -> {"id": int, "username": str, "password": str}
usernames = {}  # username -> id
todos = {}  # id -> {"id": int, "user_id": int, "title": str, "description": str, "completed": bool, "created_at": str, "updated_at": str}
sessions = {}  # token -> user_id

USER_ID_COUNTER = 1
TODO_ID_COUNTER = 1

def get_utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

class TodoHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass  # Suppress logging

    def send_json(self, status_code, data, headers=None):
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        body = json.dumps(data).encode("utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_no_content(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def get_cookie(self, name):
        cookie_header = self.headers.get("Cookie", "")
        for cookie in cookie_header.split(";"):
            key, _, value = cookie.strip().partition("=")
            if key == name:
                return value
        return None

    def check_auth(self):
        token = self.get_cookie("session_id")
        if not token or token not in sessions:
            self.send_json(401, {"error": "Authentication required"})
            return None
        return sessions[token]

    def read_json_body(self):
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            return {}
        body = self.rfile.read(content_length)
        try:
            return json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            return None

    def do_POST(self):
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

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/me":
            self.handle_me()
        elif path == "/todos":
            self.handle_get_todos()
        elif path.startswith("/todos/"):
            todo_id_str = path[7:]
            if todo_id_str.isdigit():
                self.handle_get_todo(int(todo_id_str))
            else:
                self.send_json(404, {"error": "Todo not found"})
        else:
            self.send_json(404, {"error": "Not found"})

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/password":
            self.handle_change_password()
        elif path.startswith("/todos/"):
            todo_id_str = path[7:]
            if todo_id_str.isdigit():
                self.handle_update_todo(int(todo_id_str))
            else:
                self.send_json(404, {"error": "Todo not found"})
        else:
            self.send_json(404, {"error": "Not found"})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path.startswith("/todos/"):
            todo_id_str = path[7:]
            if todo_id_str.isdigit():
                self.handle_delete_todo(int(todo_id_str))
            else:
                self.send_json(404, {"error": "Todo not found"})
        else:
            self.send_json(404, {"error": "Not found"})

    def handle_register(self):
        global USER_ID_COUNTER
        data = self.read_json_body()
        if data is None:
            self.send_json(400, {"error": "Invalid JSON"})
            return
        
        username = data.get("username")
        password = data.get("password")

        if not isinstance(username, str) or not re.match(r"^[a-zA-Z0-9_]{3,50}$", username):
            self.send_json(400, {"error": "Invalid username"})
            return

        if not isinstance(password, str) or len(password) < 8:
            self.send_json(400, {"error": "Password too short"})
            return

        if username in usernames:
            self.send_json(409, {"error": "Username already exists"})
            return

        user_id = USER_ID_COUNTER
        USER_ID_COUNTER += 1
        
        users[user_id] = {
            "id": user_id,
            "username": username,
            "password": password
        }
        usernames[username] = user_id

        self.send_json(201, {"id": user_id, "username": username})

    def handle_login(self):
        data = self.read_json_body()
        if data is None:
            self.send_json(400, {"error": "Invalid JSON"})
            return

        username = data.get("username")
        password = data.get("password")

        user_id = usernames.get(username)
        if not user_id or users[user_id]["password"] != password:
            self.send_json(401, {"error": "Invalid credentials"})
            return

        token = secrets.token_hex(32)
        sessions[token] = user_id

        self.send_json(200, {"id": user_id, "username": username}, headers={"Set-Cookie": f"session_id={token}; Path=/; HttpOnly"})

    def handle_logout(self):
        user_id = self.check_auth()
        if user_id is None:
            return

        token = self.get_cookie("session_id")
        if token in sessions:
            del sessions[token]

        self.send_json(200, {})

    def handle_me(self):
        user_id = self.check_auth()
        if user_id is None:
            return

        user = users[user_id]
        self.send_json(200, {"id": user["id"], "username": user["username"]})

    def handle_change_password(self):
        user_id = self.check_auth()
        if user_id is None:
            return

        data = self.read_json_body()
        if data is None:
            self.send_json(400, {"error": "Invalid JSON"})
            return

        old_password = data.get("old_password")
        new_password = data.get("new_password")

        if users[user_id]["password"] != old_password:
            self.send_json(401, {"error": "Invalid credentials"})
            return

        if not isinstance(new_password, str) or len(new_password) < 8:
            self.send_json(400, {"error": "Password too short"})
            return

        users[user_id]["password"] = new_password
        self.send_json(200, {})

    def handle_create_todo(self):
        global TODO_ID_COUNTER
        user_id = self.check_auth()
        if user_id is None:
            return

        data = self.read_json_body()
        if data is None:
            self.send_json(400, {"error": "Invalid JSON"})
            return

        title = data.get("title")
        if not isinstance(title, str) or len(title) == 0:
            self.send_json(400, {"error": "Title is required"})
            return

        description = data.get("description", "")
        if not isinstance(description, str):
            description = ""

        todo_id = TODO_ID_COUNTER
        TODO_ID_COUNTER += 1

        now = get_utc_now()
        todo = {
            "id": todo_id,
            "title": title,
            "description": description,
            "completed": False,
            "created_at": now,
            "updated_at": now
        }
        todos[todo_id] = {**todo, "user_id": user_id}

        self.send_json(201, todo)

    def handle_get_todos(self):
        user_id = self.check_auth()
        if user_id is None:
            return

        user_todos = [
            {k: v for k, v in t.items() if k != "user_id"}
            for t in todos.values() if t["user_id"] == user_id
        ]
        user_todos.sort(key=lambda x: x["id"])
        self.send_json(200, user_todos)

    def handle_get_todo(self, todo_id):
        user_id = self.check_auth()
        if user_id is None:
            return

        todo = todos.get(todo_id)
        if not todo or todo["user_id"] != user_id:
            self.send_json(404, {"error": "Todo not found"})
            return

        self.send_json(200, {k: v for k, v in todo.items() if k != "user_id"})

    def handle_update_todo(self, todo_id):
        user_id = self.check_auth()
        if user_id is None:
            return

        todo = todos.get(todo_id)
        if not todo or todo["user_id"] != user_id:
            self.send_json(404, {"error": "Todo not found"})
            return

        data = self.read_json_body()
        if data is None:
            self.send_json(400, {"error": "Invalid JSON"})
            return

        if "title" in data:
            if not isinstance(data["title"], str) or len(data["title"]) == 0:
                self.send_json(400, {"error": "Title is required"})
                return
            todo["title"] = data["title"]

        if "description" in data:
            todo["description"] = data["description"] if isinstance(data["description"], str) else ""

        if "completed" in data:
            todo["completed"] = bool(data["completed"])

        todo["updated_at"] = get_utc_now()

        self.send_json(200, {k: v for k, v in todo.items() if k != "user_id"})

    def handle_delete_todo(self, todo_id):
        user_id = self.check_auth()
        if user_id is None:
            return

        todo = todos.get(todo_id)
        if not todo or todo["user_id"] != user_id:
            self.send_json(404, {"error": "Todo not found"})
            return

        del todos[todo_id]
        self.send_no_content()

def run_server(port):
    server = HTTPServer(("0.0.0.0", port), TodoHandler)
    print(f"Server running on 0.0.0.0:{port}")
    server.serve_forever()

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()
    run_server(args.port)