#!/usr/bin/env python3
from __future__ import annotations

import argparse
import http.server
import json
import re
import sys
import threading
import time
import uuid
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from typing import Any, Dict, List, Mapping, MutableMapping, Optional, Tuple, Union, cast

JSONType = Union[None, bool, int, float, str, List["JSONType"], Dict[str, "JSONType"]]


def utc_now_iso() -> str:
    # Return ISO8601 UTC timestamp with seconds precision and trailing Z
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class User:
    id: int
    username: str
    password_hash: str

    def public(self) -> Dict[str, JSONType]:
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

    def to_json(self) -> Dict[str, JSONType]:
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
        self._users_by_id: Dict[int, User] = {}
        self._users_by_username: Dict[str, User] = {}
        self._next_user_id: int = 1

        self._todos_by_id: Dict[int, Todo] = {}
        self._next_todo_id: int = 1

        self._sessions: Dict[str, int] = {}

        self._lock = threading.Lock()

    # User management
    def create_user(self, username: str, password_hash: str) -> User:
        with self._lock:
            if username in self._users_by_username:
                raise ValueError("Username already exists")
            uid = self._next_user_id
            self._next_user_id += 1
            user = User(id=uid, username=username, password_hash=password_hash)
            self._users_by_id[uid] = user
            self._users_by_username[username] = user
            return user

    def get_user_by_username(self, username: str) -> Optional[User]:
        return self._users_by_username.get(username)

    def get_user_by_id(self, uid: int) -> Optional[User]:
        return self._users_by_id.get(uid)

    def set_user_password_hash(self, uid: int, password_hash: str) -> None:
        with self._lock:
            user = self._users_by_id.get(uid)
            if user is None:
                return
            user.password_hash = password_hash

    # Sessions
    def create_session(self, user_id: int) -> str:
        with self._lock:
            token = uuid.uuid4().hex
            self._sessions[token] = user_id
            return token

    def get_user_id_for_session(self, token: str) -> Optional[int]:
        return self._sessions.get(token)

    def invalidate_session(self, token: str) -> None:
        with self._lock:
            if token in self._sessions:
                del self._sessions[token]

    # Todos
    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        todos = [t for t in self._todos_by_id.values() if t.user_id == user_id]
        todos.sort(key=lambda t: t.id)
        return todos

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        with self._lock:
            tid = self._next_todo_id
            self._next_todo_id += 1
            now = utc_now_iso()
            todo = Todo(
                id=tid,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=now,
                updated_at=now,
            )
            self._todos_by_id[tid] = todo
            return todo

    def get_todo(self, todo_id: int) -> Optional[Todo]:
        return self._todos_by_id.get(todo_id)

    def update_todo(self, todo: Todo) -> None:
        # No action needed since object is mutable; included for clarity.
        return

    def delete_todo(self, todo_id: int) -> None:
        with self._lock:
            if todo_id in self._todos_by_id:
                del self._todos_by_id[todo_id]


STORE = InMemoryStore()


# Utilities

def hash_password(password: str) -> str:
    # Simple salted hash using uuid as salt per process; for in-memory app minimal hashing
    # Not security-grade, but avoids plain text storage as a courtesy.
    # For deterministic behavior within one run, fixed salt is fine.
    # We'll use a constant salt per process.
    return uuid.uuid5(uuid.NAMESPACE_OID, password).hex


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


