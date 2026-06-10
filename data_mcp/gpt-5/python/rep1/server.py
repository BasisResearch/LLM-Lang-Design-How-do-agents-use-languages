#!/usr/bin/env python3
import argparse
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from http import cookies
import uuid
import time
from datetime import datetime, timezone
import sys
import traceback
import hashlib
import hmac
import os

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')


def utc_now_iso8601():
    # ISO 8601 UTC timestamp with second precision and 'Z'
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


class InMemoryStore:
    def __init__(self):
        self.lock = threading.RLock()
        self.next_user_id = 1
        self.users_by_id = {}
        self.users_by_username = {}
        self.sessions = {}  # token -> user_id
        self.next_todo_id = 1
        self.todos_by_id = {}  # todo_id -> todo dict including owner user_id

    # Password hashing helpers
    def _hash_password(self, password: str, salt: bytes) -> bytes:
        # Use PBKDF2-HMAC-SHA256 with adequate iterations
        return hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, 100_000)

    def create_user(self, username: str, password: str):
        with self.lock:
            if username in self.users_by_username:
                return None, 'Username already exists'
            user_id = self.next_user_id
            self.next_user_id += 1
            salt = os.urandom(16)
            pwd_hash = self._hash_password(password, salt)
            user_record = {
                'id': user_id,
                'username': username,
                'password_hash': pwd_hash,
                'salt': salt,
            }
            self.users_by_id[user_id] = user_record
            self.users_by_username[username] = user_id
            return {'id': user_id, 'username': username}, None

    def verify_credentials(self, username: str, password: str):
        with self.lock:
            user_id = self.users_by_username.get(username)
            if not user_id:
                return None
            user = self.users_by_id.get(user_id)
            if not user:
                return None
            calc = self._hash_password(password, user['salt'])
            if hmac.compare_digest(calc, user['password_hash']):
                return {'id': user['id'], 'username': user['username']}
            return None

    def change_password(self, user_id: int, old_password: str, new_password: str) -> bool:
        with self.lock:
            user = self.users_by_id.get(user_id)
            if not user:
                return False
            calc = self._hash_password(old_password, user['salt'])
            if not hmac.compare_digest(calc, user['password_hash']):
                return False
            # Update with new salt
            new_salt = os.urandom(16)
            new_hash = self._hash_password(new_password, new_salt)
            user['salt'] = new_salt
            user['password_hash'] = new_hash
            return True

    def create_session(self, user_id: int) -> str:
        with self.lock:
            token = uuid.uuid4().hex
            self.sessions[token] = user_id
            return token

    def get_user_by_session(self, token: str):
        with self.lock:
            user_id = self.sessions.get(token)
            if not user_id:
                return None
            user = self.users_by_id.get(user_id)
            if not user:
                return None
            return {'id': user['id'], 'username': user['username']}

    def invalidate_session(self, token: str):
        with self.lock:
            if token in self.sessions:
                del self.sessions[token]

    def _todo_public(self, todo):
        return {
            'id': todo['id'],
            'title': todo['title'],
            'description': todo['description'],
            'completed': todo['completed'],
            'created_at': todo['created_at'],
            'updated_at': todo['updated_at'],
        }

    def list_todos_for_user(self, user_id: int):
        with self.lock:
            todos = [self._todo_public(t) for t in self.todos_by_id.values() if t['user_id'] == user_id]
            todos.sort(key=lambda x: x['id'])
            return todos

    def create_todo(self, user_id: int, title: str, description: str = ''):
        with self.lock:
            todo_id = self.next_todo_id
            self.next_todo_id += 1
            now = utc_now_iso8601()
            todo = {
                'id': todo_id,
                'user_id': user_id,
                'title': title,
                'description': description or '',
                'completed': False,
                'created_at': now,
                'updated_at': now,
            }
            self.todos_by_id[todo_id] = todo
            return self._todo_public(todo)

    def get_todo_for_user(self, user_id: int, todo_id: int):
        with self.lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo:
                return None
            if todo['user_id'] != user_id:
                return None
            return self._todo_public(todo)

    def update_todo_for_user(self, user_id: int, todo_id: int, updates: dict):
        with self.lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo:
                return None
            if todo['user_id'] != user_id:
                return None
            changed = False
            if 'title' in updates:
                todo['title'] = updates['title']
                changed = True
            if 'description' in updates:
                todo['description'] = updates['description']
                changed = True
            if 'completed' in updates:
                todo['completed'] = bool(updates['completed'])
                changed = True
            if changed:
                todo['updated_at'] = utc_now_iso8601()
            return self._todo_public(todo)

    def delete_todo_for_user(self, user_id: int, todo_id: int) -> bool:
        with self.lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo:
                return False
            if todo['user_id'] != user_id:
                return False
            del self.todos_by_id[todo_id]
            return True


