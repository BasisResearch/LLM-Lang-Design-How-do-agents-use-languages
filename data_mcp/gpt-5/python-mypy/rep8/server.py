#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Mapping, MutableMapping, Optional, Tuple, cast
import uuid
from urllib.parse import urlparse

JsonDict = Dict[str, Any]


def utc_now_iso8601() -> str:
    # Second precision, UTC with trailing Z
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


@dataclass
class User:
    id: int
    username: str
    password_hash: str


@dataclass
class Todo:
    id: int
    owner_user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class AppState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.next_user_id: int = 1
        self.next_todo_id: int = 1
        self.users_by_id: Dict[int, User] = {}
        self.user_id_by_username: Dict[str, int] = {}
        self.sessions: Dict[str, int] = {}
        self.todos_by_id: Dict[int, Todo] = {}

    # Utilities protected by lock where mutation occurs
    def create_user(self, username: str, password: str) -> User:
        with self._lock:
            if username in self.user_id_by_username:
                raise ValueError("Username already exists")
            uid = self.next_user_id
            self.next_user_id += 1
            user = User(id=uid, username=username, password_hash=self._hash_pw(password))
            self.users_by_id[uid] = user
            self.user_id_by_username[username] = uid
            return user

    def get_user_by_username(self, username: str) -> Optional[User]:
        with self._lock:
            uid = self.user_id_by_username.get(username)
            if uid is None:
                return None
            return self.users_by_id.get(uid)

    def verify_password(self, user: User, password: str) -> bool:
        return user.password_hash == self._hash_pw(password)

    def change_password(self, user_id: int, new_password: str) -> None:
        with self._lock:
            user = self.users_by_id[user_id]
            user.password_hash = self._hash_pw(new_password)

    def create_session(self, user_id: int) -> str:
        token = uuid.uuid4().hex
        with self._lock:
            self.sessions[token] = user_id
        return token

    def delete_session(self, token: str) -> None:
        with self._lock:
            if token in self.sessions:
                del self.sessions[token]

    def get_user_by_session(self, token: str) -> Optional[User]:
        with self._lock:
            uid = self.sessions.get(token)
            if uid is None:
                return None
            return self.users_by_id.get(uid)

    def create_todo(self, owner_user_id: int, title: str, description: str) -> Todo:
        now = utc_now_iso8601()
        with self._lock:
            tid = self.next_todo_id
            self.next_todo_id += 1
            todo = Todo(
                id=tid,
                owner_user_id=owner_user_id,
                title=title,
                description=description,
                completed=False,
                created_at=now,
                updated_at=now,
            )
            self.todos_by_id[tid] = todo
            return todo

    def list_todos_for_user(self, owner_user_id: int) -> List[Todo]:
        with self._lock:
            items = [t for t in self.todos_by_id.values() if t.owner_user_id == owner_user_id]
            items.sort(key=lambda t: t.id)
            return list(items)

    def get_todo_for_user(self, owner_user_id: int, todo_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self.todos_by_id.get(todo_id)
            if todo is None or todo.owner_user_id != owner_user_id:
                return None
            return todo

    def update_todo(self, todo_id: int, *, title: Optional[str], description: Optional[str], completed: Optional[bool]) -> Optional[Todo]:
        with self._lock:
            todo = self.todos_by_id.get(todo_id)
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
                todo.updated_at = utc_now_iso8601()
            return todo

    def delete_todo(self, todo_id: int) -> bool:
        with self._lock:
            if todo_id in self.todos_by_id:
                del self.todos_by_id[todo_id]
                return True
            return False

    @staticmethod
    def _hash_pw(pw: str) -> str:
        # Lightweight hash for demonstration. Not secure for production.
        import hashlib

        return hashlib.sha256(pw.encode("utf-8")).hexdigest()


class TodoHandler(BaseHTTPRequestHandler):
    # Override to prevent default logging to stderr; we will keep it minimal for tests
    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003 - shadow builtin name allowed here
        return

    @property
    def state(self) -> AppState:
        server = cast(TypedHTTPServer, self.server)
        return server.state

    def do_POST(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        path = urlparse(self.path).path
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
        path = urlparse(self.path).path
        if path == "/me":
            self.handle_me()
            return
        if path == "/todos":
            self.handle_list_todos()
            return
        if path.startswith("/todos/"):
            self.handle_get_todo_by_id(path)
            return
        self.send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/password":
            self.handle_change_password()
            return
        if path.startswith("/todos/"):
            self.handle_update_todo(path)
            return
        self.send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path.startswith("/todos/"):
            self.handle_delete_todo(path)
            return
        # For non-existing endpoint, still JSON error as per general rule (DELETE success is only one without body)
        self.send_json_error(HTTPStatus.NOT_FOUND, "Not found")

    # Handlers
    def handle_register(self) -> None:
        data = self.read_json_body()
        if data is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_v = data.get("username")
        password_v = data.get("password")
        if not isinstance(username_v, str) or not USERNAME_RE.fullmatch(username_v):
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_v, str) or len(password_v) < 8:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        try:
            user = self.state.create_user(username_v, password_v)
        except ValueError:
            self.send_json_error(HTTPStatus.CONFLICT, "Username already exists")
            return
        self.send_json(HTTPStatus.CREATED, {"id": user.id, "username": user.username})

    def handle_login(self) -> None:
        data = self.read_json_body()
        if data is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_v = data.get("username")
        password_v = data.get("password")
        if not isinstance(username_v, str) or not isinstance(password_v, str):
            self.send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = self.state.get_user_by_username(username_v)
        if user is None or not self.state.verify_password(user, password_v):
            self.send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = self.state.create_session(user.id)
        headers = {"Set-Cookie": f"session_id={token}; Path=/; HttpOnly"}
        self.send_json(HTTPStatus.OK, {"id": user.id, "username": user.username}, extra_headers=headers)

    def handle_logout(self) -> None:
        user, token = self.require_auth()
        if user is None:
            return
        # Invalidate the session
        assert token is not None
        self.state.delete_session(token)
        self.send_json(HTTPStatus.OK, {})

    def handle_me(self) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        self.send_json(HTTPStatus.OK, {"id": user.id, "username": user.username})

    def handle_change_password(self) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        data = self.read_json_body()
        if data is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        old_pw = data.get("old_password")
        new_pw = data.get("new_password")
        if not isinstance(old_pw, str) or not self.state.verify_password(user, old_pw):
            self.send_json_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        self.state.change_password(user.id, new_pw)
        self.send_json(HTTPStatus.OK, {})

    def handle_list_todos(self) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        todos = self.state.list_todos_for_user(user.id)
        self.send_json(HTTPStatus.OK, [self.todo_to_json(t) for t in todos])

    def handle_create_todo(self) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        data = self.read_json_body()
        if data is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_v = data.get("title")
        description_v = data.get("description", "")
        if not isinstance(title_v, str) or title_v.strip() == "":
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        if not isinstance(description_v, str):
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        todo = self.state.create_todo(user.id, title_v, description_v)
        self.send_json(HTTPStatus.CREATED, self.todo_to_json(todo))

    def handle_get_todo_by_id(self, path: str) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        todo_id = self.parse_id_from_path(path)
        if todo_id is None:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = self.state.get_todo_for_user(user.id, todo_id)
        if todo is None:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self.send_json(HTTPStatus.OK, self.todo_to_json(todo))

    def handle_update_todo(self, path: str) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        todo_id = self.parse_id_from_path(path)
        if todo_id is None:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        # Ensure belongs to user
        todo = self.state.get_todo_for_user(user.id, todo_id)
        if todo is None:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        data = self.read_json_body()
        if data is None:
            self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_present = "title" in data
        desc_present = "description" in data
        comp_present = "completed" in data

        title_v: Optional[str] = None
        description_v: Optional[str] = None
        completed_v: Optional[bool] = None

        if title_present:
            v = data.get("title")
            if not isinstance(v, str) or v.strip() == "":
                self.send_json_error(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            title_v = v
        if desc_present:
            v2 = data.get("description")
            if not isinstance(v2, str):
                self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            description_v = v2
        if comp_present:
            v3 = data.get("completed")
            if not isinstance(v3, bool):
                self.send_json_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            completed_v = v3

        updated = self.state.update_todo(todo_id, title=title_v, description=description_v, completed=completed_v)
        assert updated is not None
        self.send_json(HTTPStatus.OK, self.todo_to_json(updated))

    def handle_delete_todo(self, path: str) -> None:
        user, _ = self.require_auth()
        if user is None:
            return
        todo_id = self.parse_id_from_path(path)
        if todo_id is None:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        # Check ownership
        todo = self.state.get_todo_for_user(user.id, todo_id)
        if todo is None:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        ok = self.state.delete_todo(todo_id)
        if ok:
            # 204 No Content, no body and no Content-Type header
            self.send_response(HTTPStatus.NO_CONTENT)
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_json_error(HTTPStatus.NOT_FOUND, "Todo not found")

    # Helpers
    def todo_to_json(self, t: Todo) -> JsonDict:
        return {
            "id": t.id,
            "title": t.title,
            "description": t.description,
            "completed": t.completed,
            "created_at": t.created_at,
            "updated_at": t.updated_at,
        }

    def parse_id_from_path(self, path: str) -> Optional[int]:
        parts = path.strip("/").split("/")
        if len(parts) != 2:
            return None
        try:
            return int(parts[1])
        except ValueError:
            return None

    def parse_cookies(self) -> Dict[str, str]:
        raw = self.headers.get("Cookie")
        result: Dict[str, str] = {}
        if not raw:
            return result
        # Cookie header: key1=value1; key2=value2
        pairs = [p.strip() for p in raw.split(";") if p.strip()]
        for pair in pairs:
            if "=" in pair:
                k, v = pair.split("=", 1)
                result[k.strip()] = v.strip()
        return result

    def require_auth(self) -> Tuple[Optional[User], Optional[str]]:
        cookies = self.parse_cookies()
        token = cookies.get("session_id")
        if token is None:
            self.send_json_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None, None
        user = self.state.get_user_by_session(token)
        if user is None:
            self.send_json_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None, token
        return user, token

    def read_json_body(self) -> Optional[JsonDict]:
        length_str = self.headers.get("Content-Length")
        if length_str is None:
            return {}
        try:
            length = int(length_str)
        except ValueError:
            return None
        try:
            raw = self.rfile.read(length)
        except Exception:
            return None
        try:
            val = json.loads(raw.decode("utf-8"))
        except Exception:
            return None
        if isinstance(val, dict):
            return cast(JsonDict, val)
        else:
            return None

    def send_json(self, status: HTTPStatus, payload: Any, *, extra_headers: Optional[Mapping[str, str]] = None) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_json_error(self, status: HTTPStatus, message: str) -> None:
        self.send_json(status, {"error": message})


class TypedHTTPServer(HTTPServer):
    def __init__(self, server_address: Tuple[str, int], RequestHandlerClass: type[BaseHTTPRequestHandler], state: AppState) -> None:  # noqa: N803
        super().__init__(server_address, RequestHandlerClass)
        self.state = state


def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()
    port = args.port

    state = AppState()
    server = TypedHTTPServer(("0.0.0.0", port), TodoHandler, state)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