class TodoRequestHandler(http.server.BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        # Keep default logging to stderr
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))

    # Helpers
    def _read_json(self) -> Union[Dict[str, JSONType], None]:
        length_str = self.headers.get("Content-Length")
        if length_str is None:
            data = b""
        else:
            try:
                length = int(length_str)
            except ValueError:
                self._send_json({"error": "Invalid Content-Length"}, HTTPStatus.BAD_REQUEST)
                return None
            data = self.rfile.read(length)
        try:
            text = data.decode("utf-8")
            if not text:
                return {}
            obj = json.loads(text)
            if not isinstance(obj, dict):
                self._send_json({"error": "Invalid JSON"}, HTTPStatus.BAD_REQUEST)
                return None
            return cast(Dict[str, JSONType], obj)
        except UnicodeDecodeError:
            self._send_json({"error": "Invalid JSON"}, HTTPStatus.BAD_REQUEST)
            return None
        except json.JSONDecodeError:
            self._send_json({"error": "Invalid JSON"}, HTTPStatus.BAD_REQUEST)
            return None

    def _parse_cookies(self) -> Mapping[str, str]:
        header = self.headers.get("Cookie")
        result: Dict[str, str] = {}
        if header is None:
            return result
        c = SimpleCookie()
        c.load(header)
        for key, morsel in c.items():
            result[key] = morsel.value
        return result

    def _require_auth(self) -> Optional[User]:
        cookies = self._parse_cookies()
        token = cookies.get("session_id")
        if token is None:
            self._send_json({"error": "Authentication required"}, HTTPStatus.UNAUTHORIZED)
            return None
        uid = STORE.get_user_id_for_session(token)
        if uid is None:
            self._send_json({"error": "Authentication required"}, HTTPStatus.UNAUTHORIZED)
            return None
        user = STORE.get_user_by_id(uid)
        if user is None:
            # Invalidate dangling session
            STORE.invalidate_session(token)
            self._send_json({"error": "Authentication required"}, HTTPStatus.UNAUTHORIZED)
            return None
        return user

    def _send_json(self, data: Dict[str, JSONType], status: HTTPStatus = HTTPStatus.OK, extra_headers: Optional[List[Tuple[str, str]]] = None, set_cookie: Optional[str] = None) -> None:
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if set_cookie is not None:
            self.send_header("Set-Cookie", set_cookie)
        if extra_headers:
            for k, v in extra_headers:
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _send_no_content(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        # No body, therefore do not set Content-Length intentionally (allowed for 204)
        # Also do not set Content-Type per spec.
        self.end_headers()

    # Routing
    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/register":
            self.handle_register()
            return
        if self.path == "/login":
            self.handle_login()
            return
        if self.path == "/logout":
            self.handle_logout()
            return
        if self.path == "/todos":
            self.handle_create_todo()
            return
        self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/me":
            self.handle_me()
            return
        if self.path == "/todos":
            self.handle_list_todos()
            return
        m = re.fullmatch(r"/todos/(\d+)", self.path)
        if m:
            self.handle_get_todo(int(m.group(1)))
            return
        self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def do_PUT(self) -> None:  # noqa: N802
        if self.path == "/password":
            self.handle_change_password()
            return
        m = re.fullmatch(r"/todos/(\d+)", self.path)
        if m:
            self.handle_update_todo(int(m.group(1)))
            return
        self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    def do_DELETE(self) -> None:  # noqa: N802
        m = re.fullmatch(r"/todos/(\d+)", self.path)
        if m:
            self.handle_delete_todo(int(m.group(1)))
            return
        self._send_json({"error": "Not found"}, HTTPStatus.NOT_FOUND)

    # Handlers
    def handle_register(self) -> None:
        data = self._read_json()
        if data is None:
            return
        username_val = data.get("username") if isinstance(data, dict) else None
        password_val = data.get("password") if isinstance(data, dict) else None
        if not isinstance(username_val, str) or not USERNAME_RE.fullmatch(username_val):
            self._send_json({"error": "Invalid username"}, HTTPStatus.BAD_REQUEST)
            return
        if not isinstance(password_val, str) or len(password_val) < 8:
            self._send_json({"error": "Password too short"}, HTTPStatus.BAD_REQUEST)
            return
        try:
            user = STORE.create_user(username_val, hash_password(password_val))
        except ValueError:
            self._send_json({"error": "Username already exists"}, HTTPStatus.CONFLICT)
            return
        self._send_json(user.public(), HTTPStatus.CREATED)

    def handle_login(self) -> None:
        data = self._read_json()
        if data is None:
            return
        username_val = data.get("username") if isinstance(data, dict) else None
        password_val = data.get("password") if isinstance(data, dict) else None
        if not isinstance(username_val, str) or not isinstance(password_val, str):
            self._send_json({"error": "Invalid credentials"}, HTTPStatus.UNAUTHORIZED)
            return
        user = STORE.get_user_by_username(username_val)
        if user is None or user.password_hash != hash_password(password_val):
            self._send_json({"error": "Invalid credentials"}, HTTPStatus.UNAUTHORIZED)
            return
        token = STORE.create_session(user.id)
        cookie = f"session_id={token}; Path=/; HttpOnly"
        self._send_json(user.public(), HTTPStatus.OK, set_cookie=cookie)

    def handle_logout(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        cookies = self._parse_cookies()
        token = cookies.get("session_id")
        if token is not None:
            STORE.invalidate_session(token)
        # Return empty JSON object
        self._send_json({}, HTTPStatus.OK)

    def handle_me(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        self._send_json(user.public(), HTTPStatus.OK)

    def handle_change_password(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        data = self._read_json()
        if data is None:
            return
        old_pw = data.get("old_password") if isinstance(data, dict) else None
        new_pw = data.get("new_password") if isinstance(data, dict) else None
        if not isinstance(old_pw, str) or hash_password(old_pw) != user.password_hash:
            self._send_json({"error": "Invalid credentials"}, HTTPStatus.UNAUTHORIZED)
            return
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            self._send_json({"error": "Password too short"}, HTTPStatus.BAD_REQUEST)
            return
        STORE.set_user_password_hash(user.id, hash_password(new_pw))
        self._send_json({}, HTTPStatus.OK)

    def handle_list_todos(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        todos = STORE.list_todos_for_user(user.id)
        self._send_json([t.to_json() for t in todos], HTTPStatus.OK)  # type: ignore[arg-type]

    def handle_create_todo(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        data = self._read_json()
        if data is None:
            return
        title_val = data.get("title") if isinstance(data, dict) else None
        description_val = data.get("description") if isinstance(data, dict) else None
        if not isinstance(title_val, str) or title_val == "":
            self._send_json({"error": "Title is required"}, HTTPStatus.BAD_REQUEST)
            return
        if description_val is None:
            desc = ""
        elif isinstance(description_val, str):
            desc = description_val
        else:
            self._send_json({"error": "Invalid request"}, HTTPStatus.BAD_REQUEST)
            return
        todo = STORE.create_todo(user.id, title_val, desc)
        self._send_json(todo.to_json(), HTTPStatus.CREATED)

    def _get_owned_todo(self, user: User, tid: int) -> Optional[Todo]:
        todo = STORE.get_todo(tid)
        if todo is None or todo.user_id != user.id:
            self._send_json({"error": "Todo not found"}, HTTPStatus.NOT_FOUND)
            return None
        return todo

    def handle_get_todo(self, tid: int) -> None:
        user = self._require_auth()
        if user is None:
            return
        todo = self._get_owned_todo(user, tid)
        if todo is None:
            return
        self._send_json(todo.to_json(), HTTPStatus.OK)

    def handle_update_todo(self, tid: int) -> None:
        user = self._require_auth()
        if user is None:
            return
        data = self._read_json()
        if data is None:
            return
        todo = self._get_owned_todo(user, tid)
        if todo is None:
            return
        # Partial update
        if "title" in data:
            val = data.get("title")
            if not isinstance(val, str) or val == "":
                self._send_json({"error": "Title is required"}, HTTPStatus.BAD_REQUEST)
                return
            todo.title = val
        if "description" in data:
            val2 = data.get("description")
            if not isinstance(val2, str):
                self._send_json({"error": "Invalid request"}, HTTPStatus.BAD_REQUEST)
                return
            todo.description = val2
        if "completed" in data:
            val3 = data.get("completed")
            if not isinstance(val3, bool):
                self._send_json({"error": "Invalid request"}, HTTPStatus.BAD_REQUEST)
                return
            todo.completed = val3
        todo.updated_at = utc_now_iso()
        STORE.update_todo(todo)
        self._send_json(todo.to_json(), HTTPStatus.OK)

    def handle_delete_todo(self, tid: int) -> None:
        user = self._require_auth()
        if user is None:
            return
        todo = STORE.get_todo(tid)
        if todo is None or todo.user_id != user.id:
            # Return 404 for both not found and not owned
            self._send_json({"error": "Todo not found"}, HTTPStatus.NOT_FOUND)
            return
        STORE.delete_todo(tid)
        self._send_no_content()


class ThreadedHTTPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True


def run_server(port: int) -> None:
    server_address: Tuple[str, int] = ("0.0.0.0", port)
    httpd = ThreadedHTTPServer(server_address, TodoRequestHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


def parse_args(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args_ns = parser.parse_args(argv)
    port = int(args_ns.port)
    if port <= 0 or port > 65535:
        raise SystemExit("Invalid port")
    return port


if __name__ == "__main__":
    port_number = parse_args(sys.argv[1:])
    run_server(port_number)
