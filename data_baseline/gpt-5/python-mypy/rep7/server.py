#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import threading
import time
import uuid
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Optional, Tuple, Any
from urllib.parse import urlparse

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def now_iso_utc() -> str:
    # ISO 8601 UTC with seconds precision and trailing Z
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


@dataclass
class User:
    id: int
    username: str
    password: str  # Stored in-memory; for demo only

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
        self._lock = threading.RLock()
        self._users_by_id: Dict[int, User] = {}
        self._user_id_by_username: Dict[str, int] = {}
        self._password_by_user_id: Dict[int, str] = {}
        self._next_user_id: int = 1

        self._sessions: Dict[str, int] = {}

        self._todos_by_id: Dict[int, Todo] = {}
        self._todo_ids_by_user: Dict[int, List[int]] = {}
        self._next_todo_id: int = 1

    # User management
    def create_user(self, username: str, password: str) -> Tuple[Optional[User], Optional[str]]:
        with self._lock:
            if username in self._user_id_by_username:
                return None, "Username already exists"
            user_id = self._next_user_id
            self._next_user_id += 1
            user = User(id=user_id, username=username, password=password)
            self._users_by_id[user_id] = user
            self._user_id_by_username[username] = user_id
            self._password_by_user_id[user_id] = password
            return user, None

    def get_user_by_credentials(self, username: str, password: str) -> Optional[User]:
        with self._lock:
            user_id = self._user_id_by_username.get(username)
            if user_id is None:
                return None
            if self._password_by_user_id.get(user_id) != password:
                return None
            return self._users_by_id.get(user_id)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        with self._lock:
            return self._users_by_id.get(user_id)

    def change_password(self, user_id: int, old_password: str, new_password: str) -> bool:
        with self._lock:
            current = self._password_by_user_id.get(user_id)
            if current != old_password:
                return False
            self._password_by_user_id[user_id] = new_password
            user = self._users_by_id.get(user_id)
            if user is not None:
                user.password = new_password
            return True

    # Session management
    def create_session(self, user_id: int) -> str:
        with self._lock:
            token = uuid.uuid4().hex
            self._sessions[token] = user_id
            return token

    def invalidate_session(self, token: str) -> None:
        with self._lock:
            if token in self._sessions:
                del self._sessions[token]

    def get_user_id_by_session(self, token: str) -> Optional[int]:
        with self._lock:
            return self._sessions.get(token)

    # Todo management
    def list_todos(self, user_id: int) -> List[Todo]:
        with self._lock:
            ids = self._todo_ids_by_user.get(user_id, [])
            # Ensure ascending order by id
            return [self._todos_by_id[i] for i in sorted(ids)]

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        with self._lock:
            todo_id = self._next_todo_id
            self._next_todo_id += 1
            ts = now_iso_utc()
            todo = Todo(
                id=todo_id,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=ts,
                updated_at=ts,
            )
            self._todos_by_id[todo_id] = todo
            self._todo_ids_by_user.setdefault(user_id, []).append(todo_id)
            return todo

    def get_todo_for_user(self, user_id: int, todo_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return None
            return todo

    def update_todo(self, user_id: int, todo_id: int, *, title: Optional[str] = None, description: Optional[str] = None, completed: Optional[bool] = None) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return None
            if title is not None:
                todo.title = title
            if description is not None:
                todo.description = description
            if completed is not None:
                todo.completed = completed
            todo.updated_at = now_iso_utc()
            return todo

    def delete_todo(self, user_id: int, todo_id: int) -> bool:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return False
            del self._todos_by_id[todo_id]
            if user_id in self._todo_ids_by_user:
                try:
                    self._todo_ids_by_user[user_id].remove(todo_id)
                except ValueError:
                    pass
            return True


STORE = DataStore()


class TodoRequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoApp/1.0"

    # Ensure we don't write any default HTML; override to prevent logging to stderr
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003 (shadowing built-in 'format')
        # Suppress default logging or customize as needed
        return

    # Utility methods
    def _send_json(self, status: int, data: Any) -> None:
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_json_error(self, status: int, message: str) -> None:
        self._send_json(status, {"error": message})

    def _send_no_content(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        # No body for DELETE per spec
        self.end_headers()

    def _parse_json_body(self) -> Tuple[bool, Optional[Any]]:
        length_str = self.headers.get("Content-Length")
        if length_str is None:
            return True, None
        try:
            length = int(length_str)
        except ValueError:
            return False, None
        try:
            data = self.rfile.read(length)
        except Exception:
            return False, None
        try:
            if not data:
                return True, None
            return True, json.loads(data.decode("utf-8"))
        except Exception:
            return False, None

    def _read_cookie(self, name: str) -> Optional[str]:
        cookie = self.headers.get("Cookie")
        if not cookie:
            return None
        parts = [p.strip() for p in cookie.split(";")]
        for part in parts:
            if "=" not in part:
                continue
            k, v = part.split("=", 1)
            if k.strip() == name:
                return v.strip()
        return None

    def _require_auth(self) -> Optional[User]:
        token = self._read_cookie("session_id")
        if token is None:
            self._send_json_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        user_id = STORE.get_user_id_by_session(token)
        if user_id is None:
            self._send_json_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        user = STORE.get_user_by_id(user_id)
        if user is None:
            self._send_json_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        return user

    # Handlers
    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        ok, body = self._parse_json_body()
        if not ok:
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        if path == "/register":
            self._handle_register(body)
            return
        if path == "/login":
            self._handle_login(body)
            return
        if path == "/logout":
            self._handle_logout()
            return
        if path == "/todos":
            self._handle_create_todo(body)
            return
        self._send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/me":
            self._handle_me()
            return
        if path == "/todos":
            self._handle_list_todos()
            return
        if path.startswith("/todos/"):
            self._handle_get_todo(path)
            return
        self._send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        ok, body = self._parse_json_body()
        if not ok:
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        if path == "/password":
            self._handle_password_change(body)
            return
        if path.startswith("/todos/"):
            self._handle_update_todo(path, body)
            return
        self._send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith("/todos/"):
            self._handle_delete_todo(path)
            return
        self._send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    # Endpoint implementations
    def _handle_register(self, body: Optional[Any]) -> None:
        if not isinstance(body, dict):
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_v = body.get("username")
        password_v = body.get("password")
        if not isinstance(username_v, str) or not USERNAME_RE.fullmatch(username_v):
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_v, str) or len(password_v) < 8:
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        user, err = STORE.create_user(username_v, password_v)
        if err is not None or user is None:
            self._send_json_error(HTTPStatus.CONFLICT, "Username already exists")
            return
        self._send_json(HTTPStatus.CREATED, user.to_public())

    def _handle_login(self, body: Optional[Any]) -> None:
        if not isinstance(body, dict):
            self._send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        username_v = body.get("username")
        password_v = body.get("password")
        if not isinstance(username_v, str) or not isinstance(password_v, str):
            self._send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = STORE.get_user_by_credentials(username_v, password_v)
        if user is None:
            self._send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = STORE.create_session(user.id)
        body_out = json.dumps(user.to_public()).encode("utf-8")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body_out)))
        self.send_header("Set-Cookie", f"session_id={token}; Path=/; HttpOnly")
        self.end_headers()
        self.wfile.write(body_out)

    def _handle_logout(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        token = self._read_cookie("session_id")
        if token is not None:
            STORE.invalidate_session(token)
        # Return empty JSON object per spec
        self._send_json(HTTPStatus.OK, {})

    def _handle_me(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        self._send_json(HTTPStatus.OK, user.to_public())

    def _handle_password_change(self, body: Optional[Any]) -> None:
        user = self._require_auth()
        if user is None:
            return
        if not isinstance(body, dict):
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        old_pw_v = body.get("old_password")
        new_pw_v = body.get("new_password")
        if not isinstance(old_pw_v, str) or not isinstance(new_pw_v, str):
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        if len(new_pw_v) < 8:
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        ok = STORE.change_password(user.id, old_pw_v, new_pw_v)
        if not ok:
            self._send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        self._send_json(HTTPStatus.OK, {})

    def _handle_list_todos(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        todos = [t.to_public() for t in STORE.list_todos(user.id)]
        self._send_json(HTTPStatus.OK, todos)

    def _handle_create_todo(self, body: Optional[Any]) -> None:
        user = self._require_auth()
        if user is None:
            return
        if not isinstance(body, dict):
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_v = body.get("title")
        description_v = body.get("description", "")
        if not isinstance(title_v, str) or title_v == "":
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        if not isinstance(description_v, str):
            description_v = ""
        todo = STORE.create_todo(user.id, title_v, description_v)
        self._send_json(HTTPStatus.CREATED, todo.to_public())

    def _extract_todo_id(self, path: str) -> Optional[int]:
        # path like /todos/123
        parts = path.strip("/").split("/")
        if len(parts) != 2 or parts[0] != "todos":
            return None
        try:
            tid = int(parts[1])
        except ValueError:
            return None
        if tid <= 0:
            return None
        return tid

    def _handle_get_todo(self, path: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        tid = self._extract_todo_id(path)
        if tid is None:
            self._send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = STORE.get_todo_for_user(user.id, tid)
        if todo is None:
            self._send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self._send_json(HTTPStatus.OK, todo.to_public())

    def _handle_update_todo(self, path: str, body: Optional[Any]) -> None:
        user = self._require_auth()
        if user is None:
            return
        tid = self._extract_todo_id(path)
        if tid is None:
            self._send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        if not isinstance(body, dict):
            self._send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_set = False
        title_v: Optional[str] = None
        if "title" in body:
            v = body.get("title")
            if not isinstance(v, str) or v == "":
                self._send_json_error(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            title_set = True
            title_v = v
        desc_set = False
        desc_v: Optional[str] = None
        if "description" in body:
            v2 = body.get("description")
            if isinstance(v2, str):
                desc_set = True
                desc_v = v2
        comp_set = False
        comp_v: Optional[bool] = None
        if "completed" in body:
            v3 = body.get("completed")
            if isinstance(v3, bool):
                comp_set = True
                comp_v = v3
        todo = STORE.get_todo_for_user(user.id, tid)
        if todo is None:
            self._send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        updated = STORE.update_todo(
            user.id,
            tid,
            title=title_v if title_set else None,
            description=desc_v if desc_set else None,
            completed=comp_v if comp_set else None,
        )
        if updated is None:
            self._send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self._send_json(HTTPStatus.OK, updated.to_public())

    def _handle_delete_todo(self, path: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        tid = self._extract_todo_id(path)
        if tid is None:
            self._send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        ok = STORE.delete_todo(user.id, tid)
        if not ok:
            self._send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self._send_no_content()


def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()

    server = ThreadingHTTPServer(("0.0.0.0", args.port), TodoRequestHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
