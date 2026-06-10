#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Mapping, MutableMapping, Optional, Tuple
from urllib.parse import urlparse
import uuid


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def utc_now_iso() -> str:
    # ISO 8601 UTC timestamp with second precision, Z suffix
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class User:
    id: int
    username: str


@dataclass
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class InMemoryDB:
    def __init__(self) -> None:
        self.next_user_id: int = 1
        self.next_todo_id: int = 1
        self.users_by_id: Dict[int, User] = {}
        self.passwords_by_id: Dict[int, str] = {}
        self.user_id_by_username: Dict[str, int] = {}
        self.sessions: Dict[str, int] = {}
        self.todos_by_id: Dict[int, Todo] = {}

    def create_user(self, username: str, password: str) -> User:
        uid = self.next_user_id
        self.next_user_id += 1
        user = User(id=uid, username=username)
        self.users_by_id[uid] = user
        self.passwords_by_id[uid] = password
        self.user_id_by_username[username] = uid
        return user

    def get_user_by_username(self, username: str) -> Optional[Tuple[User, str]]:
        uid = self.user_id_by_username.get(username)
        if uid is None:
            return None
        user = self.users_by_id[uid]
        pwd = self.passwords_by_id[uid]
        return user, pwd

    def verify_credentials(self, username: str, password: str) -> Optional[User]:
        up = self.get_user_by_username(username)
        if up is None:
            return None
        user, pwd = up
        if pwd != password:
            return None
        return user

    def create_session(self, user_id: int) -> str:
        token = uuid.uuid4().hex
        self.sessions[token] = user_id
        return token

    def get_user_by_session(self, token: Optional[str]) -> Optional[User]:
        if token is None:
            return None
        uid = self.sessions.get(token)
        if uid is None:
            return None
        return self.users_by_id.get(uid)

    def invalidate_session(self, token: Optional[str]) -> None:
        if token is None:
            return
        if token in self.sessions:
            del self.sessions[token]

    def change_password(self, user_id: int, new_password: str) -> None:
        self.passwords_by_id[user_id] = new_password

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        tid = self.next_todo_id
        self.next_todo_id += 1
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
        self.todos_by_id[tid] = todo
        return todo

    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        lst = [t for t in self.todos_by_id.values() if t.user_id == user_id]
        lst.sort(key=lambda t: t.id)
        return lst

    def get_todo_for_user(self, todo_id: int, user_id: int) -> Optional[Todo]:
        t = self.todos_by_id.get(todo_id)
        if t is None or t.user_id != user_id:
            return None
        return t

    def update_todo(self, todo: Todo, title: Optional[str], description: Optional[str], completed: Optional[bool]) -> Todo:
        if title is not None:
            todo.title = title
        if description is not None:
            todo.description = description
        if completed is not None:
            todo.completed = completed
        todo.updated_at = utc_now_iso()
        return todo

    def delete_todo(self, todo_id: int) -> None:
        if todo_id in self.todos_by_id:
            del self.todos_by_id[todo_id]


db = InMemoryDB()


class TodoHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003 - method name from BaseHTTPRequestHandler
        # Reduce noise during automated tests
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))

    # Utility methods
    def _parse_json_body(self) -> Optional[Dict[str, Any]]:
        length_str = self.headers.get('Content-Length')
        if length_str is None:
            data = b""
        else:
            try:
                length = int(length_str)
            except ValueError:
                length = 0
            data = self.rfile.read(length) if length > 0 else b""
        if not data:
            return {}
        try:
            parsed = json.loads(data.decode('utf-8'))
        except json.JSONDecodeError:
            return None
        if isinstance(parsed, dict):
            return parsed
        return None

    def _send_json(self, status: int, payload: Mapping[str, Any] | List[Any]) -> None:
        body = json.dumps(payload).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, status: int, message: str) -> None:
        self._send_json(status, {"error": message})

    def _send_no_content(self) -> None:
        # 204 No Content, no body, no Content-Type
        self.send_response(HTTPStatus.NO_CONTENT)
        # Explicitly avoid Content-Type and Content-Length
        self.end_headers()

    def _get_cookie(self, name: str) -> Optional[str]:
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return None
        parts = [p.strip() for p in cookie_header.split(';')]
        for p in parts:
            if '=' in p:
                k, v = p.split('=', 1)
                if k.strip() == name:
                    return v
        return None

    def _require_auth(self) -> Optional[User]:
        token = self._get_cookie('session_id')
        user = db.get_user_by_session(token)
        if user is None:
            self._send_error(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None
        return user

    # Routing helpers
    def _path_parts(self) -> List[str]:
        path = urlparse(self.path).path
        parts = [p for p in path.split('/') if p]
        return parts

    # HTTP verb handlers
    def do_POST(self) -> None:  # noqa: N802 - method name per BaseHTTPRequestHandler
        parts = self._path_parts()
        if parts == ['register']:
            self._handle_register()
            return
        if parts == ['login']:
            self._handle_login()
            return
        if parts == ['logout']:
            self._handle_logout()
            return
        if parts == ['todos']:
            self._handle_create_todo()
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_GET(self) -> None:  # noqa: N802
        parts = self._path_parts()
        if parts == ['me']:
            self._handle_me()
            return
        if parts == ['todos']:
            self._handle_list_todos()
            return
        if len(parts) == 2 and parts[0] == 'todos':
            self._handle_get_todo(parts[1])
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_PUT(self) -> None:  # noqa: N802
        parts = self._path_parts()
        if parts == ['password']:
            self._handle_change_password()
            return
        if len(parts) == 2 and parts[0] == 'todos':
            self._handle_update_todo(parts[1])
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    def do_DELETE(self) -> None:  # noqa: N802
        parts = self._path_parts()
        if len(parts) == 2 and parts[0] == 'todos':
            self._handle_delete_todo(parts[1])
            return
        self._send_error(HTTPStatus.NOT_FOUND, "Not found")

    # Endpoint implementations
    def _handle_register(self) -> None:
        body = self._parse_json_body()
        if body is None:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_val = body.get('username')
        password_val = body.get('password')
        if not isinstance(username_val, str) or not USERNAME_RE.fullmatch(username_val):
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid username")
            return
        if not isinstance(password_val, str) or len(password_val) < 8:
            self._send_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        if username_val in db.user_id_by_username:
            self._send_error(HTTPStatus.CONFLICT, "Username already exists")
            return
        user = db.create_user(username_val, password_val)
        self._send_json(HTTPStatus.CREATED, asdict(user))

    def _handle_login(self) -> None:
        body = self._parse_json_body()
        if body is None:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        username_val = body.get('username')
        password_val = body.get('password')
        if not isinstance(username_val, str) or not isinstance(password_val, str):
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        user = db.verify_credentials(username_val, password_val)
        if user is None:
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        token = db.create_session(user.id)
        payload = asdict(user)
        body_bytes = json.dumps(payload).encode('utf-8')
        self.send_response(HTTPStatus.OK)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body_bytes)))
        # Set-Cookie: session_id=<token>; Path=/; HttpOnly
        self.send_header('Set-Cookie', f'session_id={token}; Path=/; HttpOnly')
        self.end_headers()
        self.wfile.write(body_bytes)

    def _handle_logout(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        token = self._get_cookie('session_id')
        db.invalidate_session(token)
        self._send_json(HTTPStatus.OK, {})

    def _handle_me(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        self._send_json(HTTPStatus.OK, asdict(user))

    def _handle_change_password(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        body = self._parse_json_body()
        if body is None:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        old_pw = body.get('old_password')
        new_pw = body.get('new_password')
        # Validate old password
        if not isinstance(old_pw, str):
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        stored = db.passwords_by_id.get(user.id)
        if stored != old_pw:
            self._send_error(HTTPStatus.UNAUTHORIZED, "Invalid credentials")
            return
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            self._send_error(HTTPStatus.BAD_REQUEST, "Password too short")
            return
        db.change_password(user.id, new_pw)
        self._send_json(HTTPStatus.OK, {})

    def _handle_list_todos(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        todos = db.list_todos_for_user(user.id)
        payload: List[Dict[str, Any]] = [asdict(t) for t in todos]
        # Use array response; ensure JSON content type
        body = json.dumps(payload).encode('utf-8')
        self.send_response(HTTPStatus.OK)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _handle_create_todo(self) -> None:
        user = self._require_auth()
        if user is None:
            return
        body = self._parse_json_body()
        if body is None:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_val = body.get('title')
        description_val = body.get('description', "")
        if not isinstance(title_val, str) or title_val.strip() == "":
            self._send_error(HTTPStatus.BAD_REQUEST, "Title is required")
            return
        if not isinstance(description_val, str):
            description_val = ""
        todo = db.create_todo(user.id, title_val, description_val)
        self._send_json(HTTPStatus.CREATED, asdict(todo))

    def _parse_todo_id(self, id_part: str) -> Optional[int]:
        try:
            tid = int(id_part)
        except ValueError:
            return None
        if tid <= 0:
            return None
        return tid

    def _handle_get_todo(self, id_part: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        tid = self._parse_todo_id(id_part)
        if tid is None:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = db.get_todo_for_user(tid, user.id)
        if todo is None:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        self._send_json(HTTPStatus.OK, asdict(todo))

    def _handle_update_todo(self, id_part: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        tid = self._parse_todo_id(id_part)
        if tid is None:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = db.get_todo_for_user(tid, user.id)
        if todo is None:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        body = self._parse_json_body()
        if body is None:
            self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
            return
        title_update: Optional[str] = None
        description_update: Optional[str] = None
        completed_update: Optional[bool] = None
        if 'title' in body:
            title_val = body.get('title')
            if not isinstance(title_val, str) or title_val.strip() == "":
                self._send_error(HTTPStatus.BAD_REQUEST, "Title is required")
                return
            title_update = title_val
        if 'description' in body:
            desc_val = body.get('description')
            if isinstance(desc_val, str):
                description_update = desc_val
            else:
                description_update = ""
        if 'completed' in body:
            comp_val = body.get('completed')
            if isinstance(comp_val, bool):
                completed_update = comp_val
            else:
                # Non-bool types are not allowed for completed
                self._send_error(HTTPStatus.BAD_REQUEST, "Invalid JSON")
                return
        updated = db.update_todo(todo, title_update, description_update, completed_update)
        self._send_json(HTTPStatus.OK, asdict(updated))

    def _handle_delete_todo(self, id_part: str) -> None:
        user = self._require_auth()
        if user is None:
            return
        tid = self._parse_todo_id(id_part)
        if tid is None:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        todo = db.get_todo_for_user(tid, user.id)
        if todo is None:
            self._send_error(HTTPStatus.NOT_FOUND, "Todo not found")
            return
        db.delete_todo(tid)
        self._send_no_content()


def run(port: int) -> None:
    server_address = ('0.0.0.0', port)
    httpd = HTTPServer(server_address, TodoHandler)
    print(f"Serving on http://{server_address[0]}:{server_address[1]}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    if args.port <= 0 or args.port > 65535:
        print("Invalid port", file=sys.stderr)
        sys.exit(2)
    run(args.port)


if __name__ == '__main__':
    main()
