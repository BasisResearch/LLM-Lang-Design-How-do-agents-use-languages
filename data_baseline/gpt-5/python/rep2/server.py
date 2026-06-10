#!/usr/bin/env python3
import argparse
import json
import re
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from http import cookies
from datetime import datetime, timezone
import uuid

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')

def iso_utc_now():
    # Second precision, UTC, with Z
    return datetime.now(timezone.utc).replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')

class InMemoryStore:
    def __init__(self):
        self.lock = threading.RLock()
        self.next_user_id = 1
        self.next_todo_id = 1
        # users by username and id
        self.users_by_username = {}
        self.users_by_id = {}
        # password storage in plain text (for demo only)
        self.password_by_user_id = {}
        # sessions: token -> user_id
        self.sessions = {}
        # todos: id -> todo dict with owner_id
        self.todos_by_id = {}
        # per-user index: user_id -> set/list of todo ids
        self.todo_ids_by_user = {}

    def create_user(self, username, password):
        with self.lock:
            if username in self.users_by_username:
                return None, 'exists'
            user_id = self.next_user_id
            self.next_user_id += 1
            user = { 'id': user_id, 'username': username }
            self.users_by_username[username] = user
            self.users_by_id[user_id] = user
            self.password_by_user_id[user_id] = password
            return user, None

    def authenticate(self, username, password):
        with self.lock:
            user = self.users_by_username.get(username)
            if not user:
                return None
            uid = user['id']
            if self.password_by_user_id.get(uid) != password:
                return None
            return user

    def create_session(self, user_id):
        with self.lock:
            token = uuid.uuid4().hex
            self.sessions[token] = user_id
            return token

    def get_user_by_session(self, token):
        with self.lock:
            uid = self.sessions.get(token)
            if uid is None:
                return None
            return self.users_by_id.get(uid)

    def invalidate_session(self, token):
        with self.lock:
            if token in self.sessions:
                del self.sessions[token]
                return True
            return False

    def change_password(self, user_id, new_password):
        with self.lock:
            self.password_by_user_id[user_id] = new_password

    def list_todos_for_user(self, user_id):
        with self.lock:
            ids = sorted(self.todo_ids_by_user.get(user_id, []))
            return [self._public_todo(self.todos_by_id[i]) for i in ids]

    def _public_todo(self, todo):
        # return a copy without owner_id
        return {
            'id': todo['id'],
            'title': todo['title'],
            'description': todo['description'],
            'completed': todo['completed'],
            'created_at': todo['created_at'],
            'updated_at': todo['updated_at'],
        }

    def create_todo(self, user_id, title, description):
        with self.lock:
            tid = self.next_todo_id
            self.next_todo_id += 1
            now = iso_utc_now()
            todo = {
                'id': tid,
                'owner_id': user_id,
                'title': title,
                'description': description,
                'completed': False,
                'created_at': now,
                'updated_at': now,
            }
            self.todos_by_id[tid] = todo
            self.todo_ids_by_user.setdefault(user_id, []).append(tid)
            return self._public_todo(todo)

    def get_todo_for_user(self, user_id, todo_id):
        with self.lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo or todo['owner_id'] != user_id:
                return None
            return self._public_todo(todo)

    def update_todo_for_user(self, user_id, todo_id, fields):
        with self.lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo or todo['owner_id'] != user_id:
                return None
            updated = False
            if 'title' in fields:
                todo['title'] = fields['title']
                updated = True
            if 'description' in fields:
                todo['description'] = fields['description']
                updated = True
            if 'completed' in fields:
                todo['completed'] = bool(fields['completed'])
                updated = True
            if updated:
                todo['updated_at'] = iso_utc_now()
            return self._public_todo(todo)

    def delete_todo_for_user(self, user_id, todo_id):
        with self.lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo or todo['owner_id'] != user_id:
                return False
            del self.todos_by_id[todo_id]
            if user_id in self.todo_ids_by_user:
                try:
                    self.todo_ids_by_user[user_id].remove(todo_id)
                except ValueError:
                    pass
            return True


data_store = InMemoryStore()

class JSONRequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    def _read_json(self):
        length = int(self.headers.get('Content-Length', 0) or 0)
        if length == 0:
            return None, None
        try:
            raw = self.rfile.read(length)
        except Exception:
            return None, 'Invalid request body'
        try:
            text = raw.decode('utf-8')
            obj = json.loads(text)
            return obj, None
        except Exception:
            return None, 'Invalid JSON'

    def _send_json(self, code, obj, set_cookie=None):
        body = json.dumps(obj).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        if set_cookie is not None:
            self.send_header('Set-Cookie', set_cookie)
        self.end_headers()
        self.wfile.write(body)

    def _send_no_content(self, code=204):
        self.send_response(code)
        # We can still send Content-Type for consistency though body is empty
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def _error(self, code, message):
        self._send_json(code, { 'error': message })

    def _parse_path(self):
        parsed = urlparse(self.path)
        return parsed.path

    def _require_auth(self):
        # returns user or None; if None, also sends 401
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            self._error(401, 'Authentication required')
            return None, None
        try:
            c = cookies.SimpleCookie()
            c.load(cookie_header)
        except Exception:
            self._error(401, 'Authentication required')
            return None, None
        if 'session_id' not in c:
            self._error(401, 'Authentication required')
            return None, None
        token = c['session_id'].value
        user = data_store.get_user_by_session(token)
        if not user:
            self._error(401, 'Authentication required')
            return None, None
        return user, token

    # Handlers for endpoints
    def do_POST(self):
        path = self._parse_path()
        if path == '/register':
            self.handle_register()
            return
        if path == '/login':
            self.handle_login()
            return
        if path == '/logout':
            user, token = self._require_auth()
            if not user:
                return
            # Invalidate session
            data_store.invalidate_session(token)
            self._send_json(200, {})
            return
        if path == '/todos':
            user, _ = self._require_auth()
            if not user:
                return
            self.handle_create_todo(user)
            return
        # Not found
        self._error(404, 'Not found')

    def do_GET(self):
        path = self._parse_path()
        if path == '/me':
            user, _ = self._require_auth()
            if not user:
                return
            self._send_json(200, { 'id': user['id'], 'username': user['username'] })
            return
        if path == '/todos':
            user, _ = self._require_auth()
            if not user:
                return
            todos = data_store.list_todos_for_user(user['id'])
            self._send_json(200, todos)
            return
        if path.startswith('/todos/'):
            user, _ = self._require_auth()
            if not user:
                return
            tid_str = path[len('/todos/'):]
            try:
                tid = int(tid_str)
            except ValueError:
                self._error(404, 'Todo not found')
                return
            todo = data_store.get_todo_for_user(user['id'], tid)
            if not todo:
                self._error(404, 'Todo not found')
                return
            self._send_json(200, todo)
            return
        if path == '/login' or path == '/register' or path == '/logout' or path == '/password':
            # Method not allowed
            self._error(405, 'Method Not Allowed')
            return
        self._error(404, 'Not found')

    def do_PUT(self):
        path = self._parse_path()
        if path == '/password':
            user, _ = self._require_auth()
            if not user:
                return
            self.handle_password_change(user)
            return
        if path.startswith('/todos/'):
            user, _ = self._require_auth()
            if not user:
                return
            tid_str = path[len('/todos/'):]
            try:
                tid = int(tid_str)
            except ValueError:
                self._error(404, 'Todo not found')
                return
            self.handle_update_todo(user, tid)
            return
        self._error(404, 'Not found')

    def do_DELETE(self):
        path = self._parse_path()
        if path.startswith('/todos/'):
            user, _ = self._require_auth()
            if not user:
                return
            tid_str = path[len('/todos/'):]
            try:
                tid = int(tid_str)
            except ValueError:
                self._error(404, 'Todo not found')
                return
            ok = data_store.delete_todo_for_user(user['id'], tid)
            if not ok:
                self._error(404, 'Todo not found')
                return
            self._send_no_content(204)
            return
        self._error(404, 'Not found')

    # Endpoint implementations
    def handle_register(self):
        body, err = self._read_json()
        if err is not None:
            self._error(400, err)
            return
        if not isinstance(body, dict):
            self._error(400, 'Invalid JSON')
            return
        username = body.get('username')
        password = body.get('password')
        if not isinstance(username, str) or not USERNAME_RE.match(username):
            self._error(400, 'Invalid username')
            return
        if not isinstance(password, str) or len(password) < 8:
            self._error(400, 'Password too short')
            return
        user, status = data_store.create_user(username, password)
        if status == 'exists':
            self._error(409, 'Username already exists')
            return
        self._send_json(201, { 'id': user['id'], 'username': user['username'] })

    def handle_login(self):
        body, err = self._read_json()
        if err is not None:
            # For login, treat invalid json as invalid credentials? Spec says invalid credentials for wrong pass/username
            self._error(401, 'Invalid credentials')
            return
        if not isinstance(body, dict):
            self._error(401, 'Invalid credentials')
            return
        username = body.get('username')
        password = body.get('password')
        if not isinstance(username, str) or not isinstance(password, str):
            self._error(401, 'Invalid credentials')
            return
        user = data_store.authenticate(username, password)
        if not user:
            self._error(401, 'Invalid credentials')
            return
        token = data_store.create_session(user['id'])
        set_cookie = f"session_id={token}; Path=/; HttpOnly"
        self._send_json(200, { 'id': user['id'], 'username': user['username'] }, set_cookie=set_cookie)

    def handle_password_change(self, user):
        body, err = self._read_json()
        if err is not None:
            self._error(400, err)
            return
        if not isinstance(body, dict):
            self._error(400, 'Invalid JSON')
            return
        old = body.get('old_password')
        new = body.get('new_password')
        if not isinstance(old, str) or data_store.password_by_user_id.get(user['id']) != old:
            self._error(401, 'Invalid credentials')
            return
        if not isinstance(new, str) or len(new) < 8:
            self._error(400, 'Password too short')
            return
        data_store.change_password(user['id'], new)
        self._send_json(200, {})

    def handle_create_todo(self, user):
        body, err = self._read_json()
        if err is not None:
            self._error(400, err)
            return
        if not isinstance(body, dict):
            self._error(400, 'Invalid JSON')
            return
        title = body.get('title')
        description = body.get('description', '')
        if not isinstance(title, str) or title.strip() == '':
            self._error(400, 'Title is required')
            return
        if not isinstance(description, str):
            # Coerce non-string to string representation
            description = str(description)
        todo = data_store.create_todo(user['id'], title, description)
        self._send_json(201, todo)

    def handle_update_todo(self, user, todo_id):
        body, err = self._read_json()
        if err is not None:
            self._error(400, err)
            return
        if not isinstance(body, dict):
            self._error(400, 'Invalid JSON')
            return
        # First ensure todo exists and belongs to user
        existing = data_store.get_todo_for_user(user['id'], todo_id)
        if not existing:
            self._error(404, 'Todo not found')
            return
        fields = {}
        if 'title' in body:
            title = body.get('title')
            if not isinstance(title, str) or title.strip() == '':
                self._error(400, 'Title is required')
                return
            fields['title'] = title
        if 'description' in body:
            desc = body.get('description')
            if not isinstance(desc, str):
                desc = str(desc)
            fields['description'] = desc
        if 'completed' in body:
            fields['completed'] = bool(body.get('completed'))
        updated = data_store.update_todo_for_user(user['id'], todo_id, fields)
        if not updated:
            # Should not happen as we checked ownership, but handle gracefully
            self._error(404, 'Todo not found')
            return
        self._send_json(200, updated)

    # Ensure no default logging to stderr to keep test output clean
    def log_message(self, format, *args):
        return


def run(host, port):
    server_address = (host, port)
    httpd = ThreadingHTTPServer(server_address, JSONRequestHandler)
    print(f"Serving on http://{host}:{port}")
    httpd.serve_forever()


def main():
    parser = argparse.ArgumentParser(description='Todo App REST API server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    run('0.0.0.0', args.port)

if __name__ == '__main__':
    main()
