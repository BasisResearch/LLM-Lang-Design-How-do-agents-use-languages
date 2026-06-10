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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Mapping, MutableMapping, Optional, Tuple, TypeAlias, Union, cast
import hashlib
import os
import hmac

# JSON type aliases
JSONPrimitive = Union[str, int, float, bool, None]
JSONValue = Union[JSONPrimitive, List["JSONValue"], Dict[str, "JSONValue"]]
JSONObject = Dict[str, JSONValue]


@dataclass
class User:
    id: int
    username: str
    password_hash: str  # stored as salt_hex:hash_hex


@dataclass
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class AppState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.users_by_id: Dict[int, User] = {}
        self.users_by_username: Dict[str, User] = {}
        self.next_user_id: int = 1

        self.todos_by_id: Dict[int, Todo] = {}
        self.next_todo_id: int = 1

        # session_id token -> user_id
        self.sessions: Dict[str, int] = {}

    def create_user(self, username: str, password: str) -> User:
        with self._lock:
            if username in self.users_by_username:
                raise ValueError("username_exists")
            user_id = self.next_user_id
            self.next_user_id += 1
            password_hash = hash_password(password)
            user = User(id=user_id, username=username, password_hash=password_hash)
            self.users_by_id[user_id] = user
            self.users_by_username[username] = user
            return user

    def find_user_by_username(self, username: str) -> Optional[User]:
        with self._lock:
            return self.users_by_username.get(username)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        with self._lock:
            return self.users_by_id.get(user_id)

    def set_user_password(self, user_id: int, new_password: str) -> None:
        with self._lock:
            user = self.users_by_id.get(user_id)
            if not user:
                return
            user.password_hash = hash_password(new_password)

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        with self._lock:
            todo_id = self.next_todo_id
            self.next_todo_id += 1
            now = current_timestamp()
            todo = Todo(
                id=todo_id,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=now,
                updated_at=now,
            )
            self.todos_by_id[todo_id] = todo
            return todo

    def get_user_todos(self, user_id: int) -> List[Todo]:
        with self._lock:
            todos = [t for t in self.todos_by_id.values() if t.user_id == user_id]
            todos.sort(key=lambda t: t.id)
            return list(todos)

    def get_todo(self, todo_id: int) -> Optional[Todo]:
        with self._lock:
            return self.todos_by_id.get(todo_id)

    def update_todo(self, todo_id: int, *, title: Optional[str] = None, description: Optional[str] = None, completed: Optional[bool] = None) -> Optional[Todo]:
        with self._lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo:
                return None
            if title is not None:
                todo.title = title
            if description is not None:
                todo.description = description
            if completed is not None:
                todo.completed = completed
            todo.updated_at = current_timestamp()
            return todo

    def delete_todo(self, todo_id: int) -> bool:
        with self._lock:
            if todo_id in self.todos_by_id:
                del self.todos_by_id[todo_id]
                return True
            return False

    def create_session(self, user_id: int) -> str:
        with self._lock:
            token = uuid.uuid4().hex
            self.sessions[token] = user_id
            return token

    def invalidate_session(self, token: str) -> None:
        with self._lock:
            if token in self.sessions:
                del self.sessions[token]

    def get_user_id_by_session(self, token: str) -> Optional[int]:
        with self._lock:
            return self.sessions.get(token)


STATE = AppState()


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def current_timestamp() -> str:
    # ISO 8601 UTC with second precision, ending with Z
    dt = datetime.now(timezone.utc)
    return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def hash_password(password: str) -> str:
    # Strong enough for in-memory usage; not for production.
    salt = os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100_000)
    return f"{salt.hex()}:{dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        salt_hex, hash_hex = stored.split(":", 1)
    except ValueError:
        return False
    salt = bytes.fromhex(salt_hex)
    expected = bytes.fromhex(hash_hex)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100_000)
    # constant-time compare
    return bool(hmac.compare_digest(dk, expected))


class TodoHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    # Helpers
    def _read_json(self) -> Tuple[Optional[JSONObject], Optional[Tuple[int, JSONObject]]]:
        try:
            length_str = self.headers.get("Content-Length")
            if not length_str:
                return {}, None
            length = int(length_str)
            if length <= 0:
                return {}, None
            data = self.rfile.read(length)
            obj = json.loads(data.decode("utf-8"))
            if not isinstance(obj, dict):
                return None, (HTTPStatus.BAD_REQUEST, {"error": "Invalid JSON"})
            # Ensure values are JSON-compatible by casting
            return cast(JSONObject, obj), None
        except Exception:
            return None, (HTTPStatus.BAD_REQUEST, {"error": "Invalid JSON"})

    def _send_json(self, status: int, obj: JSONValue, set_cookie: Optional[str] = None) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if set_cookie is not None:
            self.send_header("Set-Cookie", set_cookie)
        self.end_headers()
        self.wfile.write(body)

    def _send_204(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    def _error(self, status: int, message: str) -> None:
        self._send_json(status, {"error": message})

    def _parse_path(self) -> List[str]:
        # Remove query string
        path = self.path.split("?", 1)[0]
        parts = [p for p in path.split("/") if p]
        return parts

    def _get_cookie(self, name: str) -> Optional[str]:
        cookie_header = self.headers.get("Cookie")
        if not cookie_header:
            return None
        parts = [p.strip() for p in cookie_header.split(";")]
        for part in parts:
            if "=" in part:
                k, v = part.split("=", 1)
                if k.strip() == name:
                    return v.strip()
        return None

    def _require_auth(self) -> Optional[User]:
        token = self._get_cookie("session_id")
        if not token:
            self._error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        user_id = STATE.get_user_id_by_session(token)
        if user_id is None:
            self._error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        user = STATE.get_user_by_id(user_id)
        if user is None:
            self._error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        return user

    # Method handlers
    def do_POST(self) -> None:  # noqa: N802 (method name by BaseHTTPRequestHandler)
        parts = self._parse_path()
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
        self._error(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:  # noqa: N802
        parts = self._parse_path()
        if parts == ["me"]:
            self.handle_me()
            return
        if parts == ["todos"]:
            self.handle_list_todos()
            return
        if len(parts) == 2 and parts[0] == "todos":
            self.handle_get_todo(parts[1])
            return
        self._error(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802
        parts = self._parse_path()
        if parts == ["password"]:
            self.handle_change_password()
            return
        if len(parts) == 2 and parts[0] == "todos":
            self.handle_update_todo(parts[1])
            return
        self._error(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802
        parts = self._parse_path()
        if len(parts) == 2 and parts[0] == "todos":
            self.handle_delete_todo(parts[1])
            return
        self._error(HTTPStatus.NOT_FOUND, "Not found")

    # Endpoint handlers
    def handle_register(self) -> None:
        data, err = self._read_json()
        if err is not None:
            status, obj = err
            self._send_json(status, obj)
            return
        username_raw = data.get("username") if data is not None else None
        password_raw = data.get("password") if data is not None else None
        if not isinstance(username_raw, str) or not USERNAME_RE.fullmatch(username_raw):
            self._error(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_raw, str) or len(password_raw) < 8:
            self._error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        try:
            user = STATE.create_user(username_raw, password_raw)
        except ValueError:
            self._error(HTTPStatus.CONFLICT, "Username already exists")
            return
        self._send_json(HTTPStatus.CREATED, {"id": user.id, "username": user.username})

    def handle_login(self) -> None:
        data, err = self._read_json()
        if err is not None:
            status, obj = err
            self._send_json(status, obj)
            return
        username_raw = data.get("username") if data is not None else None
        password_raw = data.get("password") if data is not None else None
        if not isinstance(username_raw, str) or not isinstance(password_raw, str):
            self._error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = STATE.find_user_by_username(username_raw)
        if user is None or not verify_password(password_raw, user.password_hash):
            self._error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = STATE.create_session(user.id)
        set_cookie = f"session_id={token}; Path=/; HttpOnly"
        self._send_json(HTTPStatus.OK, {"id": user.id, "username": user.username}, set_cookie=set_cookie)

    def handle_logout(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        # Invalidate current session
        token = self._get_cookie("session_id")
        if token is not None:
            STATE.invalidate_session(token)
        self._send_json(HTTPStatus.OK, {})

    def handle_me(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        self._send_json(HTTPStatus.OK, {"id": user.id, "username": user.username})

    def handle_change_password(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        data, err = self._read_json()
        if err is not None:
            status, obj = err
            self._send_json(status, obj)
            return
        old_pw = data.get("old_password") if data is not None else None
        new_pw = data.get("new_password") if data is not None else None
        if not isinstance(old_pw, str) or not verify_password(old_pw, user.password_hash):
            self._error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            self._error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        STATE.set_user_password(user.id, new_pw)
        self._send_json(HTTPStatus.OK, {})

    def handle_list_todos(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        todos = STATE.get_user_todos(user.id)
        arr: List[JSONValue] = []
        for t in todos:
            arr.append(cast(JSONValue, todo_to_json(t)))
        self._send_json(HTTPStatus.OK, arr)

    def handle_create_todo(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        data, err = self._read_json()
        if err is not None:
            status, obj = err
            self._send_json(status, obj)
            return
        title_raw = data.get("title") if data is not None else None
        description_raw = data.get("description") if data is not None else None
        if not isinstance(title_raw, str) or title_raw.strip() == "":
            self._error(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        description: str
        if description_raw is None:
            description = ""
        elif isinstance(description_raw, str):
            description = description_raw
        else:
            self._error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        todo = STATE.create_todo(user.id, title_raw, description)
        self._send_json(HTTPStatus.CREATED, todo_to_json(todo))

    def _get_todo_for_user(self, user: User, todo_id_str: str) -> Optional[Todo]:
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            return None
        todo = STATE.get_todo(todo_id)
        if todo is None or todo.user_id != user.id:
            return None
        return todo

    def handle_get_todo(self, todo_id_str: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        todo = self._get_todo_for_user(user, todo_id_str)
        if todo is None:
            self._error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self._send_json(HTTPStatus.OK, todo_to_json(todo))

    def handle_update_todo(self, todo_id_str: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self._error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = STATE.get_todo(todo_id)
        if todo is None or todo.user_id != user.id:
            self._error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        data, err = self._read_json()
        if err is not None:
            status, obj = err
            self._send_json(status, obj)
            return
        assert data is not None
        title_present = "title" in data
        desc_present = "description" in data
        completed_present = "completed" in data

        title_val: Optional[str] = None
        desc_val: Optional[str] = None
        completed_val: Optional[bool] = None

        if title_present:
            title_field = data.get("title")
            if not isinstance(title_field, str) or title_field.strip() == "":
                self._error(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            title_val = title_field
        if desc_present:
            desc_field = data.get("description")
            if isinstance(desc_field, str):
                desc_val = desc_field
            else:
                self._error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
        if completed_present:
            comp_field = data.get("completed")
            if isinstance(comp_field, bool):
                completed_val = comp_field
            else:
                self._error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
        updated = STATE.update_todo(todo.id, title=title_val, description=desc_val, completed=completed_val)
        assert updated is not None
        self._send_json(HTTPStatus.OK, todo_to_json(updated))

    def handle_delete_todo(self, todo_id_str: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self._error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = STATE.get_todo(todo_id)
        if todo is None or todo.user_id != user.id:
            self._error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        STATE.delete_todo(todo.id)
        self._send_204()

    # Ensure that all responses default to JSON content type where applicable
    def log_message(self, format: str, *args: object) -> None:  # noqa: A003 - allow shadowing built-in 'format'
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], datetime.now().strftime("%d/%b/%Y %H:%M:%S"), format % args))


def todo_to_json(todo: Todo) -> JSONObject:
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at,
    }


def run_server(port: int) -> None:
    server = ThreadingHTTPServer(("0.0.0.0", port), TodoHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()
    run_server(args.port)


if __name__ == "__main__":
    main()
