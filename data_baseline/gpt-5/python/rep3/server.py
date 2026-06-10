#!/usr/bin/env python3
import argparse
import json
import re
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http import cookies
from urllib.parse import urlparse
from datetime import datetime, timezone
import hashlib
import hmac
import os

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')


def now_iso_utc_second():
    # Returns e.g., 2025-01-15T09:30:00Z
    return datetime.utcnow().replace(microsecond=0).isoformat() + 'Z'


def hash_password(password: str, salt: bytes = None):
    if salt is None:
        salt = os.urandom(16)
    # Use pbkdf2_hmac for a basic secure hash
    iterations = 100_000
    dk = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, iterations)
    return {
        'salt': salt.hex(),
        'iterations': iterations,
        'hash': dk.hex(),
    }


def verify_password(password: str, record):
    try:
        salt = bytes.fromhex(record['salt'])
        iterations = int(record['iterations'])
        expected = bytes.fromhex(record['hash'])
        dk = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, iterations)
        return hmac.compare_digest(dk, expected)
    except Exception:
        return False


class InMemoryStore:
    def __init__(self):
        self._lock = threading.RLock()
        self.next_user_id = 1
        self.users_by_id = {}
        self.users_by_username = {}
        # user record: {id, username, password: {salt, iterations, hash}}

        self.sessions = {}  # token -> user_id

        self.next_todo_id = 1
        self.todos_by_id = {}  # id -> todo (with owner_id)
        self.todo_ids_by_user = {}  # user_id -> list of todo ids

    # User operations
    def create_user(self, username, password):
        with self._lock:
            if username in self.users_by_username:
                return None, 'Username already exists'
            user_id = self.next_user_id
            self.next_user_id += 1
            pwd = hash_password(password)
            user = {'id': user_id, 'username': username, 'password': pwd}
            self.users_by_id[user_id] = user
            self.users_by_username[username] = user
            return {'id': user_id, 'username': username}, None

    def get_user_by_username(self, username):
        with self._lock:
            return self.users_by_username.get(username)

    def get_user_public(self, user_id):
        with self._lock:
            u = self.users_by_id.get(user_id)
            if not u:
                return None
            return {'id': u['id'], 'username': u['username']}

    def set_user_password(self, user_id, new_password):
        with self._lock:
            u = self.users_by_id.get(user_id)
            if not u:
                return False
            u['password'] = hash_password(new_password)
            return True

    # Session operations
    def create_session(self, user_id):
        with self._lock:
            token = uuid.uuid4().hex
            self.sessions[token] = user_id
            return token

    def get_user_id_by_session(self, token):
        with self._lock:
            return self.sessions.get(token)

    def invalidate_session(self, token):
        with self._lock:
            if token in self.sessions:
                del self.sessions[token]
                return True
            return False

    # Todo operations
    def create_todo(self, user_id, title, description):
        with self._lock:
            todo_id = self.next_todo_id
            self.next_todo_id += 1
            ts = now_iso_utc_second()
            todo = {
                'id': todo_id,
                'title': title,
                'description': description,
                'completed': False,
                'created_at': ts,
                'updated_at': ts,
                'owner_id': user_id,
            }
            self.todos_by_id[todo_id] = todo
            self.todo_ids_by_user.setdefault(user_id, []).append(todo_id)
            return self._public_todo(todo)

    def _public_todo(self, todo):
        return {
            'id': todo['id'],
            'title': todo['title'],
            'description': todo['description'],
            'completed': todo['completed'],
            'created_at': todo['created_at'],
            'updated_at': todo['updated_at'],
        }

    def list_todos_for_user(self, user_id):
        with self._lock:
            ids = self.todo_ids_by_user.get(user_id, [])
            todos = [self.todos_by_id[i] for i in ids if i in self.todos_by_id]
            todos.sort(key=lambda t: t['id'])
            return [self._public_todo(t) for t in todos]

    def get_todo_if_owned(self, user_id, todo_id):
        with self._lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo or todo.get('owner_id') != user_id:
                return None
            return self._public_todo(todo)

    def update_todo_if_owned(self, user_id, todo_id, fields):
        with self._lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo or todo.get('owner_id') != user_id:
                return None
            changed = False
            if 'title' in fields:
                todo['title'] = fields['title']
                changed = True
            if 'description' in fields:
                todo['description'] = fields['description']
                changed = True
            if 'completed' in fields:
                todo['completed'] = fields['completed']
                changed = True
            if changed:
                todo['updated_at'] = now_iso_utc_second()
            return self._public_todo(todo)

    def delete_todo_if_owned(self, user_id, todo_id):
        with self._lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo or todo.get('owner_id') != user_id:
                return False
            # Remove from main dict
            del self.todos_by_id[todo_id]
            # Remove from user's list if present
            ids = self.todo_ids_by_user.get(user_id)
            if ids is not None:
                try:
                    ids.remove(todo_id)
                except ValueError:
                    pass
            return True


