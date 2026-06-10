#!/usr/bin/env python3
import argparse
import json
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
from datetime import datetime, timezone
from typing import Optional, Tuple

# In-memory storage
USERS = {}  # id -> {id, username, password}
USERNAMES = {}  # username -> id
NEXT_USER_ID = 1

SESSIONS = {}  # session_token -> user_id

TODOS = {}  # id -> {id, user_id, title, description, completed, created_at, updated_at}
NEXT_TODO_ID = 1

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def iso_now() -> str:
    # ISO 8601 UTC timestamp with second precision
    return datetime.utcnow().replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_json_body(handler: BaseHTTPRequestHandler) -> Tuple[Optional[dict], Optional[str]]:
    try:
        length = int(handler.headers.get('Content-Length', '0'))
    except ValueError:
        length = 0
    if length == 0:
        return {}, None
    try:
        raw = handler.rfile.read(length)
        if not raw:
            return {}, None
        data = json.loads(raw.decode('utf-8'))
        if isinstance(data, dict):
            return data, None
        else:
            return None, "Invalid JSON"
    except json.JSONDecodeError:
        return None, "Invalid JSON"


def get_cookie(handler: BaseHTTPRequestHandler, name: str) -> Optional[str]:
    cookie_header = handler.headers.get('Cookie')
    if not cookie_header:
        return None
    # Simple cookie parsing
    parts = cookie_header.split(';')
    for part in parts:
        if '=' in part:
            k, v = part.strip().split('=', 1)
            if k.strip() == name:
                return v.strip()
    return None


def set_json_headers(handler: BaseHTTPRequestHandler, status: int, length: int):
    handler.send_response(status)
    handler.send_header('Content-Type', 'application/json')
    handler.send_header('Content-Length', str(length))


def send_json(handler: BaseHTTPRequestHandler, status: int, obj: dict):
    body = json.dumps(obj).encode('utf-8')
    set_json_headers(handler, status, len(body))
    handler.end_headers()
    handler.wfile.write(body)


def send_error_json(handler: BaseHTTPRequestHandler, status: int, message: str):
    send_json(handler, status, {"error": message})


def send_no_content(handler: BaseHTTPRequestHandler):
    handler.send_response(204)
    handler.send_header('Content-Length', '0')
    handler.end_headers()


def require_auth(handler: BaseHTTPRequestHandler) -> Optional[dict]:
    token = get_cookie(handler, 'session_id')
    if not token or token not in SESSIONS:
        send_error_json(handler, 401, "Authentication required")
        return None
    uid = SESSIONS[token]
    user = USERS.get(uid)
    if not user:
        # Shouldn't happen, but treat as unauthenticated
        send_error_json(handler, 401, "Authentication required")
        return None
    return {"user": user, "session_token": token}


class TodoRequestHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        # Reduce noisy logging, but keep to stderr
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/register':
            self.handle_register()
        elif path == '/login':
            self.handle_login()
        elif path == '/logout':
            auth = require_auth(self)
            if auth is None:
                return
            self.handle_logout(auth)
        elif path == '/todos':
            auth = require_auth(self)
            if auth is None:
                return
            self.handle_create_todo(auth)
        else:
            send_error_json(self, 404, "Not found")

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/me':
            auth = require_auth(self)
            if auth is None:
                return
            self.handle_me(auth)
        elif path == '/todos':
            auth = require_auth(self)
            if auth is None:
                return
            self.handle_list_todos(auth)
        elif path.startswith('/todos/'):
            auth = require_auth(self)
            if auth is None:
                return
            self.handle_get_todo(auth, path)
        else:
            send_error_json(self, 404, "Not found")

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/password':
            auth = require_auth(self)
            if auth is None:
                return
            self.handle_change_password(auth)
        elif path.startswith('/todos/'):
            auth = require_auth(self)
            if auth is None:
                return
            self.handle_update_todo(auth, path)
        else:
            send_error_json(self, 404, "Not found")

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith('/todos/'):
            auth = require_auth(self)
            if auth is None:
                return
            self.handle_delete_todo(auth, path)
        else:
            send_error_json(self, 404, "Not found")

    # Handlers
    def handle_register(self):
        global NEXT_USER_ID
        data, err = parse_json_body(self)
        if data is None:
            send_error_json(self, 400, err or "Invalid JSON")
            return
        username = data.get('username')
        password = data.get('password')

        if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
            send_error_json(self, 400, "Invalid username")
            return
        if not isinstance(password, str) or len(password) < 8:
            send_error_json(self, 400, "Password too short")
            return
        if username in USERNAMES:
            send_error_json(self, 409, "Username already exists")
            return
        uid = NEXT_USER_ID
        NEXT_USER_ID += 1
        USERS[uid] = {"id": uid, "username": username, "password": password}
        USERNAMES[username] = uid
        send_json(self, 201, {"id": uid, "username": username})

    def handle_login(self):
        data, err = parse_json_body(self)
        if data is None:
            send_error_json(self, 400, err or "Invalid JSON")
            return
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not isinstance(password, str):
            send_error_json(self, 401, "Invalid credentials")
            return
        uid = USERNAMES.get(username)
        if not uid:
            send_error_json(self, 401, "Invalid credentials")
            return
        user = USERS.get(uid)
        if not user or user.get('password') != password:
            send_error_json(self, 401, "Invalid credentials")
            return
        token = uuid.uuid4().hex
        SESSIONS[token] = uid
        body = json.dumps({"id": uid, "username": username}).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Set-Cookie', f'session_id={token}; Path=/; HttpOnly')
        self.end_headers()
        self.wfile.write(body)

    def handle_logout(self, auth):
        token = auth['session_token']
        if token in SESSIONS:
            del SESSIONS[token]
        # Return empty JSON object
        send_json(self, 200, {})

    def handle_me(self, auth):
        user = auth['user']
        send_json(self, 200, {"id": user['id'], "username": user['username']})

    def handle_change_password(self, auth):
        user = auth['user']
        data, err = parse_json_body(self)
        if data is None:
            send_error_json(self, 400, err or "Invalid JSON")
            return
        old_pw = data.get('old_password')
        new_pw = data.get('new_password')
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            send_error_json(self, 400, "Password too short")
            return
        if user.get('password') != old_pw:
            send_error_json(self, 401, "Invalid credentials")
            return
        user['password'] = new_pw
        send_json(self, 200, {})

    def handle_list_todos(self, auth):
        user = auth['user']
        uid = user['id']
        items = [todo for todo in TODOS.values() if todo['user_id'] == uid]
        items.sort(key=lambda t: t['id'])
        # Remove user_id from response
        response = [{k: v for k, v in t.items() if k != 'user_id'} for t in items]
        send_json(self, 200, response)

    def handle_create_todo(self, auth):
        global NEXT_TODO_ID
        user = auth['user']
        data, err = parse_json_body(self)
        if data is None:
            send_error_json(self, 400, err or "Invalid JSON")
            return
        title = data.get('title')
        description = data.get('description', "")
        if not isinstance(title, str) or title.strip() == "":
            send_error_json(self, 400, "Title is required")
            return
        if not isinstance(description, str):
            description = str(description)
        tid = NEXT_TODO_ID
        NEXT_TODO_ID += 1
        now = iso_now()
        todo = {
            'id': tid,
            'user_id': user['id'],
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now,
            'updated_at': now,
        }
        TODOS[tid] = todo
        resp = {k: v for k, v in todo.items() if k != 'user_id'}
        send_json(self, 201, resp)

    def _parse_todo_id(self, path: str) -> Optional[int]:
        parts = path.rstrip('/').split('/')
        if len(parts) >= 3 and parts[1] == 'todos':
            try:
                return int(parts[2])
            except (ValueError, IndexError):
                return None
        return None

    def _get_owned_todo(self, uid: int, tid: int) -> Optional[dict]:
        todo = TODOS.get(tid)
        if not todo or todo.get('user_id') != uid:
            return None
        return todo

    def handle_get_todo(self, auth, path: str):
        user = auth['user']
        tid = self._parse_todo_id(path)
        if tid is None:
            send_error_json(self, 404, "Todo not found")
            return
        todo = self._get_owned_todo(user['id'], tid)
        if not todo:
            send_error_json(self, 404, "Todo not found")
            return
        resp = {k: v for k, v in todo.items() if k != 'user_id'}
        send_json(self, 200, resp)

    def handle_update_todo(self, auth, path: str):
        user = auth['user']
        tid = self._parse_todo_id(path)
        if tid is None:
            send_error_json(self, 404, "Todo not found")
            return
        todo = self._get_owned_todo(user['id'], tid)
        if not todo:
            send_error_json(self, 404, "Todo not found")
            return
        data, err = parse_json_body(self)
        if data is None:
            send_error_json(self, 400, err or "Invalid JSON")
            return
        # Partial update
        if 'title' in data:
            title = data.get('title')
            if not isinstance(title, str) or title.strip() == "":
                send_error_json(self, 400, "Title is required")
                return
            todo['title'] = title
        if 'description' in data:
            desc = data.get('description')
            if not isinstance(desc, str):
                desc = str(desc)
            todo['description'] = desc
        if 'completed' in data:
            comp = data.get('completed')
            if isinstance(comp, bool):
                todo['completed'] = comp
            else:
                # If present but not bool, treat as invalid request
                send_error_json(self, 400, "Invalid request")
                return
        todo['updated_at'] = iso_now()
        resp = {k: v for k, v in todo.items() if k != 'user_id'}
        send_json(self, 200, resp)

    def handle_delete_todo(self, auth, path: str):
        user = auth['user']
        tid = self._parse_todo_id(path)
        if tid is None:
            send_error_json(self, 404, "Todo not found")
            return
        todo = self._get_owned_todo(user['id'], tid)
        if not todo:
            send_error_json(self, 404, "Todo not found")
            return
        del TODOS[tid]
        send_no_content(self)


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    server_address = ('0.0.0.0', args.port)
    httpd = HTTPServer(server_address, TodoRequestHandler)
    try:
        print(f"Server listening on 0.0.0.0:{args.port}")
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == '__main__':
    main()
