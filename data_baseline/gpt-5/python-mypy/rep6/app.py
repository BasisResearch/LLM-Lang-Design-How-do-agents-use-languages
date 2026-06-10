from __future__ import annotations

import argparse
import json
import re
import threading
import uuid
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Mapping, MutableMapping, Optional, Tuple, cast
from urllib.parse import urlparse


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class User:
    id: int
    username: str


@dataclass
class TodoItem:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class Store:
    def __init__(self) -> None:
        self._lock: threading.Lock = threading.Lock()
        self.next_user_id: int = 1
        self.next_todo_id: int = 1
        self.users_by_id: Dict[int, User] = {}
        self.user_passwords: Dict[int, str] = {}
        self.username_to_id: Dict[str, int] = {}
        self.todos_by_id: Dict[int, TodoItem] = {}
        self.user_todo_ids: Dict[int, List[int]] = {}
        self.sessions: Dict[str, int] = {}

    # User management
    def create_user(self, username: str, password: str) -> User:
        with self._lock:
            if username in self.username_to_id:
                raise ValueError("username_exists")
            user_id = self.next_user_id
            self.next_user_id += 1
            user = User(id=user_id, username=username)
            self.users_by_id[user_id] = user
            self.user_passwords[user_id] = password
            self.username_to_id[username] = user_id
            return user

    def get_user_by_username(self, username: str) -> Optional[Tuple[User, str]]:
        with self._lock:
            uid = self.username_to_id.get(username)
            if uid is None:
                return None
            user = self.users_by_id[uid]
            pw = self.user_passwords[uid]
            return (user, pw)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        with self._lock:
            return self.users_by_id.get(user_id)

    def set_password(self, user_id: int, new_password: str) -> None:
        with self._lock:
            self.user_passwords[user_id] = new_password

    # Sessions
    def create_session(self, user_id: int) -> str:
        with self._lock:
            token = uuid.uuid4().hex
            self.sessions[token] = user_id
            return token

    def get_user_id_from_session(self, token: str) -> Optional[int]:
        with self._lock:
            return self.sessions.get(token)

    def invalidate_session(self, token: str) -> None:
        with self._lock:
            self.sessions.pop(token, None)

    # Todos
    def create_todo(self, user_id: int, title: str, description: str) -> TodoItem:
        with self._lock:
            tid = self.next_todo_id
            self.next_todo_id += 1
            now = now_iso()
            todo = TodoItem(
                id=tid,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=now,
                updated_at=now,
            )
            self.todos_by_id[tid] = todo
            self.user_todo_ids.setdefault(user_id, []).append(tid)
            return todo

    def list_todos_for_user(self, user_id: int) -> List[TodoItem]:
        with self._lock:
            ids = self.user_todo_ids.get(user_id, [])
            # Ensure ascending order by id
            ids_sorted = sorted(ids)
            return [self.todos_by_id[i] for i in ids_sorted]

    def get_todo_if_owned(self, todo_id: int, user_id: int) -> Optional[TodoItem]:
        with self._lock:
            todo = self.todos_by_id.get(todo_id)
            if todo is None:
                return None
            if todo.user_id != user_id:
                return None
            return todo

    def update_todo(self, todo: TodoItem, update: Mapping[str, Any]) -> TodoItem:
        with self._lock:
            changed = False
            if "title" in update:
                todo.title = cast(str, update["title"])  # validated by caller
                changed = True
            if "description" in update:
                todo.description = cast(str, update["description"])  # validated by caller
                changed = True
            if "completed" in update:
                todo.completed = cast(bool, update["completed"])  # validated by caller
                changed = True
            if changed:
                todo.updated_at = now_iso()
            return todo

    def delete_todo(self, todo_id: int, user_id: int) -> bool:
        with self._lock:
            todo = self.todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return False
            del self.todos_by_id[todo_id]
            lst = self.user_todo_ids.get(user_id)
            if lst is not None:
                try:
                    lst.remove(todo_id)
                except ValueError:
                    pass
            return True


class TodoHTTPRequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoHTTP/1.0"

    # Ensure we don't write default HTML error pages
    def log_message(self, format: str, *args: object) -> None:  # noqa: A003 - override
        # Keep server quiet or could print to stderr; acceptable but keep minimal
        super().log_message(format, *args)

    @property
    def store(self) -> Store:
        srv = cast(HTTPServer, self.server)
        st = cast(Store, getattr(srv, "store"))
        return st

    def do_POST(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        path = urlparse(self.path).path
        if path == "/register":
            self.handle_register()
        elif path == "/login":
            self.handle_login()
        elif path == "/logout":
            self.require_auth_and(self.handle_logout)
        elif path == "/todos":
            self.require_auth_and(self.handle_create_todo)
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/me":
            self.require_auth_and(self.handle_me)
        elif path == "/todos":
            self.require_auth_and(self.handle_list_todos)
        elif path.startswith("/todos/"):
            self.require_auth_and(lambda uid, token: self.handle_get_todo(uid))
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/password":
            self.require_auth_and(self.handle_change_password)
        elif path.startswith("/todos/"):
            self.require_auth_and(lambda uid, token: self.handle_update_todo(uid))
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path.startswith("/todos/"):
            self.require_auth_and(lambda uid, token: self.handle_delete_todo(uid))
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    # Utilities
    def parse_json_body(self) -> Optional[Dict[str, Any]]:
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
            if not raw:
                return {}
            data = json.loads(raw.decode("utf-8"))
            if isinstance(data, dict):
                # Return as Dict[str, Any]
                return dict(data)
            else:
                return None
        except json.JSONDecodeError:
            return None

    def send_json(self, status: int, obj: Mapping[str, Any] | List[Mapping[str, Any]] | List[Any], set_cookie: Optional[str] = None) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        if set_cookie is not None:
            self.send_header("Set-Cookie", set_cookie)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status: HTTPStatus, message: str) -> None:
        self.send_json(int(status), {"error": message})

    def parse_cookies(self) -> Dict[str, str]:
        header = self.headers.get("Cookie")
        result: Dict[str, str] = {}
        if not header:
            return result
        parts = [p.strip() for p in header.split(";")]
        for part in parts:
            if "=" in part:
                k, v = part.split("=", 1)
                result[k.strip()] = v.strip()
        return result

    def get_auth(self) -> Optional[Tuple[int, str]]:
        cookies = self.parse_cookies()
        token = cookies.get("session_id")
        if token is None:
            return None
        uid = self.store.get_user_id_from_session(token)
        if uid is None:
            return None
        return (uid, token)

    def require_auth_and(self, func: "CallableWithAuth") -> None:
        auth = self.get_auth()
        if auth is None:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return
        uid, token = auth
        func(uid, token)

    # Handlers
    def handle_register(self) -> None:
        data = self.parse_json_body()
        if data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_val = data.get("username")
        password_val = data.get("password")
        if not isinstance(username_val, str) or not USERNAME_RE.match(username_val):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_val, str):
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        if len(password_val) < 8:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        try:
            user = self.store.create_user(username_val, password_val)
        except ValueError as e:
            if str(e) == "username_exists":
                self.send_error_json(HTTPStatus.CONFLICT, "Username already exists")
                return
            raise
        self.send_json(HTTPStatus.CREATED, asdict(user))

    def handle_login(self) -> None:
        data = self.parse_json_body()
        if data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_val = data.get("username")
        password_val = data.get("password")
        if not isinstance(username_val, str) or not isinstance(password_val, str):
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        up = self.store.get_user_by_username(username_val)
        if up is None:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user, pw = up
        if password_val != pw:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = self.store.create_session(user.id)
        cookie = f"session_id={token}; Path=/; HttpOnly"
        self.send_json(HTTPStatus.OK, asdict(user), set_cookie=cookie)

    def handle_logout(self, user_id: int, token: str) -> None:  # noqa: ARG002 - user_id unused
        # Invalidate the token
        self.store.invalidate_session(token)
        self.send_json(HTTPStatus.OK, {})

    def handle_me(self, user_id: int, token: str) -> None:  # noqa: ARG002 - token unused
        user = self.store.get_user_by_id(user_id)
        if user is None:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return
        self.send_json(HTTPStatus.OK, asdict(user))

    def handle_change_password(self, user_id: int, token: str) -> None:  # noqa: ARG002 - token unused
        data = self.parse_json_body()
        if data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        old_pw = data.get("old_password")
        new_pw = data.get("new_password")
        if not isinstance(old_pw, str):
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        stored_pw = self.store.user_passwords.get(user_id)
        if stored_pw is None or old_pw != stored_pw:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        self.store.set_password(user_id, new_pw)
        self.send_json(HTTPStatus.OK, {})

    def handle_list_todos(self, user_id: int, token: str) -> None:  # noqa: ARG002 - token unused
        todos = self.store.list_todos_for_user(user_id)
        self.send_json(HTTPStatus.OK, [self.todo_to_public(t) for t in todos])

    def handle_create_todo(self, user_id: int, token: str) -> None:  # noqa: ARG002 - token unused
        data = self.parse_json_body()
        if data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_val = data.get("title")
        description_val = data.get("description", "")
        if not isinstance(title_val, str) or title_val.strip() == "":
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        if not isinstance(description_val, str):
            description_val = ""
        todo = self.store.create_todo(user_id, title_val, description_val)
        self.send_json(HTTPStatus.CREATED, self.todo_to_public(todo))

    def extract_todo_id(self) -> Optional[int]:
        path = urlparse(self.path).path
        parts = path.strip("/").split("/")
        if len(parts) == 2 and parts[0] == "todos":
            try:
                return int(parts[1])
            except ValueError:
                return None
        return None

    def handle_get_todo(self, user_id: int) -> None:
        tid = self.extract_todo_id()
        if tid is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = self.store.get_todo_if_owned(tid, user_id)
        if todo is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self.send_json(HTTPStatus.OK, self.todo_to_public(todo))

    def handle_update_todo(self, user_id: int) -> None:
        tid = self.extract_todo_id()
        if tid is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = self.store.get_todo_if_owned(tid, user_id)
        if todo is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        data = self.parse_json_body()
        if data is None:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        update: Dict[str, Any] = {}
        if "title" in data:
            val = data.get("title")
            if not isinstance(val, str) or val.strip() == "":
                self.send_error_json(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            update["title"] = val
        if "description" in data:
            val2 = data.get("description")
            if isinstance(val2, str):
                update["description"] = val2
        if "completed" in data:
            val3 = data.get("completed")
            if isinstance(val3, bool):
                update["completed"] = val3
        updated = self.store.update_todo(todo, update)
        self.send_json(HTTPStatus.OK, self.todo_to_public(updated))

    def handle_delete_todo(self, user_id: int) -> None:
        tid = self.extract_todo_id()
        if tid is None:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        ok = self.store.delete_todo(tid, user_id)
        if not ok:
            self.send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        # 204 No Content, no body and no Content-Type
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    @staticmethod
    def todo_to_public(todo: TodoItem) -> Dict[str, Any]:
        # exclude user_id
        return {
            "id": todo.id,
            "title": todo.title,
            "description": todo.description,
            "completed": todo.completed,
            "created_at": todo.created_at,
            "updated_at": todo.updated_at,
        }


# Type alias for auth-required callbacks
from typing import Callable  # placed after handler class to avoid circular ref in type checking
CallableWithAuth = Callable[[int, str], None]


def run_server(port: int) -> None:
    server_address = ("0.0.0.0", port)
    httpd: HTTPServer = HTTPServer(server_address, TodoHTTPRequestHandler)
    # Attach store
    setattr(httpd, "store", Store())
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
