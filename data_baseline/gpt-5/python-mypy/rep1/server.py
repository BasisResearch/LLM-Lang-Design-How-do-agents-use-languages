from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie, Morsel
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Mapping, MutableMapping, Optional, Tuple, Union, cast
import threading
import secrets


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def now_iso() -> str:
    dt = datetime.now(timezone.utc).replace(microsecond=0)
    # Ensure trailing Z
    iso = dt.isoformat()
    if iso.endswith("+00:00"):
        iso = iso[:-6] + "Z"
    return iso


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


class AppState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._users_by_id: Dict[int, User] = {}
        self._users_by_username: Dict[str, User] = {}
        self._next_user_id: int = 1

        self._sessions: Dict[str, int] = {}

        self._todos_by_id: Dict[int, Todo] = {}
        self._next_todo_id: int = 1

    # User management
    def create_user(self, username: str, password: str) -> Tuple[Optional[User], Optional[str]]:
        if not USERNAME_RE.match(username):
            return None, "Invalid username"
        if len(password) < 8:
            return None, "Password too short"
        with self._lock:
            if username in self._users_by_username:
                return None, "Username already exists"
            uid = self._next_user_id
            self._next_user_id += 1
            user = User(id=uid, username=username, password_hash=self._hash_pw(password))
            self._users_by_id[uid] = user
            self._users_by_username[username] = user
            return user, None

    def authenticate(self, username: str, password: str) -> Optional[User]:
        with self._lock:
            user = self._users_by_username.get(username)
            if user is None:
                return None
            if user.password_hash != self._hash_pw(password):
                return None
            return user

    def change_password(self, user_id: int, old_password: str, new_password: str) -> Tuple[bool, Optional[str]]:
        if len(new_password) < 8:
            return False, "Password too short"
        with self._lock:
            user = self._users_by_id.get(user_id)
            if user is None:
                # Should not happen
                return False, "Invalid credentials"
            if user.password_hash != self._hash_pw(old_password):
                return False, "Invalid credentials"
            user.password_hash = self._hash_pw(new_password)
            return True, None

    # Sessions
    def create_session(self, user_id: int) -> str:
        token = secrets.token_hex(32)
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

    # Todos
    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        now = now_iso()
        with self._lock:
            tid = self._next_todo_id
            self._next_todo_id += 1
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

    def get_todo_for_user(self, todo_id: int, user_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None:
                return None
            if todo.user_id != user_id:
                return None
            return todo

    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        with self._lock:
            items = [t for t in self._todos_by_id.values() if t.user_id == user_id]
            items.sort(key=lambda t: t.id)
            return list(items)

    def update_todo(self, todo: Todo, title: Optional[str], description: Optional[str], completed: Optional[bool]) -> Todo:
        with self._lock:
            if title is not None:
                todo.title = title
            if description is not None:
                todo.description = description
            if completed is not None:
                todo.completed = completed
            todo.updated_at = now_iso()
            return todo

    def delete_todo(self, todo_id: int) -> None:
        with self._lock:
            if todo_id in self._todos_by_id:
                del self._todos_by_id[todo_id]

    @staticmethod
    def _hash_pw(pw: str) -> str:
        # For in-memory demo purposes; not intended for production security
        import hashlib

        return hashlib.sha256(pw.encode("utf-8")).hexdigest()


def user_to_public(user: User) -> Dict[str, Union[int, str]]:
    return {"id": user.id, "username": user.username}


def todo_to_public(todo: Todo) -> Dict[str, Union[int, str, bool]]:
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at,
    }


class TodoRequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    # Attach state via server
    @property
    def app_state(self) -> AppState:
        srv = cast(TodoHTTPServer, self.server)
        return srv.state

    # Utilities
    def _read_json_object(self) -> Tuple[Optional[Dict[str, object]], Optional[str]]:
        length_header = self.headers.get("Content-Length")
        if length_header is None:
            return None, "Invalid JSON"
        try:
            length = int(length_header)
        except ValueError:
            return None, "Invalid JSON"
        try:
            data = self.rfile.read(length)
        except Exception:
            return None, "Invalid JSON"
        try:
            parsed = json.loads(data.decode("utf-8"))
        except Exception:
            return None, "Invalid JSON"
        if not isinstance(parsed, dict):
            return None, "Invalid JSON"
        # Ensure keys are strings
        result: Dict[str, object] = {}
        for k, v in parsed.items():
            if isinstance(k, str):
                result[k] = v
        return result, None

    def _send_json(self, status: int, payload: object, set_cookie: Optional[str] = None) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if set_cookie is not None:
            self.send_header("Set-Cookie", set_cookie)
        self.end_headers()
        self.wfile.write(body)

    def _send_error_json(self, status: int, message: str) -> None:
        self._send_json(status, {"error": message})

    def _get_session_token(self) -> Optional[str]:
        cookie_header = self.headers.get("Cookie")
        if cookie_header is None:
            return None
        c = SimpleCookie()
        try:
            c.load(cookie_header)
        except Exception:
            return None
        morsel = c.get("session_id")  # type: Optional[Morsel[str]]
        if morsel is None:
            return None
        return morsel.value

    def _require_auth(self) -> Tuple[Optional[User], Optional[str]]:
        token = self._get_session_token()
        if token is None:
            self._send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None, None
        user = self.app_state.get_user_by_session(token)
        if user is None:
            self._send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None, None
        return user, token

    # Routing helpers
    def do_POST(self) -> None:  # noqa: N802 (method name by stdlib)
        path = self.path
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
        self._send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:  # noqa: N802
        path = self.path
        if path == "/me":
            self.handle_me()
            return
        if path == "/todos":
            self.handle_list_todos()
            return
        if path.startswith("/todos/"):
            self.handle_get_todo_by_id(path)
            return
        self._send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802
        path = self.path
        if path == "/password":
            self.handle_change_password()
            return
        if path.startswith("/todos/"):
            self.handle_update_todo_by_id(path)
            return
        self._send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802
        path = self.path
        if path.startswith("/todos/"):
            self.handle_delete_todo_by_id(path)
            return
        self._send_error_json(HTTPStatus.NOT_FOUND, "Not found")

    # Handlers
    def handle_register(self) -> None:
        body, err = self._read_json_object()
        if err is not None or body is None:
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_v = body.get("username")
        password_v = body.get("password")
        if not isinstance(username_v, str) or not USERNAME_RE.match(username_v):
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_v, str) or len(password_v) < 8:
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        user, create_err = self.app_state.create_user(username_v, password_v)
        if create_err is not None:
            if create_err == "Username already exists":
                self._send_error_json(HTTPStatus.CONFLICT, create_err)
            elif create_err == "Invalid username":
                self._send_error_json(HTTPStatus.BAD_REQUEST, create_err)
            elif create_err == "Password too short":
                self._send_error_json(HTTPStatus.BAD_REQUEST, create_err)
            else:
                self._send_error_json(HTTPStatus.BAD_REQUEST, create_err)
            return
        assert user is not None
        self._send_json(HTTPStatus.CREATED, user_to_public(user))

    def handle_login(self) -> None:
        body, err = self._read_json_object()
        if err is not None or body is None:
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_v = body.get("username")
        password_v = body.get("password")
        if not isinstance(username_v, str) or not isinstance(password_v, str):
            # Do not leak which is wrong
            self._send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = self.app_state.authenticate(username_v, password_v)
        if user is None:
            self._send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = self.app_state.create_session(user.id)
        cookie = f"session_id={token}; Path=/; HttpOnly"
        self._send_json(HTTPStatus.OK, user_to_public(user), set_cookie=cookie)

    def handle_logout(self) -> None:
        user, token = self._require_auth()
        if user is None or token is None:
            return
        # Invalidate session
        self.app_state.invalidate_session(token)
        self._send_json(HTTPStatus.OK, {})

    def handle_me(self) -> None:
        user, _ = self._require_auth()
        if user is None:
            return
        self._send_json(HTTPStatus.OK, user_to_public(user))

    def handle_change_password(self) -> None:
        user, _ = self._require_auth()
        if user is None:
            return
        body, err = self._read_json_object()
        if err is not None or body is None:
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        old_pw_v = body.get("old_password")
        new_pw_v = body.get("new_password")
        if not isinstance(old_pw_v, str) or not isinstance(new_pw_v, str):
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        ok, change_err = self.app_state.change_password(user.id, old_pw_v, new_pw_v)
        if not ok:
            if change_err == "Password too short":
                self._send_error_json(HTTPStatus.BAD_REQUEST, "Password too short")
            else:
                self._send_error_json(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        self._send_json(HTTPStatus.OK, {})

    def handle_list_todos(self) -> None:
        user, _ = self._require_auth()
        if user is None:
            return
        todos = self.app_state.list_todos_for_user(user.id)
        output = [todo_to_public(t) for t in todos]
        self._send_json(HTTPStatus.OK, output)

    def handle_create_todo(self) -> None:
        user, _ = self._require_auth()
        if user is None:
            return
        body, err = self._read_json_object()
        if err is not None or body is None:
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_v = body.get("title")
        description_v = body.get("description", "")
        if not isinstance(title_v, str) or len(title_v.strip()) == 0:
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        if not isinstance(description_v, str):
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        todo = self.app_state.create_todo(user.id, title_v, description_v)
        self._send_json(HTTPStatus.CREATED, todo_to_public(todo))

    def _parse_todo_id(self, path: str) -> Optional[int]:
        # Expected format: /todos/:id
        parts = path.split("/")
        if len(parts) != 3:
            return None
        if parts[1] != "todos":
            return None
        try:
            return int(parts[2])
        except ValueError:
            return None

    def handle_get_todo_by_id(self, path: str) -> None:
        user, _ = self._require_auth()
        if user is None:
            return
        todo_id = self._parse_todo_id(path)
        if todo_id is None:
            self._send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = self.app_state.get_todo_for_user(todo_id, user.id)
        if todo is None:
            self._send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self._send_json(HTTPStatus.OK, todo_to_public(todo))

    def handle_update_todo_by_id(self, path: str) -> None:
        user, _ = self._require_auth()
        if user is None:
            return
        todo_id = self._parse_todo_id(path)
        if todo_id is None:
            self._send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = self.app_state.get_todo_for_user(todo_id, user.id)
        if todo is None:
            self._send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        body, err = self._read_json_object()
        if err is not None or body is None:
            self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_opt: Optional[str] = None
        desc_opt: Optional[str] = None
        completed_opt: Optional[bool] = None
        if "title" in body:
            v = body.get("title")
            if not isinstance(v, str):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            if len(v) == 0:
                self._send_error_json(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            title_opt = v
        if "description" in body:
            v2 = body.get("description")
            if not isinstance(v2, str):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            desc_opt = v2
        if "completed" in body:
            v3 = body.get("completed")
            if not isinstance(v3, bool):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            completed_opt = v3
        updated = self.app_state.update_todo(todo, title_opt, desc_opt, completed_opt)
        self._send_json(HTTPStatus.OK, todo_to_public(updated))

    def handle_delete_todo_by_id(self, path: str) -> None:
        user, _ = self._require_auth()
        if user is None:
            return
        todo_id = self._parse_todo_id(path)
        if todo_id is None:
            self._send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = self.app_state.get_todo_for_user(todo_id, user.id)
        if todo is None:
            self._send_error_json(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self.app_state.delete_todo(todo_id)
        # 204 No Content, no body
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    # Silence logging for cleaner output
    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))


class TodoHTTPServer(ThreadingHTTPServer):
    def __init__(self, server_address: Tuple[str, int], RequestHandlerClass: type[TodoRequestHandler], state: AppState):
        super().__init__(server_address, RequestHandlerClass)
        self.state = state



def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args(argv)

    state = AppState()
    server = TodoHTTPServer(("0.0.0.0", args.port), TodoRequestHandler, state)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