STORE = InMemoryStore()


class TodoHandler(BaseHTTPRequestHandler):
    server_version = 'TodoServer/1.0'

    def log_message(self, format, *args):
        # Log to stderr with timestamp
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))

    def _read_json(self):
        length = self.headers.get('Content-Length')
        if not length:
            return None, None
        try:
            raw = self.rfile.read(int(length))
        except Exception:
            return None, 'Invalid JSON'
        try:
            if not raw:
                return None, None
            data = json.loads(raw.decode('utf-8'))
            return data, None
        except Exception:
            return None, 'Invalid JSON'

    def _send_json(self, code, obj, set_cookie: str | None = None):
        body = json.dumps(obj).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        if set_cookie is not None:
            self.send_header('Set-Cookie', set_cookie)
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, code, message):
        self._send_json(code, {'error': message})

    def _parse_cookies(self):
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return {}
        c = cookies.SimpleCookie()
        try:
            c.load(cookie_header)
        except Exception:
            return {}
        out = {}
        for key in c.keys():
            out[key] = c[key].value
        return out

    def _require_auth(self):
        # Returns (user, session_token) or (None, None) and sends 401
        cookies_map = self._parse_cookies()
        token = cookies_map.get('session_id')
        if not token:
            self._send_error(401, 'Authentication required')
            return None, None
        user = STORE.get_user_by_session(token)
        if not user:
            self._send_error(401, 'Authentication required')
            return None, None
        return user, token

    # Routing helpers
    def do_POST(self):
        try:
            parsed = urlparse(self.path)
            path = parsed.path
            if path == '/register':
                return self.handle_register()
            if path == '/login':
                return self.handle_login()
            if path == '/logout':
                return self.handle_logout()
            if path == '/todos':
                return self.handle_create_todo()
            self._send_error(404, 'Not found')
        except Exception:
            traceback.print_exc()
            self._send_error(500, 'Internal server error')

    def do_GET(self):
        try:
            parsed = urlparse(self.path)
            path = parsed.path
            if path == '/me':
                return self.handle_me()
            if path == '/todos':
                return self.handle_list_todos()
            if path.startswith('/todos/'):
                return self.handle_get_todo_by_id(path)
            self._send_error(404, 'Not found')
        except Exception:
            traceback.print_exc()
            self._send_error(500, 'Internal server error')

    def do_PUT(self):
        try:
            parsed = urlparse(self.path)
            path = parsed.path
            if path == '/password':
                return self.handle_change_password()
            if path.startswith('/todos/'):
                return self.handle_update_todo_by_id(path)
            self._send_error(404, 'Not found')
        except Exception:
            traceback.print_exc()
            self._send_error(500, 'Internal server error')

    def do_DELETE(self):
        try:
            parsed = urlparse(self.path)
            path = parsed.path
            if path.startswith('/todos/'):
                return self.handle_delete_todo_by_id(path)
            self._send_error(404, 'Not found')
        except Exception:
            traceback.print_exc()
            self._send_error(500, 'Internal server error')

    # Handlers
    def handle_register(self):
        data, err = self._read_json()
        if err:
            return self._send_error(400, err)
        if not data or not isinstance(data, dict):
            return self._send_error(400, 'Invalid JSON')
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not USERNAME_RE.fullmatch(username or ''):
            return self._send_error(400, 'Invalid username')
        if not isinstance(password, str) or len(password) < 8:
            return self._send_error(400, 'Password too short')
        user, err = STORE.create_user(username, password)
        if err:
            return self._send_error(409, err)
        return self._send_json(201, user)

    def handle_login(self):
        data, err = self._read_json()
        if err:
            return self._send_error(400, err)
        if not data or not isinstance(data, dict):
            return self._send_error(400, 'Invalid JSON')
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not isinstance(password, str):
            return self._send_error(401, 'Invalid credentials')
        user = STORE.verify_credentials(username, password)
        if not user:
            return self._send_error(401, 'Invalid credentials')
        token = STORE.create_session(user['id'])
        set_cookie = f'session_id={token}; Path=/; HttpOnly'
        return self._send_json(200, user, set_cookie=set_cookie)

    def handle_logout(self):
        user, token = self._require_auth()
        if not user:
            return
        # Invalidate the session token
        if token:
            STORE.invalidate_session(token)
        # Return empty JSON object
        return self._send_json(200, {})

    def handle_me(self):
        user, _ = self._require_auth()
        if not user:
            return
        return self._send_json(200, user)

    def handle_change_password(self):
        user, _ = self._require_auth()
        if not user:
            return
        data, err = self._read_json()
        if err:
            return self._send_error(400, err)
        if not data or not isinstance(data, dict):
            return self._send_error(400, 'Invalid JSON')
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        if not isinstance(new_password, str) or len(new_password) < 8:
            return self._send_error(400, 'Password too short')
        if not isinstance(old_password, str):
            return self._send_error(401, 'Invalid credentials')
        ok = STORE.change_password(user['id'], old_password, new_password)
        if not ok:
            return self._send_error(401, 'Invalid credentials')
        return self._send_json(200, {})

    def handle_list_todos(self):
        user, _ = self._require_auth()
        if not user:
            return
        todos = STORE.list_todos_for_user(user['id'])
        return self._send_json(200, todos)

    def handle_create_todo(self):
        user, _ = self._require_auth()
        if not user:
            return
        data, err = self._read_json()
        if err:
            return self._send_error(400, err)
        if not data or not isinstance(data, dict):
            return self._send_error(400, 'Invalid JSON')
        title = data.get('title')
        description = data.get('description', '')
        if 'title' not in data or not isinstance(title, str) or title.strip() == '':
            return self._send_error(400, 'Title is required')
        if not isinstance(description, str):
            description = ''
        todo = STORE.create_todo(user['id'], title.strip(), description)
        return self._send_json(201, todo)

    def _parse_todo_id_from_path(self, path: str):
        parts = path.split('/')
        if len(parts) != 3 or parts[1] != 'todos' or not parts[2]:
            return None
        try:
            todo_id = int(parts[2])
            if todo_id < 1:
                return None
            return todo_id
        except Exception:
            return None

    def handle_get_todo_by_id(self, path: str):
        user, _ = self._require_auth()
        if not user:
            return
        todo_id = self._parse_todo_id_from_path(path)
        if not todo_id:
            return self._send_error(404, 'Todo not found')
        todo = STORE.get_todo_for_user(user['id'], todo_id)
        if not todo:
            return self._send_error(404, 'Todo not found')
        return self._send_json(200, todo)

    def handle_update_todo_by_id(self, path: str):
        user, _ = self._require_auth()
        if not user:
            return
        todo_id = self._parse_todo_id_from_path(path)
        if not todo_id:
            return self._send_error(404, 'Todo not found')
        data, err = self._read_json()
        if err:
            return self._send_error(400, err)
        if data is None:
            data = {}
        if not isinstance(data, dict):
            return self._send_error(400, 'Invalid JSON')
        updates = {}
        if 'title' in data:
            title = data.get('title')
            if not isinstance(title, str) or title.strip() == '':
                return self._send_error(400, 'Title is required')
            updates['title'] = title.strip()
        if 'description' in data:
            desc = data.get('description')
            if not isinstance(desc, str):
                desc = ''
            updates['description'] = desc
        if 'completed' in data:
            comp = data.get('completed')
            # Must be a boolean per spec; but we'll coerce truthiness to bool
            updates['completed'] = bool(comp)
        todo = STORE.update_todo_for_user(user['id'], todo_id, updates)
        if not todo:
            return self._send_error(404, 'Todo not found')
        return self._send_json(200, todo)

    def handle_delete_todo_by_id(self, path: str):
        user, _ = self._require_auth()
        if not user:
            return
        todo_id = self._parse_todo_id_from_path(path)
        if not todo_id:
            return self._send_error(404, 'Todo not found')
        ok = STORE.delete_todo_for_user(user['id'], todo_id)
        if not ok:
            return self._send_error(404, 'Todo not found')
        # 204 No Content, no body and no Content-Type header
        self.send_response(204)
        self.end_headers()


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    server_address = ('0.0.0.0', args.port)
    httpd = ThreadingHTTPServer(server_address, TodoHandler)
    # Reduce timeout to prevent hanging tests
    httpd.timeout = 2
    try:
        print(f"Serving on 0.0.0.0:{args.port}")
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == '__main__':
    main()
