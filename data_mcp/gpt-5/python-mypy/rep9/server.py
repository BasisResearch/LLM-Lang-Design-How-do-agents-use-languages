from __future__ import annotations

import argparse
import hashlib
import http.cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Mapping, MutableMapping, Optional, Tuple
from urllib.parse import urlparse

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def iso_utc_now() -> str:
    now = datetime.now(timezone.utc)
    # Truncate to seconds
    now = now.replace(microsecond=0)
    return now.strftime("%Y-%m-%dT%H:%M:%SZ")


def generate_token() -> str:
    return uuid.uuid4().hex


def pbkdf2_hash(password: str, salt: bytes) -> bytes:
    # Use PBKDF2-HMAC-SHA256 with a reasonable iteration count
    return hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 200_000)


@dataclass
class UserRecord:
    id: int
    username: str
    password_salt: bytes
    password_hash: bytes

    def to_public_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "username": self.username}


@dataclass
class TodoRecord:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str

    def to_public_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
            "completed": self.completed,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


class InMemoryDB:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._next_user_id: int = 1
        self._next_todo_id: int = 1
        self._users_by_id: Dict[int, UserRecord] = {}
        self._users_by_username: Dict[str, UserRecord] = {}
        self._sessions: Dict[str, int] = {}
        self._todos_by_id: Dict[int, TodoRecord] = {}

    # User operations
    def create_user(self, username: str, password: str) -> UserRecord:
        with self._lock:
            if username in self._users_by_username:
                raise ValueError("Username already exists")
            uid = self._next_user_id
            self._next_user_id += 1
            salt = uuid.uuid4().bytes
            password_hash = pbkdf2_hash(password, salt)
            user = UserRecord(id=uid, username=username, password_salt=salt, password_hash=password_hash)
            self._users_by_id[uid] = user
            self._users_by_username[username] = user
            return user

    def get_user_by_username(self, username: str) -> Optional[UserRecord]:
        with self._lock:
            return self._users_by_username.get(username)

    def get_user_by_id(self, user_id: int) -> Optional[UserRecord]:
        with self._lock:
            return self._users_by_id.get(user_id)

    def set_user_password(self, user_id: int, new_password: str) -> None:
        with self._lock:
            user = self._users_by_id[user_id]
            user.password_salt = uuid.uuid4().bytes
            user.password_hash = pbkdf2_hash(new_password, user.password_salt)

    # Session operations
    def create_session(self, user_id: int) -> str:
        token = generate_token()
        with self._lock:
            self._sessions[token] = user_id
        return token

    def get_user_id_for_session(self, token: str) -> Optional[int]:
        with self._lock:
            return self._sessions.get(token)

    def invalidate_session(self, token: str) -> None:
        with self._lock:
            if token in self._sessions:
                del self._sessions[token]

    # Todo operations
    def create_todo(self, user_id: int, title: str, description: str) -> TodoRecord:
        with self._lock:
            tid = self._next_todo_id
            self._next_todo_id += 1
            ts = iso_utc_now()
            todo = TodoRecord(
                id=tid,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=ts,
                updated_at=ts,
            )
            self._todos_by_id[tid] = todo
            return todo

    def list_todos_for_user(self, user_id: int) -> List[TodoRecord]:
        with self._lock:
            todos = [t for t in self._todos_by_id.values() if t.user_id == user_id]
            todos.sort(key=lambda t: t.id)
            return list(todos)

    def get_todo(self, todo_id: int) -> Optional[TodoRecord]:
        with self._lock:
            return self._todos_by_id.get(todo_id)

    def update_todo(self, todo_id: int, *, title: Optional[str] = None, description: Optional[str] = None, completed: Optional[bool] = None) -> Optional[TodoRecord]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None:
                return None
            changed = False
            if title is not None:
                todo.title = title
                changed = True
            if description is not None:
                todo.description = description
                changed = True
            if completed is not None:
                todo.completed = completed
                changed = True
            if changed:
                todo.updated_at = iso_utc_now()
            return todo

    def delete_todo(self, todo_id: int) -> bool:
        with self._lock:
            if todo_id in self._todos_by_id:
                del self._todos_by_id[todo_id]
                return True
            return False


DB = InMemoryDB()


class TodoRequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    # Utilities
    def _parse_json_body(self) -> Optional[Dict[str, Any]]:
        length_str = self.headers.get("Content-Length")
        if length_str is None:
            body = b""
        else:
            try:
                length = int(length_str)
            except ValueError:
                self._send_json(400, {"error": "Invalid Content-Length"})
                return None
            body = self.rfile.read(length)
        if not body:
            return {}
        try:
            data = json.loads(body.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json(400, {"error": "Invalid JSON"})
            return None
        if not isinstance(data, dict):
            self._send_json(400, {"error": "Invalid JSON"})
            return None
        return data

    def _get_cookie(self, name: str) -> Optional[str]:
        raw = self.headers.get("Cookie")
        if raw is None:
            return None
        c = http.cookies.SimpleCookie()
        try:
            c.load(raw)
        except (http.cookies.CookieError, KeyError):
            return None
        morsel = c.get(name)
        if morsel is None:
            return None
        value = morsel.value
        return value

    def _authenticate(self) -> Tuple[Optional[UserRecord], Optional[str]]:
        token = self._get_cookie("session_id")
        if token is None:
            return (None, None)
        user_id = DB.get_user_id_for_session(token)
        if user_id is None:
            return (None, token)
        user = DB.get_user_by_id(user_id)
        if user is None:
            return (None, token)
        return (user, token)

    def _send_json(self, status_code: int, data: Mapping[str, Any] | List[Any], set_cookie: Optional[str] = None, clear_cookie: bool = False) -> None:
        body = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if set_cookie is not None:
            sc = http.cookies.SimpleCookie()
            sc["session_id"] = set_cookie
            sc["session_id"]["path"] = "/"
            sc["session_id"]["httponly"] = "True"
            # SimpleCookie renders to multiple Set-Cookie lines if multiple cookies; here we have one
            for morsel in sc.values():
                self.send_header("Set-Cookie", morsel.OutputString())
        if clear_cookie:
            sc2 = http.cookies.SimpleCookie()
            sc2["session_id"] = ""
            sc2["session_id"]["path"] = "/"
            sc2["session_id"]["httponly"] = "True"
            sc2["session_id"]["max-age"] = "0"
            for morsel in sc2.values():
                self.send_header("Set-Cookie", morsel.OutputString())
        self.end_headers()
        self.wfile.write(body)

    def _send_no_content(self, status_code: int = 204) -> None:
        self.send_response(status_code)
        # No Content-Type and no body per spec for DELETE 204
        self.send_header("Content-Length", "0")
        self.end_headers()

    # HTTP methods
    def do_POST(self) -> None:  # noqa: N802 (name style)
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/register":
            self._handle_register()
            return
        if path == "/login":
            self._handle_login()
            return
        if path == "/logout":
            self._handle_logout()
            return
        if path == "/todos":
            self._handle_todos_create()
            return
        self._send_json(404, {"error": "Not found"})

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/me":
            self._handle_me()
            return
        if path == "/todos":
            self._handle_todos_list()
            return
        if path.startswith("/todos/"):
            self._handle_todos_get(path)
            return
        self._send_json(404, {"error": "Not found"})

    def do_PUT(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/password":
            self._handle_password_change()
            return
        if path.startswith("/todos/"):
            self._handle_todos_update(path)
            return
        self._send_json(404, {"error": "Not found"})

    def do_DELETE(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/todos/"):
            self._handle_todos_delete(path)
            return
        self._send_json(404, {"error": "Not found"})

    # Handlers
    def _handle_register(self) -> None:
        data = self._parse_json_body()
        if data is None:
            return
        username_val = data.get("username")
        password_val = data.get("password")
        if not isinstance(username_val, str) or not USERNAME_RE.fullmatch(username_val):
            self._send_json(400, {"error": "Invalid username"})
            return
        if not isinstance(password_val, str) or len(password_val) < 8:
            self._send_json(400, {"error": "Password too short"})
            return
        try:
            user = DB.create_user(username_val, password_val)
        except ValueError:
            self._send_json(409, {"error": "Username already exists"})
            return
        self._send_json(201, user.to_public_dict())

    def _handle_login(self) -> None:
        data = self._parse_json_body()
        if data is None:
            return
        username_val = data.get("username")
        password_val = data.get("password")
        if not isinstance(username_val, str) or not isinstance(password_val, str):
            self._send_json(401, {"error": "Invalid credentials"})
            return
        user = DB.get_user_by_username(username_val)
        if user is None:
            self._send_json(401, {"error": "Invalid credentials"})
            return
        expected = pbkdf2_hash(password_val, user.password_salt)
        if not hmac_compare(user.password_hash, expected):
            self._send_json(401, {"error": "Invalid credentials"})
            return
        token = DB.create_session(user.id)
        self._send_json(200, user.to_public_dict(), set_cookie=token)

    def _handle_logout(self) -> None:
        user, token = self._authenticate()
        if user is None or token is None:
            self._send_json(401, {"error": "Authentication required"})
            return
        DB.invalidate_session(token)
        self._send_json(200, {}, clear_cookie=True)

    def _handle_me(self) -> None:
        user, _token = self._authenticate()
        if user is None:
            self._send_json(401, {"error": "Authentication required"})
            return
        self._send_json(200, user.to_public_dict())

    def _handle_password_change(self) -> None:
        user, _token = self._authenticate()
        if user is None:
            self._send_json(401, {"error": "Authentication required"})
            return
        data = self._parse_json_body()
        if data is None:
            return
        old_password = data.get("old_password")
        new_password = data.get("new_password")
        if not isinstance(old_password, str) or not isinstance(new_password, str):
            self._send_json(400, {"error": "Password too short"})
            return
        expected = pbkdf2_hash(old_password, user.password_salt)
        if not hmac_compare(user.password_hash, expected):
            self._send_json(401, {"error": "Invalid credentials"})
            return
        if len(new_password) < 8:
            self._send_json(400, {"error": "Password too short"})
            return
        DB.set_user_password(user.id, new_password)
        self._send_json(200, {})

    def _handle_todos_list(self) -> None:
        user, _token = self._authenticate()
        if user is None:
            self._send_json(401, {"error": "Authentication required"})
            return
        todos = DB.list_todos_for_user(user.id)
        self._send_json(200, [t.to_public_dict() for t in todos])

    def _handle_todos_create(self) -> None:
        user, _token = self._authenticate()
        if user is None:
            self._send_json(401, {"error": "Authentication required"})
            return
        data = self._parse_json_body()
        if data is None:
            return
        title_val = data.get("title")
        description_val = data.get("description", "")
        if not isinstance(title_val, str) or title_val.strip() == "":
            self._send_json(400, {"error": "Title is required"})
            return
        if not isinstance(description_val, str):
            description_val = str(description_val)
        todo = DB.create_todo(user.id, title_val, description_val)
        self._send_json(201, todo.to_public_dict())

    def _extract_todo_id(self, path: str) -> Optional[int]:
        # path like /todos/123
        parts = path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != "todos":
            return None
        try:
            tid = int(parts[1])
            if tid < 1:
                return None
            return tid
        except ValueError:
            return None

    def _handle_todos_get(self, path: str) -> None:
        user, _token = self._authenticate()
        if user is None:
            self._send_json(401, {"error": "Authentication required"})
            return
        tid = self._extract_todo_id(path)
        if tid is None:
            self._send_json(404, {"error": "Todo not found"})
            return
        todo = DB.get_todo(tid)
        if todo is None or todo.user_id != user.id:
            self._send_json(404, {"error": "Todo not found"})
            return
        self._send_json(200, todo.to_public_dict())

    def _handle_todos_update(self, path: str) -> None:
        user, _token = self._authenticate()
        if user is None:
            self._send_json(401, {"error": "Authentication required"})
            return
        tid = self._extract_todo_id(path)
        if tid is None:
            self._send_json(404, {"error": "Todo not found"})
            return
        data = self._parse_json_body()
        if data is None:
            return
        todo = DB.get_todo(tid)
        if todo is None or todo.user_id != user.id:
            self._send_json(404, {"error": "Todo not found"})
            return
        title_update: Optional[str] = None
        description_update: Optional[str] = None
        completed_update: Optional[bool] = None
        if "title" in data:
            title_val = data.get("title")
            if not isinstance(title_val, str) or title_val.strip() == "":
                self._send_json(400, {"error": "Title is required"})
                return
            title_update = title_val
        if "description" in data:
            desc_val = data.get("description")
            if not isinstance(desc_val, str):
                desc_val = str(desc_val)
            description_update = desc_val
        if "completed" in data:
            comp_val = data.get("completed")
            if isinstance(comp_val, bool):
                completed_update = comp_val
            else:
                # Treat non-bool values as invalid type -> 400 with generic message
                self._send_json(400, {"error": "Invalid JSON"})
                return
        updated = DB.update_todo(tid, title=title_update, description=description_update, completed=completed_update)
        assert updated is not None  # already checked exists
        self._send_json(200, updated.to_public_dict())

    def _handle_todos_delete(self, path: str) -> None:
        user, _token = self._authenticate()
        if user is None:
            self._send_json(401, {"error": "Authentication required"})
            return
        tid = self._extract_todo_id(path)
        if tid is None:
            self._send_json(404, {"error": "Todo not found"})
            return
        todo = DB.get_todo(tid)
        if todo is None or todo.user_id != user.id:
            self._send_json(404, {"error": "Todo not found"})
            return
        DB.delete_todo(tid)
        self._send_no_content(204)

    # Silence default logging to keep test output clean
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        return


def hmac_compare(a: bytes, b: bytes) -> bool:
    # Constant-time comparison to mitigate timing attacks
    if len(a) != len(b):
        return False
    result = 0
    for x, y in zip(a, b):
        result |= x ^ y
    return result == 0


def run_server(port: int) -> None:
    server_address = ("0.0.0.0", port)
    httpd = ThreadingHTTPServer(server_address, TodoRequestHandler)
    try:
        httpd.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()
    run_server(args.port)
