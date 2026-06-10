#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Mapping, MutableMapping, Optional, Tuple, TypeVar, cast


JsonDict = Dict[str, Any]


def utc_now_iso_seconds() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class User:
    id: int
    username: str
    password_hash: str

    def to_public(self) -> JsonDict:
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

    def to_public(self) -> JsonDict:
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
        self._lock = threading.RLock()
        self._users_by_id: Dict[int, User] = {}
        self._users_by_username: Dict[str, User] = {}
        self._next_user_id = 1

        self._todos_by_id: Dict[int, Todo] = {}
        self._next_todo_id = 1

        # session token -> user_id
        self._sessions: Dict[str, int] = {}

    def create_user(self, username: str, password_hash: str) -> User:
        with self._lock:
            if username in self._users_by_username:
                raise ValueError("Username exists")
            user = User(id=self._next_user_id, username=username, password_hash=password_hash)
            self._users_by_id[user.id] = user
            self._users_by_username[username] = user
            self._next_user_id += 1
            return user

    def get_user_by_username(self, username: str) -> Optional[User]:
        with self._lock:
            return self._users_by_username.get(username)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        with self._lock:
            return self._users_by_id.get(user_id)

    def set_user_password_hash(self, user_id: int, password_hash: str) -> None:
        with self._lock:
            user = self._users_by_id.get(user_id)
            if user is None:
                return
            user.password_hash = password_hash

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

    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        with self._lock:
            todos = [t for t in self._todos_by_id.values() if t.user_id == user_id]
            todos.sort(key=lambda t: t.id)
            return list(todos)

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        with self._lock:
            now = utc_now_iso_seconds()
            todo = Todo(
                id=self._next_todo_id,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=now,
                updated_at=now,
            )
            self._todos_by_id[todo.id] = todo
            self._next_todo_id += 1
            return todo

    def get_todo_checked(self, todo_id: int, user_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None:
                return None
            if todo.user_id != user_id:
                return None
            return todo

    def update_todo(self, todo: Todo, *, title: Optional[str] = None, description: Optional[str] = None, completed: Optional[bool] = None) -> Todo:
        with self._lock:
            if title is not None:
                todo.title = title
            if description is not None:
                todo.description = description
            if completed is not None:
                todo.completed = completed
            todo.updated_at = utc_now_iso_seconds()
            return todo

    def delete_todo(self, todo_id: int) -> None:
        with self._lock:
            if todo_id in self._todos_by_id:
                del self._todos_by_id[todo_id]


STORE = InMemoryStore()


# Utilities

def json_bytes(data: Any) -> bytes:
    return json.dumps(data, separators=(",", ":")).encode("utf-8")


def parse_cookies(cookie_header: Optional[str]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    if not cookie_header:
        return result
    parts = [p.strip() for p in cookie_header.split(";")]
    for part in parts:
        if not part:
            continue
        if "=" not in part:
            continue
        name, value = part.split("=", 1)
        result[name.strip()] = value.strip()
    return result


def hash_password(password: str) -> str:
    # Simple SHA-256 hash; for demo only
    import hashlib

    return hashlib.sha256(password.encode("utf-8")).hexdigest()


T = TypeVar("T")


class RequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    # Ensure no default logging to stderr to keep test output clean
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003 - follows BaseHTTPRequestHandler signature
        return

    def _send_json(self, status: int, payload: Any, set_cookie: Optional[str] = None) -> None:
        body = json_bytes(payload)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if set_cookie is not None:
            self.send_header("Set-Cookie", set_cookie)
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, status: int, message: str) -> None:
        self._send_json(status, {"error": message})

    def _read_json_body(self) -> Tuple[bool, Optional[JsonDict], Optional[str]]:
        # Returns (ok, data, error_message)
        try:
            length_str = self.headers.get("Content-Length")
            length = int(length_str) if length_str is not None else 0
        except ValueError:
            return (False, None, "Invalid Content-Length")
        if length <= 0:
            return (True, {}, None)
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except Exception:
            return (False, None, "Invalid JSON")
        if not isinstance(parsed, dict):
            return (False, None, "Invalid JSON")
        # type narrowing
        data = cast(JsonDict, parsed)
        return (True, data, None)

    def _require_auth(self) -> Tuple[Optional[User], Optional[str]]:
        cookie_header = self.headers.get("Cookie")
        cookies = parse_cookies(cookie_header)
        token = cookies.get("session_id")
        if token is None:
            return (None, None)
        user_id = STORE.get_user_id_for_session(token)
        if user_id is None:
            return (None, None)
        user = STORE.get_user_by_id(user_id)
        if user is None:
            return (None, None)
        return (user, token)

    # Routing
    def do_POST(self) -> None:  # noqa: N802 - method name from BaseHTTPRequestHandler
        path = self.path or ""
        if path == "/register":
            self.handle_register()
            return
        if path == "/login":
            self.handle_login()
            return
        if path == "/logout":
            user, token = self._require_auth()
            if user is None or token is None:
                self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
                return
            # Invalidate session
            STORE.invalidate_session(token)
            self._send_json(HTTPStatus.OK, {})
            return
        if path == "/todos":
            user, _ = self._require_auth()
            if user is None:
                self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
                return
            self.handle_create_todo(user)
            return
        # Not found
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:  # noqa: N802
        path = self.path or ""
        if path == "/me":
            user, _ = self._require_auth()
            if user is None:
                self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
                return
            self._send_json(HTTPStatus.OK, user.to_public())
            return
        if path == "/todos":
            user, _ = self._require_auth()
            if user is None:
                self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
                return
            todos = STORE.list_todos_for_user(user.id)
            data = [t.to_public() for t in todos]
            self._send_json(HTTPStatus.OK, data)
            return
        if path.startswith("/todos/"):
            user, _ = self._require_auth()
            if user is None:
                self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
                return
            seg = path[len("/todos/") :]
            try:
                todo_id = int(seg)
            except ValueError:
                self._send_error(HTTPStatus.NOT_FOUND, "Not found")
                return
            todo = STORE.get_todo_checked(todo_id, user.id)
            if todo is None:
                self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
                return
            self._send_json(HTTPStatus.OK, todo.to_public())
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802
        path = self.path or ""
        if path == "/password":
            user, _ = self._require_auth()
            if user is None:
                self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
                return
            ok, data, err = self._read_json_body()
            if not ok or data is None:
                self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            old_pw = data.get("old_password")
            new_pw = data.get("new_password")
            if not isinstance(old_pw, str) or not isinstance(new_pw, str):
                self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            if STORE.get_user_by_username(user.username) is None:
                self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
                return
            if user.password_hash != hash_password(old_pw):
                self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
                return
            if len(new_pw) < 8:
                self._send_error(HTTPStatus.BAD_REQUEST, "Password too short")
                return
            STORE.set_user_password_hash(user.id, hash_password(new_pw))
            # Refresh user reference
            fresh_user = STORE.get_user_by_id(user.id)
            if fresh_user is not None:
                user = fresh_user
            self._send_json(HTTPStatus.OK, {})
            return
        if path.startswith("/todos/"):
            user, _ = self._require_auth()
            if user is None:
                self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
                return
            seg = path[len("/todos/") :]
            try:
                todo_id = int(seg)
            except ValueError:
                self._send_error(HTTPStatus.NOT_FOUND, "Not found")
                return
            todo = STORE.get_todo_checked(todo_id, user.id)
            if todo is None:
                self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
                return
            ok, data, err = self._read_json_body()
            if not ok or data is None:
                self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            # Partial update
            title_upd: Optional[str] = None
            desc_upd: Optional[str] = None
            comp_upd: Optional[bool] = None
            if "title" in data:
                title_val = data.get("title")
                if not isinstance(title_val, str):
                    self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                    return
                if title_val.strip() == "":
                    self._send_error(HTTPStatus.BAD_REQUEST, "Title is required")
                    return
                title_upd = title_val
            if "description" in data:
                desc_val = data.get("description")
                if not isinstance(desc_val, str):
                    self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                    return
                desc_upd = desc_val
            if "completed" in data:
                comp_val = data.get("completed")
                if not isinstance(comp_val, bool):
                    self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                    return
                comp_upd = comp_val
            updated = STORE.update_todo(todo, title=title_upd, description=desc_upd, completed=comp_upd)
            self._send_json(HTTPStatus.OK, updated.to_public())
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802
        path = self.path or ""
        if path.startswith("/todos/"):
            user, _ = self._require_auth()
            if user is None:
                self.send_response(HTTPStatus.UNAUTHORIZED)
                self.send_header("Content-Type", "application/json")
                body = json_bytes({"error": "Authentication required"})
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            seg = path[len("/todos/") :]
            try:
                todo_id = int(seg)
            except ValueError:
                # Unknown resource
                self._send_error(HTTPStatus.NOT_FOUND, "Not found")
                return
            todo = STORE.get_todo_checked(todo_id, user.id)
            if todo is None:
                self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
                return
            STORE.delete_todo(todo_id)
            # 204 No Content, no body
            self.send_response(HTTPStatus.NO_CONTENT)
            # Do not send Content-Type or body for 204
            self.end_headers()
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    # Handlers
    def handle_register(self) -> None:
        ok, data, err = self._read_json_body()
        if not ok or data is None:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username = data.get("username")
        password = data.get("password")
        if not isinstance(username, str):
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password, str):
            self._send_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        if len(password) < 8:
            self._send_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        if len(username) < 3 or len(username) > 50:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not re.fullmatch(r"^[A-Za-z0-9_]+$", username):
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        try:
            user = STORE.create_user(username=username, password_hash=hash_password(password))
        except ValueError:
            self._send_error(HTTPStatus.CONFLICT, "Username already exists")
            return
        self._send_json(HTTPStatus.CREATED, user.to_public())

    def handle_login(self) -> None:
        ok, data, err = self._read_json_body()
        if not ok or data is None:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username = data.get("username")
        password = data.get("password")
        if not isinstance(username, str) or not isinstance(password, str):
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = STORE.get_user_by_username(username)
        if user is None:
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        if user.password_hash != hash_password(password):
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = STORE.create_session(user.id)
        set_cookie = f"session_id={token}; Path=/; HttpOnly"
        self._send_json(HTTPStatus.OK, user.to_public(), set_cookie=set_cookie)

    def handle_create_todo(self, user: User) -> None:
        ok, data, err = self._read_json_body()
        if not ok or data is None:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title = data.get("title")
        description_raw = data.get("description", "")
        if not isinstance(title, str) or title.strip() == "":
            self._send_error(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        description: str
        if isinstance(description_raw, str):
            description = description_raw
        else:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        todo = STORE.create_todo(user_id=user.id, title=title, description=description)
        self._send_json(HTTPStatus.CREATED, todo.to_public())


def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("0.0.0.0", args.port), RequestHandler)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
