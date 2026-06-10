#!/usr/bin/env python3
import argparse
import json
import re
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from urllib.parse import parse_qs
import uuid
import hashlib
import secrets
from datetime import datetime, timezone
from typing import Optional, Tuple

# In-memory storage
NEXT_USER_ID = 1
USERS_BY_USERNAME = {}  # username -> {id, username, password_hash, salt}
USERS_BY_ID = {}  # id -> same dict
SESSIONS = {}  # session_id token -> user_id

NEXT_TODO_ID = 1
TODOS = {}  # todo_id -> {id, title, description, completed, created_at, updated_at, user_id}

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')


def now_iso8601_utc() -> str:
    # ISO 8601 UTC timestamp with second precision, trailing Z
    return datetime.utcnow().replace(microsecond=0).isoformat() + 'Z'


def hash_password(password: str, salt: str) -> str:
    h = hashlib.sha256()
    h.update((salt + password).encode('utf-8'))
    return h.hexdigest()


def get_cookies(header_val: Optional[str]) -> dict:
    cookies = {}
    if not header_val:
        return cookies
    parts = header_val.split(';')
    for p in parts:
        if '=' in p:
            k, v = p.split('=', 1)
            cookies[k.strip()] = v.strip()
    return cookies


class TodoRequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    def log_message(self, format, *args):
        # Keep default logging to stderr for visibility in tests
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0],
                                                self.log_date_time_string(),
                                                format%args))

    # Utility: JSON responses
    def send_json(self, status_code: int, payload: dict):
        body = json.dumps(payload).encode('utf-8')
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json_list(self, status_code: int, payload_list: list):
        body = json.dumps(payload_list).encode('utf-8')
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status_code: int, message: str):
        self.send_json(status_code, {"error": message})

    def parse_json_body(self) -> Tuple[Optional[dict], Optional[str]]:
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            length = 0
        body = b''
        if length > 0:
            body = self.rfile.read(length)
        if not body:
            return {}, None
        try:
            data = json.loads(body.decode('utf-8'))
            if not isinstance(data, dict):
                return None, 'Invalid JSON'
            return data, None
        except Exception:
            return None, 'Invalid JSON'

    def get_authenticated_user(self) -> Optional[dict]:
        # Returns user dict if authenticated, else None
        cookies = get_cookies(self.headers.get('Cookie'))
        token = cookies.get('session_id')
        if not token:
            return None
        user_id = SESSIONS.get(token)
        if not user_id:
            return None
        return USERS_BY_ID.get(user_id)

    def require_auth(self) -> Optional[dict]:
        user = self.get_authenticated_user()
        if not user:
            self.send_error_json(401, 'Authentication required')
            return None
        return user

    # Routing
    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/register':
            return self.handle_register()
        elif path == '/login':
            return self.handle_login()
        elif path == '/logout':
            user = self.require_auth()
            if not user:
                return
            return self.handle_logout()
        elif path == '/todos':
            user = self.require_auth()
            if not user:
                return
            return self.handle_create_todo(user)
        else:
            self.send_error_json(404, 'Not found')

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/me':
            user = self.require_auth()
            if not user:
                return
            return self.handle_me(user)
        elif path == '/todos':
            user = self.require_auth()
            if not user:
                return
            return self.handle_list_todos(user)
        elif path.startswith('/todos/'):
            user = self.require_auth()
            if not user:
                return
            return self.handle_get_todo(user, path)
        else:
            self.send_error_json(404, 'Not found')

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/password':
            user = self.require_auth()
            if not user:
                return
            return self.handle_change_password(user)
        elif path.startswith('/todos/'):
            user = self.require_auth()
            if not user:
                return
            return self.handle_update_todo(user, path)
        else:
            self.send_error_json(404, 'Not found')

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith('/todos/'):
            user = self.require_auth()
            if not user:
                return
            return self.handle_delete_todo(user, path)
        else:
            self.send_error_json(404, 'Not found')

    # Handlers
    def handle_register(self):
        data, err = self.parse_json_body()
        if err is not None:
            # Treat invalid JSON as bad request for this endpoint
            self.send_error_json(400, 'Invalid username')
            return
        username = data.get('username') if isinstance(data, dict) else None
        password = data.get('password') if isinstance(data, dict) else None
        if not isinstance(username, str) or not USERNAME_RE.match(username):
            self.send_error_json(400, 'Invalid username')
            return
        if not isinstance(password, str) or len(password) < 8:
            self.send_error_json(400, 'Password too short')
            return
        if username in USERS_BY_USERNAME:
            self.send_error_json(409, 'Username already exists')
            return
        global NEXT_USER_ID
        salt = secrets.token_hex(16)
        pwd_hash = hash_password(password, salt)
        user = {
            'id': NEXT_USER_ID,
            'username': username,
            'password_hash': pwd_hash,
            'salt': salt,
        }
        USERS_BY_USERNAME[username] = user
        USERS_BY_ID[user['id']] = user
        NEXT_USER_ID += 1
        self.send_json(201, {'id': user['id'], 'username': user['username']})

    def handle_login(self):
        data, err = self.parse_json_body()
        if err is not None:
            self.send_error_json(401, 'Invalid credentials')
            return
        username = data.get('username') if isinstance(data, dict) else None
        password = data.get('password') if isinstance(data, dict) else None
        if not isinstance(username, str) or not isinstance(password, str):
            self.send_error_json(401, 'Invalid credentials')
            return
        user = USERS_BY_USERNAME.get(username)
        if not user:
            self.send_error_json(401, 'Invalid credentials')
            return
        expected = user['password_hash']
        salt = user['salt']
        if hash_password(password, salt) != expected:
            self.send_error_json(401, 'Invalid credentials')
            return
        # Create session
        token = uuid.uuid4().hex
        SESSIONS[token] = user['id']
        body = json.dumps({'id': user['id'], 'username': user['username']}).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Set-Cookie', f'session_id={token}; Path=/; HttpOnly')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_logout(self):
        # Invalidate session
        cookies = get_cookies(self.headers.get('Cookie'))
        token = cookies.get('session_id')
        if token and token in SESSIONS:
            del SESSIONS[token]
        # Return 200 {}
        body = json.dumps({}).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        # Also clear cookie client-side (optional for spec)
        self.send_header('Set-Cookie', 'session_id=; Path=/; HttpOnly')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_me(self, user: dict):
        self.send_json(200, {'id': user['id'], 'username': user['username']})

    def handle_change_password(self, user: dict):
        data, err = self.parse_json_body()
        if err is not None:
            self.send_error_json(400, 'Password too short')
            return
        old_password = data.get('old_password') if isinstance(data, dict) else None
        new_password = data.get('new_password') if isinstance(data, dict) else None
        if not isinstance(old_password, str) or hash_password(old_password, user['salt']) != user['password_hash']:
            self.send_error_json(401, 'Invalid credentials')
            return
        if not isinstance(new_password, str) or len(new_password) < 8:
            self.send_error_json(400, 'Password too short')
            return
        # Update
        salt = secrets.token_hex(16)
        user['salt'] = salt
        user['password_hash'] = hash_password(new_password, salt)
        self.send_json(200, {})

    def handle_list_todos(self, user: dict):
        user_id = user['id']
        items = [todo_public_view(t) for t in TODOS.values() if t['user_id'] == user_id]
        items.sort(key=lambda x: x['id'])
        self.send_json_list(200, items)

    def handle_create_todo(self, user: dict):
        data, err = self.parse_json_body()
        if err is not None:
            self.send_error_json(400, 'Title is required')
            return
        title = data.get('title') if isinstance(data, dict) else None
        description = data.get('description') if isinstance(data, dict) else ''
        if description is None:
            description = ''
        if not isinstance(title, str) or title.strip() == '':
            self.send_error_json(400, 'Title is required')
            return
        if not isinstance(description, str):
            # Coerce to string per permissive behavior
            description = str(description)
        global NEXT_TODO_ID
        todo_id = NEXT_TODO_ID
        NEXT_TODO_ID += 1
        ts = now_iso8601_utc()
        todo = {
            'id': todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': ts,
            'updated_at': ts,
            'user_id': user['id'],
        }
        TODOS[todo_id] = todo
        self.send_json(201, todo_public_view(todo))

    def parse_todo_id_from_path(self, path: str) -> Optional[int]:
        parts = path.strip('/').split('/')
        if len(parts) == 2 and parts[0] == 'todos':
            try:
                return int(parts[1])
            except ValueError:
                return None
        return None

    def find_user_todo(self, user: dict, path: str) -> Optional[dict]:
        todo_id = self.parse_todo_id_from_path(path)
        if todo_id is None:
            return None
        todo = TODOS.get(todo_id)
        if not todo or todo['user_id'] != user['id']:
            return None
        return todo

    def handle_get_todo(self, user: dict, path: str):
        todo = self.find_user_todo(user, path)
        if not todo:
            self.send_error_json(404, 'Todo not found')
            return
        self.send_json(200, todo_public_view(todo))

    def handle_update_todo(self, user: dict, path: str):
        todo = self.find_user_todo(user, path)
        if not todo:
            self.send_error_json(404, 'Todo not found')
            return
        data, err = self.parse_json_body()
        if err is not None:
            self.send_error_json(400, 'Title is required')
            return
        if not isinstance(data, dict):
            data = {}
        if 'title' in data:
            title = data.get('title')
            if not isinstance(title, str) or title.strip() == '':
                self.send_error_json(400, 'Title is required')
                return
            todo['title'] = title
        if 'description' in data:
            desc = data.get('description')
            if desc is None:
                desc = ''
            if not isinstance(desc, str):
                desc = str(desc)
            todo['description'] = desc
        if 'completed' in data:
            comp = data.get('completed')
            # Accept only booleans per spec field type
            if isinstance(comp, bool):
                todo['completed'] = comp
            else:
                # If non-bool provided, coerce truthiness to bool to avoid unexpected errors
                todo['completed'] = bool(comp)
        todo['updated_at'] = now_iso8601_utc()
        self.send_json(200, todo_public_view(todo))

    def handle_delete_todo(self, user: dict, path: str):
        todo_id = self.parse_todo_id_from_path(path)
        if todo_id is None:
            self.send_error_json(404, 'Todo not found')
            return
        todo = TODOS.get(todo_id)
        if not todo or todo['user_id'] != user['id']:
            self.send_error_json(404, 'Todo not found')
            return
        del TODOS[todo_id]
        # 204 No Content, no body and no Content-Type
        self.send_response(204)
        self.send_header('Content-Length', '0')
        self.end_headers()


def todo_public_view(todo: dict) -> dict:
    return {
        'id': todo['id'],
        'title': todo['title'],
        'description': todo['description'],
        'completed': todo['completed'],
        'created_at': todo['created_at'],
        'updated_at': todo['updated_at'],
    }


def run(host: str, port: int):
    httpd = HTTPServer((host, port), TodoRequestHandler)
    print(f"Server listening on {host}:{port}")
    httpd.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to listen on')
    args = parser.parse_args()
    try:
        run('0.0.0.0', args.port)
    except KeyboardInterrupt:
        print('Shutting down.')
