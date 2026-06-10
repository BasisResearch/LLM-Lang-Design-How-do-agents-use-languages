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
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Mapping, MutableMapping, Optional, Tuple, Union


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def utc_now_iso() -> str:
    # Second precision, UTC with Z suffix
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class User:
    id: int
    username: str
    password_hash: str
    password_salt: str

    def to_public(self) -> Dict[str, Union[int, str]]:
        return {"id": self.id, "username": self.username}


@dataclass
class Todo:
    id: int
    owner_user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str

    def to_public(self) -> Dict[str, Union[int, str, bool]]:
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
            "completed": self.completed,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


class InMemoryDB:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._users_by_username: Dict[str, User] = {}
        self._users_by_id: Dict[int, User] = {}
        self._next_user_id: int = 1

        self._todos_by_id: Dict[int, Todo] = {}
        self._user_todo_ids: Dict[int, List[int]] = {}
        self._next_todo_id: int = 1

        self._sessions: Dict[str, int] = {}

    # Simple PBKDF2 password hashing
    @staticmethod
    def _hash_password(password: str, salt_hex: Optional[str] = None) -> Tuple[str, str]:
        import hashlib
        import os

        if salt_hex is None:
            salt = os.urandom(16)
        else:
            salt = bytes.fromhex(salt_hex)
        dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100_000)
        return dk.hex(), salt.hex()

    def create_user(self, username: str, password: str) -> Tuple[Optional[User], Optional[str]]:
        with self._lock:
            if username in self._users_by_username:
                return None, "Username already exists"
            user_id = self._next_user_id
            self._next_user_id += 1
            pwd_hash, salt_hex = self._hash_password(password)
            user = User(id=user_id, username=username, password_hash=pwd_hash, password_salt=salt_hex)
            self._users_by_username[username] = user
            self._users_by_id[user_id] = user
            return user, None

    def authenticate(self, username: str, password: str) -> Optional[User]:
        with self._lock:
            user = self._users_by_username.get(username)
            if user is None:
                return None
            calc_hash, _ = self._hash_password(password, salt_hex=user.password_salt)
            if calc_hash != user.password_hash:
                return None
            return user

    def change_password(self, user_id: int, old_password: str, new_password: str) -> bool:
        with self._lock:
            user = self._users_by_id.get(user_id)
            if user is None:
                return False
            calc_hash, _ = self._hash_password(old_password, salt_hex=user.password_salt)
            if calc_hash != user.password_hash:
                return False
            new_hash, new_salt = self._hash_password(new_password)
            user.password_hash = new_hash
            user.password_salt = new_salt
            return True

    def create_session(self, user_id: int) -> str:
        with self._lock:
            token = uuid.uuid4().hex
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

    def list_todos(self, user_id: int) -> List[Todo]:
        with self._lock:
            ids = sorted(self._user_todo_ids.get(user_id, []))
            return [self._todos_by_id[i] for i in ids]

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        with self._lock:
            todo_id = self._next_todo_id
            self._next_todo_id += 1
            now = utc_now_iso()
            todo = Todo(
                id=todo_id,
                owner_user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=now,
                updated_at=now,
            )
            self._todos_by_id[todo_id] = todo
            self._user_todo_ids.setdefault(user_id, []).append(todo_id)
            return todo

    def get_todo_for_user(self, user_id: int, todo_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None:
                return None
            if todo.owner_user_id != user_id:
                return None
            return todo

    def update_todo_for_user(
        self,
        user_id: int,
        todo_id: int,
        *,
        title: Optional[str] = None,
        description: Optional[str] = None,
        completed: Optional[bool] = None,
    ) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.owner_user_id != user_id:
                return None
            if title is not None:
                todo.title = title
            if description is not None:
                todo.description = description
            if completed is not None:
                todo.completed = completed
            todo.updated_at = utc_now_iso()
            return todo

    def delete_todo_for_user(self, user_id: int, todo_id: int) -> bool:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.owner_user_id != user_id:
                return False
            del self._todos_by_id[todo_id]
            ids = self._user_todo_ids.get(user_id)
            if ids is not None:
                try:
                    ids.remove(todo_id)
                except ValueError:
                    pass
            return True


DB = InMemoryDB()


class TodoRequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    # Ensure no default logging to stderr for requests to keep tests clean
    def log_message(self, format: str, *args: object) -> None:  # noqa: A003 - name from base class
        return

    # Utilities
    def _parse_json_body(self) -> Tuple[Optional[Mapping[str, object]], Optional[Tuple[int, str]]]:
        length_str = self.headers.get("Content-Length")
        if length_str is None:
            raw = b""
        else:
            try:
                length = int(length_str)
            except ValueError:
                return None, (HTTPStatus.BAD_REQUEST, "Invalid Content-Length")
            raw = self.rfile.read(length)
        if not raw:
            return {}, None
        try:
            data = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return None, (HTTPStatus.BAD_REQUEST, "Invalid JSON")
        if not isinstance(data, dict):
            return None, (HTTPStatus.BAD_REQUEST, "Invalid JSON")
        return data, None

    def _send_json(self, obj: Union[Mapping[str, object], List[Mapping[str, object]]], status: int = 200, headers: Optional[Mapping[str, str]] = None) -> None:
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if headers is not None:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, status: int, message: str) -> None:
        self._send_json({"error": message}, status)

    def _send_no_content(self, status: int = 204) -> None:
        self.send_response(status)
        self.end_headers()

    def _parse_path(self) -> Tuple[str, List[str]]:
        from urllib.parse import urlparse

        parsed = urlparse(self.path)
        path = parsed.path
        parts = [p for p in path.split("/") if p]
        return "/" + "/".join(parts), parts

    def _get_session_token(self) -> Optional[str]:
        cookie_header = self.headers.get("Cookie")
        if not cookie_header:
            return None
        c = SimpleCookie()
        try:
            c.load(cookie_header)
        except Exception:
            return None
        morsel = c.get("session_id")
        if morsel is None:
            return None
        return morsel.value

    def _require_auth(self) -> Optional[User]:
        token = self._get_session_token()
        if token is None:
            self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        user = DB.get_user_by_session(token)
        if user is None:
            self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        return user

    # Handlers
    def do_POST(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        path, parts = self._parse_path()
        if path == "/register":
            self._handle_register()
            return
        if path == "/login":
            self._handle_login()
            return
        if path == "/logout":
            self._handle_logout()
            return
        if path == "/todos":
            self._handle_create_todo()
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        path, parts = self._parse_path()
        if path == "/me":
            self._handle_me()
            return
        if path == "/todos":
            self._handle_list_todos()
            return
        if len(parts) == 2 and parts[0] == "todos":
            self._handle_get_todo(parts[1])
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        path, parts = self._parse_path()
        if path == "/password":
            self._handle_change_password()
            return
        if len(parts) == 2 and parts[0] == "todos":
            self._handle_update_todo(parts[1])
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        path, parts = self._parse_path()
        if len(parts) == 2 and parts[0] == "todos":
            self._handle_delete_todo(parts[1])
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    # Endpoint implementations
    def _handle_register(self) -> None:
        data, err = self._parse_json_body()
        if err is not None:
            self._send_error(err[0], err[1])
            return
        assert data is not None
        username_raw = data.get("username")
        password_raw = data.get("password")
        if not isinstance(username_raw, str) or not USERNAME_RE.fullmatch(username_raw):
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_raw, str) or len(password_raw) < 8:
            self._send_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        user, err_msg = DB.create_user(username_raw, password_raw)
        if user is None:
            # Username taken
            self._send_error(HTTPStatus.CONFLICT, "Username already exists")
            return
        self._send_json(user.to_public(), status=HTTPStatus.CREATED)

    def _handle_login(self) -> None:
        data, err = self._parse_json_body()
        if err is not None:
            self._send_error(err[0], err[1])
            return
        assert data is not None
        username_raw = data.get("username")
        password_raw = data.get("password")
        if not isinstance(username_raw, str) or not isinstance(password_raw, str):
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = DB.authenticate(username_raw, password_raw)
        if user is None:
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = DB.create_session(user.id)
        headers = {"Set-Cookie": f"session_id={token}; Path=/; HttpOnly"}
        self._send_json(user.to_public(), status=HTTPStatus.OK, headers=headers)

    def _handle_logout(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        token = self._get_session_token()
        if token is not None:
            DB.invalidate_session(token)
        self._send_json({}, status=HTTPStatus.OK)

    def _handle_me(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        self._send_json(user.to_public(), status=HTTPStatus.OK)

    def _handle_change_password(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        data, err = self._parse_json_body()
        if err is not None:
            self._send_error(err[0], err[1])
            return
        assert data is not None
        old_pw = data.get("old_password")
        new_pw = data.get("new_password")
        if not isinstance(old_pw, str):
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            self._send_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        ok = DB.change_password(user.id, old_pw, new_pw)
        if not ok:
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        self._send_json({}, status=HTTPStatus.OK)

    def _handle_list_todos(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        todos = DB.list_todos(user.id)
        self._send_json([t.to_public() for t in todos], status=HTTPStatus.OK)

    def _handle_create_todo(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        data, err = self._parse_json_body()
        if err is not None:
            self._send_error(err[0], err[1])
            return
        assert data is not None
        title_raw = data.get("title")
        description_raw = data.get("description")
        if not isinstance(title_raw, str) or title_raw.strip() == "":
            self._send_error(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        description = description_raw if isinstance(description_raw, str) else ""
        todo = DB.create_todo(user.id, title_raw, description)
        self._send_json(todo.to_public(), status=HTTPStatus.CREATED)

    def _handle_get_todo(self, todo_id_str: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = DB.get_todo_for_user(user.id, todo_id)
        if todo is None:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self._send_json(todo.to_public(), status=HTTPStatus.OK)

    def _handle_update_todo(self, todo_id_str: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        data, err = self._parse_json_body()
        if err is not None:
            self._send_error(err[0], err[1])
            return
        assert data is not None
        title_set = False
        title_val: Optional[str] = None
        if "title" in data:
            v = data.get("title")
            if not isinstance(v, str) or v.strip() == "":
                self._send_error(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            title_set = True
            title_val = v
        description_set = False
        description_val: Optional[str] = None
        if "description" in data:
            v2 = data.get("description")
            if not isinstance(v2, str):
                self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            description_set = True
            description_val = v2
        completed_set = False
        completed_val: Optional[bool] = None
        if "completed" in data:
            v3 = data.get("completed")
            if not isinstance(v3, bool):
                self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
            completed_set = True
            completed_val = v3
        todo = DB.update_todo_for_user(
            user.id,
            todo_id,
            title=title_val if title_set else None,
            description=description_val if description_set else None,
            completed=completed_val if completed_set else None,
        )
        if todo is None:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self._send_json(todo.to_public(), status=HTTPStatus.OK)

    def _handle_delete_todo(self, todo_id_str: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        ok = DB.delete_todo_for_user(user.id, todo_id)
        if not ok:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self._send_no_content(HTTPStatus.NO_CONTENT)


def run_server(port: int) -> None:
    server = ThreadingHTTPServer(("0.0.0.0", port), TodoRequestHandler)
    try:
        server.serve_forever(poll_interval=0.5)
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
