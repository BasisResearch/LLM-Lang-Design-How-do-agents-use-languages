#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]+$")


def utc_now_iso_seconds() -> str:
    # Format: YYYY-MM-DDTHH:MM:SSZ
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class User:
    id: int
    username: str
    password: str  # stored in plain text for this exercise

    def to_public(self) -> Dict[str, object]:
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

    def to_public(self) -> Dict[str, object]:
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
        self._lock = threading.Lock()
        self._users_by_id: Dict[int, User] = {}
        self._users_by_username: Dict[str, User] = {}
        self._todos_by_id: Dict[int, Todo] = {}
        self._sessions: Dict[str, int] = {}
        self._next_user_id: int = 1
        self._next_todo_id: int = 1

    # User management
    def create_user(self, username: str, password: str) -> Tuple[Optional[User], Optional[str]]:
        with self._lock:
            if username in self._users_by_username:
                return None, "Username already exists"
            user = User(id=self._next_user_id, username=username, password=password)
            self._users_by_id[user.id] = user
            self._users_by_username[user.username] = user
            self._next_user_id += 1
            return user, None

    def authenticate(self, username: str, password: str) -> Optional[User]:
        with self._lock:
            user = self._users_by_username.get(username)
            if user is None:
                return None
            if user.password != password:
                return None
            return user

    def change_password(self, user_id: int, new_password: str) -> None:
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

    def get_user_by_session(self, token: str) -> Optional[User]:
        with self._lock:
            uid = self._sessions.get(token)
            if uid is None:
                return None
            return self._users_by_id.get(uid)

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

    def get_todo_for_user(self, user_id: int, todo_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None:
                return None
            if todo.user_id != user_id:
                return None
            return todo

    def update_todo(self, todo_id: int, *, title: Optional[str] = None, description: Optional[str] = None, completed: Optional[bool] = None) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None:
                return None
            if title is not None:
                todo.title = title
            if description is not None:
                todo.description = description
            if completed is not None:
                todo.completed = completed
            todo.updated_at = utc_now_iso_seconds()
            return todo

    def delete_todo(self, todo_id: int) -> bool:
        with self._lock:
            if todo_id in self._todos_by_id:
                del self._todos_by_id[todo_id]
                return True
            return False


STORE = DataStore()


class TodoRequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    # Ensure we do not log every request to stdout
    def log_message(self, format: str, *args: object) -> None:  # noqa: A003 - clash with builtin format
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))

    # Utilities
    def parse_json_body(self) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
        length_str = self.headers.get("Content-Length")
        if length_str is None:
            return {}, None  # Allow empty body for endpoints that don't require it
        try:
            length = int(length_str)
        except ValueError:
            return None, "Invalid Content-Length"
        try:
            raw = self.rfile.read(length)
        except Exception:
            return None, "Failed to read request body"
        try:
            if not raw:
                return {}, None
            data = json.loads(raw.decode("utf-8"))
        except Exception:
            return None, "Invalid JSON"
        if not isinstance(data, dict):
            return None, "Invalid JSON object"
        return data, None

    def get_path_parts(self) -> List[str]:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/":
            return [""]
        parts = [p for p in path.split("/") if p != ""]
        return parts

    def get_session_token(self) -> Optional[str]:
        cookie_header = self.headers.get("Cookie")
        if not cookie_header:
            return None
        try:
            cookie = SimpleCookie(cookie_header)
        except Exception:
            return None
        morsel = cookie.get("session_id")
        if morsel is None:
            return None
        return morsel.value

    def require_auth(self) -> Optional[Tuple[User, str]]:
        token = self.get_session_token()
        if token is None:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        user = STORE.get_user_by_session(token)
        if user is None:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        return user, token

    def send_json(self, status: int, payload: object, extra_headers: Optional[List[Tuple[str, str]]] = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if extra_headers:
            for (k, v) in extra_headers:
                self.send_header(k, v)
        self.end_headers()
        body = json.dumps(payload).encode("utf-8")
        self.wfile.write(body)

    def send_error_json(self, status: int, message: str) -> None:
        self.send_json(status, {"error": message})

    # Handlers
    def do_POST(self) -> None:  # noqa: N802
        parts = self.get_path_parts()
        if parts == ["register"]:
            self.handle_register()
            return
        if parts == ["login"]:
            self.handle_login()
            return
        if parts == ["logout"]:
            self.handle_logout()
            return
        if parts == ["todos"]:
            self.handle_create_todo()
            return
        self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:  # noqa: N802
        parts = self.get_path_parts()
        if parts == ["me"]:
            self.handle_me()
            return
        if len(parts) == 1 and parts[0] == "todos":
            self.handle_list_todos()
            return
        if len(parts) == 2 and parts[0] == "todos":
            self.handle_get_todo(parts[1])
            return
        self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802
        parts = self.get_path_parts()
        if parts == ["password"]:
            self.handle_change_password()
            return
        if len(parts) == 2 and parts[0] == "todos":
            self.handle_update_todo(parts[1])
            return
        self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802
        parts = self.get_path_parts()
        if len(parts) == 2 and parts[0] == "todos":
            self.handle_delete_todo(parts[1])
            return
        # Even for errors, return JSON with Content-Type
        self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    # Specific endpoint implementations
    def handle_register(self) -> None:
        data, err = self.parse_json_body()
        if err is not None or data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_val = data.get("username")
        password_val = data.get("password")
        if not isinstance(username_val, str) or len(username_val) < 3 or len(username_val) > 50 or not USERNAME_RE.match(username_val):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_val, str) or len(password_val) < 8:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        user, create_err = STORE.create_user(username_val, password_val)
        if create_err is not None or user is None:
            self.send_error_json(HTTPStatus.CONFLICT, "Username already exists")
            return
        self.send_json(HTTPStatus.CREATED, user.to_public())

    def handle_login(self) -> None:
        data, err = self.parse_json_body()
        if err is not None or data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_val = data.get("username")
        password_val = data.get("password")
        if not isinstance(username_val, str) or not isinstance(password_val, str):
            # Treat as invalid credentials to avoid leaking info
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = STORE.authenticate(username_val, password_val)
        if user is None:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = STORE.create_session(user.id)
        headers = [("Set-Cookie", f"session_id={token}; Path=/; HttpOnly")]
        self.send_json(HTTPStatus.OK, user.to_public(), headers)

    def handle_logout(self) -> None:
        auth = self.require_auth()
        if auth is None:
            return
        _user, token = auth
        STORE.invalidate_session(token)
        self.send_json(HTTPStatus.OK, {})

    def handle_me(self) -> None:
        auth = self.require_auth()
        if auth is None:
            return
        user, _token = auth
        self.send_json(HTTPStatus.OK, user.to_public())

    def handle_change_password(self) -> None:
        auth = self.require_auth()
        if auth is None:
            return
        user, _token = auth
        data, err = self.parse_json_body()
        if err is not None or data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        old_pw = data.get("old_password")
        new_pw = data.get("new_password")
        if not isinstance(old_pw, str) or old_pw != user.password:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        STORE.change_password(user.id, new_pw)
        self.send_json(HTTPStatus.OK, {})

    def handle_list_todos(self) -> None:
        auth = self.require_auth()
        if auth is None:
            return
        user, _token = auth
        todos = STORE.list_todos_for_user(user.id)
        payload: List[Dict[str, object]] = [t.to_public() for t in todos]
        self.send_json(HTTPStatus.OK, payload)

    def handle_create_todo(self) -> None:
        auth = self.require_auth()
        if auth is None:
            return
        user, _token = auth
        data, err = self.parse_json_body()
        if err is not None or data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_val = data.get("title")
        desc_val: str = ""
        if "description" in data:
            dv = data.get("description")
            if isinstance(dv, str):
                desc_val = dv
            else:
                # Coerce non-string to string to avoid type issues; spec says string
                desc_val = ""
        if not isinstance(title_val, str) or title_val.strip() == "":
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        todo = STORE.create_todo(user.id, title_val, desc_val)
        self.send_json(HTTPStatus.CREATED, todo.to_public())

    def _parse_todo_id(self, part: str) -> Optional[int]:
        try:
            tid = int(part)
        except ValueError:
            return None
        if tid <= 0:
            return None
        return tid

    def handle_get_todo(self, todo_id_part: str) -> None:
        auth = self.require_auth()
        if auth is None:
            return
        user, _token = auth
        tid = self._parse_todo_id(todo_id_part)
        if tid is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = STORE.get_todo_for_user(user.id, tid)
        if todo is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self.send_json(HTTPStatus.OK, todo.to_public())

    def handle_update_todo(self, todo_id_part: str) -> None:
        auth = self.require_auth()
        if auth is None:
            return
        user, _token = auth
        tid = self._parse_todo_id(todo_id_part)
        if tid is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        # Ensure the todo exists and belongs to user first
        existing = STORE.get_todo_for_user(user.id, tid)
        if existing is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        data, err = self.parse_json_body()
        if err is not None or data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        new_title: Optional[str] = None
        new_desc: Optional[str] = None
        new_completed: Optional[bool] = None
        if "title" in data:
            tv = data.get("title")
            if not isinstance(tv, str) or tv.strip() == "":
                self.send_error_json(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            new_title = tv
        if "description" in data:
            dv = data.get("description")
            if isinstance(dv, str):
                new_desc = dv
            else:
                # If provided but not string, coerce to empty string
                new_desc = ""
        if "completed" in data:
            cv = data.get("completed")
            if isinstance(cv, bool):
                new_completed = cv
            else:
                # If provided but not bool, treat as invalid type -> we can coerce False or ignore? Spec does not say.
                # We'll coerce using truthiness: but safer to return 400? Spec does not define. We'll coerce False.
                new_completed = bool(cv)
        updated = STORE.update_todo(tid, title=new_title, description=new_desc, completed=new_completed)
        if updated is None:
            # Should not happen, but handle gracefully
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self.send_json(HTTPStatus.OK, updated.to_public())

    def handle_delete_todo(self, todo_id_part: str) -> None:
        auth = self.require_auth()
        if auth is None:
            return
        user, _token = auth
        tid = self._parse_todo_id(todo_id_part)
        if tid is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        # Verify ownership
        existing = STORE.get_todo_for_user(user.id, tid)
        if existing is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        # Perform delete
        STORE.delete_todo(tid)
        # Respond 204 with no body
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="In-memory Todo REST API server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)
    host = "0.0.0.0"
    port = args.port
    httpd = HTTPServer((host, port), TodoRequestHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
