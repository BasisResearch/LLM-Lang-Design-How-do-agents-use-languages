from __future__ import annotations

import argparse
import json
import re
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Mapping, Optional, Union, cast

# Data models


def now_iso() -> str:
    # ISO 8601 UTC timestamp with second precision
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


Username = str
SessionToken = str


@dataclass
class User:
    id: int
    username: str
    password_hash: str


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


class InMemoryStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._users_by_id: Dict[int, User] = {}
        self._users_by_username: Dict[Username, User] = {}
        self._next_user_id: int = 1
        self._sessions: Dict[SessionToken, int] = {}
        self._todos_by_id: Dict[int, Todo] = {}
        self._next_todo_id: int = 1

    # User operations
    def create_user(self, username: str, password_hash: str) -> User:
        with self._lock:
            if username in self._users_by_username:
                raise ValueError("username_exists")
            uid = self._next_user_id
            self._next_user_id += 1
            user = User(id=uid, username=username, password_hash=password_hash)
            self._users_by_id[uid] = user
            self._users_by_username[username] = user
            return user

    def find_user_by_username(self, username: str) -> Optional[User]:
        with self._lock:
            return self._users_by_username.get(username)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        with self._lock:
            return self._users_by_id.get(user_id)

    def set_user_password_hash(self, user_id: int, new_hash: str) -> None:
        with self._lock:
            user = self._users_by_id.get(user_id)
            if user is not None:
                user.password_hash = new_hash

    # Session operations
    def create_session(self, user_id: int) -> SessionToken:
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

    # Todo operations
    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        with self._lock:
            todos = [t for t in self._todos_by_id.values() if t.user_id == user_id]
            todos.sort(key=lambda t: t.id)
            return list(todos)

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        with self._lock:
            tid = self._next_todo_id
            self._next_todo_id += 1
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
            return todo

    def get_todo_for_user(self, user_id: int, todo_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None:
                return None
            if todo.user_id != user_id:
                return None
            return todo

    def update_todo(self, todo: Todo, *, title: Optional[str], description: Optional[str], completed: Optional[bool]) -> Todo:
        with self._lock:
            if title is not None:
                todo.title = title
            if description is not None:
                todo.description = description
            if completed is not None:
                todo.completed = completed
            todo.updated_at = now_iso()
            return todo

    def delete_todo_for_user(self, user_id: int, todo_id: int) -> bool:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return False
            del self._todos_by_id[todo_id]
            return True


STORE = InMemoryStore()


def hash_password(pw: str) -> str:
    # For simplicity, a basic hash. In production, use a strong KDF.
    import hashlib

    return hashlib.sha256(pw.encode("utf-8")).hexdigest()


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def extract_session_token(cookie_header: Optional[str]) -> Optional[str]:
    if not cookie_header:
        return None
    c = SimpleCookie()
    c.load(cookie_header)
    morsel_any = c.get("session_id")
    if morsel_any is None:
        return None
    # Morsel has attribute 'value', but typeshed doesn't expose it generically.
    value_any: Any = morsel_any
    try:
        token = cast(str, value_any.value)
    except Exception:
        return None
    return token


class TodoHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    # Ensure we never send default HTML bodies
    def send_json(self, status: int, obj: Any, extra_headers: Optional[Mapping[str, str]] = None) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if extra_headers is not None:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status: int, message: str) -> None:
        self.send_json(status, {"error": message})

    def parse_json_body(self) -> Union[Mapping[str, Any], List[Any]]:
        length_str = self.headers.get("Content-Length")
        if length_str is None:
            return {}
        try:
            length = int(length_str)
        except ValueError:
            return {}
        if length <= 0:
            return {}
        data = self.rfile.read(length)
        try:
            parsed = json.loads(data.decode("utf-8"))
        except json.JSONDecodeError:
            raise ValueError("invalid_json")
        return cast(Union[Mapping[str, Any], List[Any]], parsed)

    def get_session_user_id(self) -> Optional[int]:
        token = extract_session_token(self.headers.get("Cookie"))
        if token is None:
            return None
        user_id = STORE.get_user_id_for_session(token)
        return user_id

    def require_auth(self) -> Optional[int]:
        user_id = self.get_session_user_id()
        if user_id is None:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        user = STORE.get_user_by_id(user_id)
        if user is None:
            # Session refers to unknown user; invalidate path silently
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        return user_id

    # Endpoint handlers

    def do_POST(self) -> None:
        if self.path == "/register":
            self.handle_register()
            return
        if self.path == "/login":
            self.handle_login()
            return
        if self.path == "/logout":
            uid = self.require_auth()
            if uid is None:
                return
            self.handle_logout()
            return
        if self.path == "/todos":
            uid = self.require_auth()
            if uid is None:
                return
            self.handle_create_todo(uid)
            return
        # Unknown
        self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:
        if self.path == "/me":
            uid = self.require_auth()
            if uid is None:
                return
            self.handle_me(uid)
            return
        if self.path == "/todos":
            uid = self.require_auth()
            if uid is None:
                return
            self.handle_list_todos(uid)
            return
        if self.path.startswith("/todos/"):
            uid = self.require_auth()
            if uid is None:
                return
            self.handle_get_todo(uid)
            return
        self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:
        if self.path == "/password":
            uid = self.require_auth()
            if uid is None:
                return
            self.handle_change_password(uid)
            return
        if self.path.startswith("/todos/"):
            uid = self.require_auth()
            if uid is None:
                return
            self.handle_update_todo(uid)
            return
        self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:
        if self.path.startswith("/todos/"):
            uid = self.require_auth()
            if uid is None:
                return
            self.handle_delete_todo(uid)
            return
        self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    # Specific handlers

    def handle_register(self) -> None:
        try:
            body_raw = self.parse_json_body()
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        if not isinstance(body_raw, Mapping):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_v = body_raw.get("username")
        password_v = body_raw.get("password")
        if not isinstance(username_v, str) or not USERNAME_RE.fullmatch(username_v):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_v, str) or len(password_v) < 8:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        try:
            user = STORE.create_user(username_v, hash_password(password_v))
        except ValueError as e:
            if str(e) == "username_exists":
                self.send_error_json(HTTPStatus.CONFLICT, "Username already exists")
                return
            raise
        self.send_json(HTTPStatus.CREATED, {"id": user.id, "username": user.username})

    def handle_login(self) -> None:
        try:
            body_raw = self.parse_json_body()
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        if not isinstance(body_raw, Mapping):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_v = body_raw.get("username")
        password_v = body_raw.get("password")
        if not isinstance(username_v, str) or not isinstance(password_v, str):
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = STORE.find_user_by_username(username_v)
        if user is None or user.password_hash != hash_password(password_v):
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = STORE.create_session(user.id)
        headers = {"Set-Cookie": f"session_id={token}; Path=/; HttpOnly"}
        self.send_json(HTTPStatus.OK, {"id": user.id, "username": user.username}, headers)

    def handle_logout(self) -> None:
        # Invalidate session token if present
        token = extract_session_token(self.headers.get("Cookie"))
        if token is not None:
            STORE.invalidate_session(token)
        self.send_json(HTTPStatus.OK, {})

    def handle_me(self, user_id: int) -> None:
        user = STORE.get_user_by_id(user_id)
        if user is None:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return
        self.send_json(HTTPStatus.OK, {"id": user.id, "username": user.username})

    def handle_change_password(self, user_id: int) -> None:
        try:
            body_raw = self.parse_json_body()
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        if not isinstance(body_raw, Mapping):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        old_pw_v = body_raw.get("old_password")
        new_pw_v = body_raw.get("new_password")
        if not isinstance(old_pw_v, str) or not isinstance(new_pw_v, str):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        user = STORE.get_user_by_id(user_id)
        if user is None or user.password_hash != hash_password(old_pw_v):
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        if len(new_pw_v) < 8:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        STORE.set_user_password_hash(user_id, hash_password(new_pw_v))
        self.send_json(HTTPStatus.OK, {})

    def handle_list_todos(self, user_id: int) -> None:
        todos = STORE.list_todos_for_user(user_id)
        data = [t.to_public() for t in todos]
        self.send_json(HTTPStatus.OK, data)

    def handle_create_todo(self, user_id: int) -> None:
        try:
            body_raw = self.parse_json_body()
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        if not isinstance(body_raw, Mapping):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_v = body_raw.get("title")
        description_v = body_raw.get("description", "")
        if not isinstance(title_v, str) or title_v.strip() == "":
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        if not isinstance(description_v, str):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        todo = STORE.create_todo(user_id, title_v, description_v)
        self.send_json(HTTPStatus.CREATED, todo.to_public())

    def _parse_todo_id_from_path(self) -> Optional[int]:
        parts = self.path.split("/")
        if len(parts) != 3:
            return None
        tid_str = parts[2]
        try:
            tid = int(tid_str)
        except ValueError:
            return None
        if tid <= 0:
            return None
        return tid

    def handle_get_todo(self, user_id: int) -> None:
        todo_id = self._parse_todo_id_from_path()
        if todo_id is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = STORE.get_todo_for_user(user_id, todo_id)
        if todo is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self.send_json(HTTPStatus.OK, todo.to_public())

    def handle_update_todo(self, user_id: int) -> None:
        todo_id = self._parse_todo_id_from_path()
        if todo_id is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        try:
            body_raw = self.parse_json_body()
        except ValueError:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        if not isinstance(body_raw, Mapping):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        todo = STORE.get_todo_for_user(user_id, todo_id)
        if todo is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        title_opt: Optional[str] = None
        description_opt: Optional[str] = None
        completed_opt: Optional[bool] = None
        if "title" in body_raw:
            title_v = body_raw.get("title")
            if not isinstance(title_v, str) or title_v.strip() == "":
                self.send_error_json(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            title_opt = title_v
        if "description" in body_raw:
            description_v = body_raw.get("description")
            if not isinstance(description_v, str):
                self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            description_opt = description_v
        if "completed" in body_raw:
            completed_v = body_raw.get("completed")
            if not isinstance(completed_v, bool):
                self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            completed_opt = completed_v
        updated = STORE.update_todo(todo, title=title_opt, description=description_opt, completed=completed_opt)
        self.send_json(HTTPStatus.OK, updated.to_public())

    def handle_delete_todo(self, user_id: int) -> None:
        todo_id = self._parse_todo_id_from_path()
        if todo_id is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        ok = STORE.delete_todo_for_user(user_id, todo_id)
        if not ok:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        # 204 No Content, no body
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    # Silence default logging to keep test output clean
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003 - match signature
        return


class ThreadingHTTPServerCompat(HTTPServer):
    # Python's built-in ThreadingHTTPServer is available in 3.7+ as http.server.ThreadingHTTPServer
    # but to keep compatibility, we use HTTPServer (single-threaded). This is sufficient for testing.
    pass


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args(argv)
    port = args.port
    server_address = ("0.0.0.0", port)
    httpd = ThreadingHTTPServerCompat(server_address, TodoHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
