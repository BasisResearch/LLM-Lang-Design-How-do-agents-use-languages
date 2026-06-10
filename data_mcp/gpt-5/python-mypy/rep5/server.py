from __future__ import annotations

import argparse
import json
import re
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, ClassVar, Dict, List, Mapping, Optional, Sequence, Tuple, Union
from urllib.parse import urlparse


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")

JSONRoot = Union[Mapping[str, Any], List[Any]]


def now_iso() -> str:
    # ISO 8601 UTC timestamp with second precision
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class User:
    id: int
    username: str
    password: str

    def to_public(self) -> Dict[str, Any]:
        return {"id": self.id, "username": self.username}


@dataclass
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str

    def to_public(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
            "completed": self.completed,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


class DataStore:
    def __init__(self) -> None:
        self._lock: threading.RLock = threading.RLock()
        self._users_by_id: Dict[int, User] = {}
        self._users_by_username: Dict[str, int] = {}
        self._todos_by_id: Dict[int, Todo] = {}
        self._sessions: Dict[str, int] = {}
        self._next_user_id: int = 1
        self._next_todo_id: int = 1

    # User management
    def create_user(self, username: str, password: str) -> User:
        with self._lock:
            if username in self._users_by_username:
                raise ValueError("exists")
            user = User(id=self._next_user_id, username=username, password=password)
            self._users_by_id[user.id] = user
            self._users_by_username[username] = user.id
            self._next_user_id += 1
            return user

    def find_user_by_username(self, username: str) -> Optional[User]:
        with self._lock:
            uid = self._users_by_username.get(username)
            if uid is None:
                return None
            return self._users_by_id.get(uid)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        with self._lock:
            return self._users_by_id.get(user_id)

    def set_password(self, user_id: int, new_password: str) -> None:
        with self._lock:
            user = self._users_by_id.get(user_id)
            if user is None:
                return
            user.password = new_password

    # Session management
    def create_session(self, user_id: int) -> str:
        token = uuid.uuid4().hex
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

    # Todo management
    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        with self._lock:
            todos = [t for t in self._todos_by_id.values() if t.user_id == user_id]
            todos.sort(key=lambda t: t.id)
            return list(todos)

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        with self._lock:
            tid = self._next_todo_id
            ts = now_iso()
            todo = Todo(
                id=tid,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=ts,
                updated_at=ts,
            )
            self._todos_by_id[tid] = todo
            self._next_todo_id += 1
            return todo

    def get_todo(self, todo_id: int) -> Optional[Todo]:
        with self._lock:
            return self._todos_by_id.get(todo_id)

    def update_todo(self, todo: Todo) -> None:
        with self._lock:
            # As objects are mutable, they are already updated
            self._todos_by_id[todo.id] = todo

    def delete_todo(self, todo_id: int) -> None:
        with self._lock:
            if todo_id in self._todos_by_id:
                del self._todos_by_id[todo_id]


class TodoRequestHandler(BaseHTTPRequestHandler):
    store: ClassVar[DataStore]

    server_version = "TodoServer/1.0"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003 - shadow builtin format
        # Reduce noise in tests
        return

    # Utilities
    def parse_json(self) -> Tuple[Optional[Mapping[str, Any]], Optional[str]]:
        length_str = self.headers.get("Content-Length")
        if length_str is None:
            data = b""
        else:
            try:
                length = int(length_str)
            except ValueError:
                return None, "Invalid Content-Length"
            data = self.rfile.read(length)
        if not data:
            return {}, None
        try:
            obj = json.loads(data.decode("utf-8"))
        except json.JSONDecodeError:
            return None, "Invalid JSON"
        if not isinstance(obj, dict):
            return None, "Invalid JSON"
        return obj, None

    def parse_cookies(self) -> Dict[str, str]:
        result: Dict[str, str] = {}
        cookie = self.headers.get("Cookie")
        if not cookie:
            return result
        parts = [p.strip() for p in cookie.split(";")]
        for part in parts:
            if "=" in part:
                k, v = part.split("=", 1)
                result[k.strip()] = v.strip()
        return result

    def get_authenticated_user(self) -> Tuple[Optional[User], Optional[str], Optional[str]]:
        cookies = self.parse_cookies()
        token = cookies.get("session_id")
        if not token:
            return None, None, None
        user_id = self.store.get_user_id_for_session(token)
        if user_id is None:
            return None, token, None
        user = self.store.get_user_by_id(user_id)
        return user, token, None

    def send_json(self, status: int, payload: JSONRoot, set_cookie: Optional[str] = None) -> None:
        body_bytes = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_bytes)))
        if set_cookie is not None:
            self.send_header("Set-Cookie", set_cookie)
        self.end_headers()
        self.wfile.write(body_bytes)

    def send_json_error(self, status: int, message: str) -> None:
        self.send_json(status, {"error": message})

    # Handlers
    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/register":
            self.handle_register()
            return
        if path == "/login":
            self.handle_login()
            return
        if path == "/logout":
            self.handle_logout()
            return
        if path == "/todos":
            self.handle_create_todo()
            return
        self.send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/me":
            self.handle_me()
            return
        if path == "/todos":
            self.handle_list_todos()
            return
        if path.startswith("/todos/"):
            self.handle_get_todo(path)
            return
        self.send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/password":
            self.handle_change_password()
            return
        if path.startswith("/todos/"):
            self.handle_update_todo(path)
            return
        self.send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/todos/"):
            self.handle_delete_todo(path)
            return
        self.send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    # Endpoint implementations
    def handle_register(self) -> None:
        body, _ = self.parse_json()
        if body is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_val = body.get("username")
        password_val = body.get("password")
        if not isinstance(username_val, str) or not USERNAME_RE.fullmatch(username_val):
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_val, str) or len(password_val) < 8:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        try:
            user = self.store.create_user(username_val, password_val)
        except ValueError:
            self.send_json_error(HTTPStatus.CONFLICT, "Username already exists")
            return
        self.send_json(HTTPStatus.CREATED, user.to_public())

    def handle_login(self) -> None:
        body, _ = self.parse_json()
        if body is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_val = body.get("username")
        password_val = body.get("password")
        if not isinstance(username_val, str) or not isinstance(password_val, str):
            self.send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = self.store.find_user_by_username(username_val)
        if user is None or user.password != password_val:
            self.send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = self.store.create_session(user.id)
        cookie = f"session_id={token}; Path=/; HttpOnly"
        self.send_json(HTTPStatus.OK, user.to_public(), set_cookie=cookie)

    def require_auth(self) -> Tuple[Optional[User], Optional[str]]:
        user, token, _ = self.get_authenticated_user()
        if user is None:
            self.send_json_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None, token
        return user, token

    def handle_logout(self) -> None:
        user, token = self.require_auth()
        if user is None:
            return
        if token is not None:
            self.store.invalidate_session(token)
        # Empty JSON object per spec
        self.send_json(HTTPStatus.OK, {})

    def handle_me(self) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        self.send_json(HTTPStatus.OK, user.to_public())

    def handle_change_password(self) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        body, _ = self.parse_json()
        if body is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        old_pw = body.get("old_password")
        new_pw = body.get("new_password")
        if not isinstance(old_pw, str) or user.password != old_pw:
            self.send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        self.store.set_password(user.id, new_pw)
        self.send_json(HTTPStatus.OK, {})

    def handle_list_todos(self) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        todos = self.store.list_todos_for_user(user.id)
        arr: List[Dict[str, Any]] = [t.to_public() for t in todos]
        self.send_json(HTTPStatus.OK, arr)

    def handle_create_todo(self) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        body, _ = self.parse_json()
        if body is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_val = body.get("title")
        description_val = body.get("description", "")
        if not isinstance(title_val, str) or title_val.strip() == "":
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        if not isinstance(description_val, str):
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid request")
            return
        todo = self.store.create_todo(user.id, title_val, description_val)
        self.send_json(HTTPStatus.CREATED, todo.to_public())

    def _extract_todo_id(self, path: str) -> Optional[int]:
        parts = path.strip("/").split("/")
        if len(parts) != 2:
            return None
        if parts[0] != "todos":
            return None
        try:
            tid = int(parts[1])
        except ValueError:
            return None
        return tid

    def _get_owned_todo(self, path: str, user: User) -> Optional[Todo]:
        tid = self._extract_todo_id(path)
        if tid is None:
            return None
        todo = self.store.get_todo(tid)
        if todo is None or todo.user_id != user.id:
            return None
        return todo

    def handle_get_todo(self, path: str) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        todo = self._get_owned_todo(path, user)
        if todo is None:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self.send_json(HTTPStatus.OK, todo.to_public())

    def handle_update_todo(self, path: str) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        todo = self._get_owned_todo(path, user)
        if todo is None:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        body, _ = self.parse_json()
        if body is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        # Partial update
        if "title" in body:
            title_val = body.get("title")
            if not isinstance(title_val, str) or title_val.strip() == "":
                self.send_json_error(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            todo.title = title_val
        if "description" in body:
            description_val = body.get("description")
            if not isinstance(description_val, str):
                self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid request")
                return
            todo.description = description_val
        if "completed" in body:
            completed_val = body.get("completed")
            if not isinstance(completed_val, bool):
                self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid request")
                return
            todo.completed = completed_val
        todo.updated_at = now_iso()
        self.store.update_todo(todo)
        self.send_json(HTTPStatus.OK, todo.to_public())

    def handle_delete_todo(self, path: str) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        tid = self._extract_todo_id(path)
        if tid is None:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = self.store.get_todo(tid)
        if todo is None or todo.user_id != user.id:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self.store.delete_todo(tid)
        # Success: 204 with no body and no Content-Type
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Content-Length", "0")
        self.end_headers()


def run_server(port: int) -> None:
    handler = TodoRequestHandler
    handler.store = DataStore()
    httpd = ThreadingHTTPServer(("0.0.0.0", port), handler)
    httpd.daemon_threads = True
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()
    run_server(args.port)


if __name__ == "__main__":
    main()