DB = InMemoryStore()


class TodoHandler(BaseHTTPRequestHandler):
    server_version = 'TodoServer/1.0'

    def log_message(self, format, *args):
        # Keep default logging; could be extended
        super().log_message(format, *args)

    # Utility methods
    def _send_json(self, code, obj, set_cookie=None, extra_headers=None):
        body = json.dumps(obj).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        if set_cookie is not None:
            self.send_header('Set-Cookie', set_cookie)
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, code, message):
        self._send_json(code, {'error': message})

    def _send_no_content(self, code=204):
        self.send_response(code)
        # No body, so no Content-Type, no Content-Length
        self.end_headers()

    def _parse_json_body(self):
        length = self.headers.get('Content-Length')
        if not length:
            return {}
        try:
            n = int(length)
        except ValueError:
            self._send_error(400, 'Invalid Content-Length')
            return None
        try:
            data = self.rfile.read(n)
        except Exception:
            self._send_error(400, 'Failed to read request body')
            return None
        try:
            if not data:
                return {}
            obj = json.loads(data.decode('utf-8'))
            if not isinstance(obj, dict):
                self._send_error(400, 'Invalid JSON')
                return None
            return obj
        except json.JSONDecodeError:
            self._send_error(400, 'Invalid JSON')
            return None

    def _get_path_segments(self):
        path = urlparse(self.path).path
        if path == '/':
            return []
        if path.startswith('/'):
            path = path[1:]
        segs = [s for s in path.split('/') if s]
        return segs

    def _get_session_user_id(self):
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return None
        try:
            c = cookies.SimpleCookie()
            c.load(cookie_header)
            if 'session_id' not in c:
                return None
            token = c['session_id'].value
            if not token:
                return None
            uid = DB.get_user_id_by_session(token)
            return uid
        except Exception:
            return None

    def _require_auth(self):
        uid = self._get_session_user_id()
        if uid is None:
            self._send_error(401, 'Authentication required')
            return None
        return uid

    # HTTP method handlers
    def do_POST(self):
        try:
            segs = self._get_path_segments()
            if segs == ['register']:
                self._handle_register()
                return
            if segs == ['login']:
                self._handle_login()
                return
            if segs == ['logout']:
                self._handle_logout()
                return
            if segs == ['todos']:
                self._handle_todos_create()
                return
            # No matching endpoint
            self._send_error(404, 'Not Found')
        except Exception:
            # Avoid crashing the server due to unexpected errors
            self._send_error(500, 'Internal Server Error')

    def do_GET(self):
        try:
            segs = self._get_path_segments()
            if segs == ['me']:
                self._handle_me()
                return
            if segs == ['todos']:
                self._handle_todos_list()
                return
            if len(segs) == 2 and segs[0] == 'todos':
                self._handle_todo_get(segs[1])
                return
            self._send_error(404, 'Not Found')
        except Exception:
            self._send_error(500, 'Internal Server Error')

    def do_PUT(self):
        try:
            segs = self._get_path_segments()
            if segs == ['password']:
                self._handle_password_change()
                return
            if len(segs) == 2 and segs[0] == 'todos':
                self._handle_todo_update(segs[1])
                return
            self._send_error(404, 'Not Found')
        except Exception:
            self._send_error(500, 'Internal Server Error')

    def do_DELETE(self):
        try:
            segs = self._get_path_segments()
            if len(segs) == 2 and segs[0] == 'todos':
                self._handle_todo_delete(segs[1])
                return
            self._send_error(404, 'Not Found')
        except Exception:
            self._send_error(500, 'Internal Server Error')

    # Endpoint handlers
    def _handle_register(self):
        body = self._parse_json_body()
        if body is None:
            return
        username = body.get('username')
        password = body.get('password')
        if not isinstance(username, str) or not USERNAME_RE.match(username or ''):
            self._send_error(400, 'Invalid username')
            return
        if not isinstance(password, str) or len(password) < 8:
            self._send_error(400, 'Password too short')
            return
        user, err = DB.create_user(username, password)
        if err:
            self._send_error(409, 'Username already exists')
            return
        self._send_json(201, user)

    def _handle_login(self):
        body = self._parse_json_body()
        if body is None:
            return
        username = body.get('username')
        password = body.get('password')
        if not isinstance(username, str) or not isinstance(password, str):
            self._send_error(401, 'Invalid credentials')
            return
        user = DB.get_user_by_username(username)
        if not user or not verify_password(password, user['password']):
            self._send_error(401, 'Invalid credentials')
            return
        token = DB.create_session(user['id'])
        cookie_value = f'session_id={token}; Path=/; HttpOnly'
        self._send_json(200, {'id': user['id'], 'username': user['username']}, set_cookie=cookie_value)

    def _handle_logout(self):
        # Auth required
        cookie_header = self.headers.get('Cookie')
        token = None
        if cookie_header:
            try:
                c = cookies.SimpleCookie()
                c.load(cookie_header)
                if 'session_id' in c:
                    token = c['session_id'].value
            except Exception:
                token = None
        uid = self._require_auth()
        if uid is None:
            return
        if token:
            DB.invalidate_session(token)
        self._send_json(200, {})

    def _handle_me(self):
        uid = self._require_auth()
        if uid is None:
            return
        user_pub = DB.get_user_public(uid)
        if not user_pub:
            self._send_error(401, 'Authentication required')
            return
        self._send_json(200, user_pub)

    def _handle_password_change(self):
        uid = self._require_auth()
        if uid is None:
            return
        body = self._parse_json_body()
        if body is None:
            return
        old_password = body.get('old_password')
        new_password = body.get('new_password')
        if not isinstance(old_password, str) or not isinstance(new_password, str):
            self._send_error(400, 'Password too short')
            return
        # Verify old password
        user = DB.users_by_id.get(uid)
        if not user or not verify_password(old_password, user['password']):
            self._send_error(401, 'Invalid credentials')
            return
        if len(new_password) < 8:
            self._send_error(400, 'Password too short')
            return
        DB.set_user_password(uid, new_password)
        self._send_json(200, {})

    def _handle_todos_list(self):
        uid = self._require_auth()
        if uid is None:
            return
        todos = DB.list_todos_for_user(uid)
        self._send_json(200, todos)

    def _handle_todos_create(self):
        uid = self._require_auth()
        if uid is None:
            return
        body = self._parse_json_body()
        if body is None:
            return
        title = body.get('title')
        description = body.get('description', '')
        if not isinstance(title, str) or len(title) == 0:
            self._send_error(400, 'Title is required')
            return
        if not isinstance(description, str):
            self._send_error(400, 'Invalid JSON')
            return
        todo = DB.create_todo(uid, title, description)
        self._send_json(201, todo)

    def _parse_todo_id(self, seg):
        try:
            tid = int(seg)
            if tid <= 0:
                return None
            return tid
        except ValueError:
            return None

    def _handle_todo_get(self, seg):
        uid = self._require_auth()
        if uid is None:
            return
        tid = self._parse_todo_id(seg)
        if not tid:
            # Treat as not found to avoid enumeration/leak
            self._send_error(404, 'Todo not found')
            return
        todo = DB.get_todo_if_owned(uid, tid)
        if not todo:
            self._send_error(404, 'Todo not found')
            return
        self._send_json(200, todo)

    def _handle_todo_update(self, seg):
        uid = self._require_auth()
        if uid is None:
            return
        tid = self._parse_todo_id(seg)
        if not tid:
            self._send_error(404, 'Todo not found')
            return
        body = self._parse_json_body()
        if body is None:
            return
        fields = {}
        if 'title' in body:
            title = body['title']
            if not isinstance(title, str) or len(title) == 0:
                self._send_error(400, 'Title is required')
                return
            fields['title'] = title
        if 'description' in body:
            desc = body['description']
            if not isinstance(desc, str):
                self._send_error(400, 'Invalid JSON')
                return
            fields['description'] = desc
        if 'completed' in body:
            comp = body['completed']
            if not isinstance(comp, bool):
                self._send_error(400, 'Invalid JSON')
                return
            fields['completed'] = comp
        todo = DB.update_todo_if_owned(uid, tid, fields)
        if not todo:
            self._send_error(404, 'Todo not found')
            return
        self._send_json(200, todo)

    def _handle_todo_delete(self, seg):
        uid = self._require_auth()
        if uid is None:
            return
        tid = self._parse_todo_id(seg)
        if not tid:
            self._send_error(404, 'Todo not found')
            return
        ok = DB.delete_todo_if_owned(uid, tid)
        if not ok:
            self._send_error(404, 'Todo not found')
            return
        self._send_no_content(204)


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    server_address = ('0.0.0.0', args.port)
    httpd = ThreadingHTTPServer(server_address, TodoHandler)
    try:
        print(f'Serving on 0.0.0.0:{args.port}', flush=True)
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == '__main__':
    main()
