#!/usr/bin/env python3
import argparse
import http.server
import json
import re
import threading
import uuid
from urllib.parse import urlparse
from datetime import datetime, timezone

# In-memory data stores
USERS = {}  # user_id -> {id, username, password_hash}
USERNAMES = {}  # username -> user_id
USER_ID_COUNTER = 1

SESSIONS = {}  # session_token -> user_id

TODOS = {}  # todo_id -> {id, user_id, title, description, completed, created_at, updated_at}
TODO_ID_COUNTER = 1

# Locks for thread-safety
users_lock = threading.Lock()
sessions_lock = threading.Lock()
todos_lock = threading.Lock()
counters_lock = threading.Lock()

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')


def now_iso8601_utc_seconds():
    # Return ISO 8601 UTC timestamp with seconds precision and trailing Z
    return datetime.utcnow().replace(microsecond=0).isoformat() + 'Z'


def hash_password(pw: str) -> str:
    # Simple SHA256 hashing with static salt (in-memory only). Not intended for production crypto strength
    import hashlib
    salt = b"todo_app_salt_v1"
    h = hashlib.sha256()
    h.update(salt)
    h.update(pw.encode('utf-8'))
    return h.hexdigest()


def parse_json_body(handler: http.server.BaseHTTPRequestHandler):
    length = handler.headers.get('Content-Length')
    if not length:
        return None, 'Invalid JSON'
    try:
        n = int(length)
    except Exception:
        return None, 'Invalid JSON'
    try:
        raw = handler.rfile.read(n)
    except Exception:
        return None, 'Invalid JSON'
    try:
        data = json.loads(raw.decode('utf-8'))
        if not isinstance(data, dict):
            return None, 'Invalid JSON'
        return data, None
    except Exception:
        return None, 'Invalid JSON'


def get_cookie(handler: http.server.BaseHTTPRequestHandler, name: str):
    cookie = handler.headers.get('Cookie') or handler.headers.get('cookie')
    if not cookie:
        return None
    # Parse simple cookie header: key=value; key2=value2
    parts = [p.strip() for p in cookie.split(';') if p.strip()]
    for p in parts:
        if '=' in p:
            k, v = p.split('=', 1)
            if k.strip() == name:
                return v
    return None


class TodoHandler(http.server.BaseHTTPRequestHandler):
    server_version = "TodoHTTP/1.0"

    def log_message(self, format, *args):
        # Keep default logging; could be silenced by overriding
        super().log_message(format, *args)

    # Helper to write JSON response
    def send_json(self, status_code: int, obj: dict, extra_headers: dict | None = None):
        body = json.dumps(obj).encode('utf-8')
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_no_content(self):
        # For DELETE 204 with no body and no Content-Type per spec
        self.send_response(204)
        self.end_headers()

    def send_error_json(self, status_code: int, message: str):
        self.send_json(status_code, {"error": message})

    # Authentication
    def require_auth(self):
        token = get_cookie(self, 'session_id')
        if not token:
            self.send_error_json(401, 'Authentication required')
            return None, None
        with sessions_lock:
            uid = SESSIONS.get(token)
        if not uid:
            self.send_error_json(401, 'Authentication required')
            return None, None
        # Fetch user object
        with users_lock:
            user = USERS.get(uid)
        if not user:
            # Should not happen; invalidate session just in case
            with sessions_lock:
                SESSIONS.pop(token, None)
            self.send_error_json(401, 'Authentication required')
            return None, None
        return token, user

    # Routing
    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/register':
            return self.handle_register()
        elif path == '/login':
            return self.handle_login()
        elif path == '/logout':
            return self.handle_logout()
        elif path == '/todos':
            return self.handle_todos_create()
        else:
            self.send_error_json(404, 'Not found')

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/me':
            return self.handle_me()
        elif path == '/todos':
            return self.handle_todos_list()
        else:
            m = re.match(r'^/todos/(\d+)$', path)
            if m:
                todo_id = int(m.group(1))
                return self.handle_todos_get(todo_id)
            self.send_error_json(404, 'Not found')

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/password':
            return self.handle_password_change()
        else:
            m = re.match(r'^/todos/(\d+)$', path)
            if m:
                todo_id = int(m.group(1))
                return self.handle_todos_update(todo_id)
            self.send_error_json(404, 'Not found')

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path
        m = re.match(r'^/todos/(\d+)$', path)
        if m:
            todo_id = int(m.group(1))
            return self.handle_todos_delete(todo_id)
        self.send_error_json(404, 'Not found')

    # Endpoint handlers
    def handle_register(self):
        data, err = parse_json_body(self)
        if err:
            return self.send_error_json(400, err)
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
            return self.send_error_json(400, 'Invalid username')
        if not isinstance(password, str) or len(password) < 8:
            return self.send_error_json(400, 'Password too short')
        with users_lock:
            if username in USERNAMES:
                return self.send_error_json(409, 'Username already exists')
            global USER_ID_COUNTER
            uid = USER_ID_COUNTER
            USER_ID_COUNTER += 1
            user = {
                'id': uid,
                'username': username,
                'password_hash': hash_password(password),
            }
            USERS[uid] = user
            USERNAMES[username] = uid
        return self.send_json(201, {'id': uid, 'username': username})

    def handle_login(self):
        data, err = parse_json_body(self)
        if err:
            return self.send_error_json(401, 'Invalid credentials')
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not isinstance(password, str):
            return self.send_error_json(401, 'Invalid credentials')
        with users_lock:
            uid = USERNAMES.get(username)
            if not uid:
                return self.send_error_json(401, 'Invalid credentials')
            user = USERS.get(uid)
        if not user or user.get('password_hash') != hash_password(password):
            return self.send_error_json(401, 'Invalid credentials')
        token = uuid.uuid4().hex
        with sessions_lock:
            SESSIONS[token] = user['id']
        headers = {'Set-Cookie': f'session_id={token}; Path=/; HttpOnly'}
        return self.send_json(200, {'id': user['id'], 'username': user['username']}, extra_headers=headers)

    def handle_logout(self):
        token, user = self.require_auth()
        if not user:
            return
        with sessions_lock:
            SESSIONS.pop(token, None)
        return self.send_json(200, {})

    def handle_me(self):
        token, user = self.require_auth()
        if not user:
            return
        return self.send_json(200, {'id': user['id'], 'username': user['username']})

    def handle_password_change(self):
        token, user = self.require_auth()
        if not user:
            return
        data, err = parse_json_body(self)
        if err:
            return self.send_error_json(400, err)
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        if not isinstance(old_password, str) or hash_password(old_password) != user.get('password_hash'):
            return self.send_error_json(401, 'Invalid credentials')
        if not isinstance(new_password, str) or len(new_password) < 8:
            return self.send_error_json(400, 'Password too short')
        with users_lock:
            # Refresh from USERS to avoid race
            u = USERS.get(user['id'])
            if not u:
                return self.send_error_json(401, 'Authentication required')
            u['password_hash'] = hash_password(new_password)
        return self.send_json(200, {})

    def handle_todos_list(self):
        token, user = self.require_auth()
        if not user:
            return
        uid = user['id']
        with todos_lock:
            todos = [self._todo_public_repr(t) for t in sorted((t for t in TODOS.values() if t['user_id'] == uid), key=lambda x: x['id'])]
        return self.send_json(200, todos)

    def handle_todos_create(self):
        token, user = self.require_auth()
        if not user:
            return
        data, err = parse_json_body(self)
        if err:
            return self.send_error_json(400, err)
        title = data.get('title')
        description = data.get('description', '')
        if title is None or not isinstance(title, str) or title.strip() == '':
            return self.send_error_json(400, 'Title is required')
        if not isinstance(description, str):
            description = str(description)
        created = now_iso8601_utc_seconds()
        with todos_lock:
            global TODO_ID_COUNTER
            tid = TODO_ID_COUNTER
            TODO_ID_COUNTER += 1
            todo = {
                'id': tid,
                'user_id': user['id'],
                'title': title,
                'description': description,
                'completed': False,
                'created_at': created,
                'updated_at': created,
            }
            TODOS[tid] = todo
            pub = self._todo_public_repr(todo)
        return self.send_json(201, pub)

    def handle_todos_get(self, todo_id: int):
        token, user = self.require_auth()
        if not user:
            return
        with todos_lock:
            todo = TODOS.get(todo_id)
            if not todo or todo['user_id'] != user['id']:
                return self.send_error_json(404, 'Todo not found')
            pub = self._todo_public_repr(todo)
        return self.send_json(200, pub)

    def handle_todos_update(self, todo_id: int):
        token, user = self.require_auth()
        if not user:
            return
        data, err = parse_json_body(self)
        if err:
            return self.send_error_json(400, err)
        with todos_lock:
            todo = TODOS.get(todo_id)
            if not todo or todo['user_id'] != user['id']:
                return self.send_error_json(404, 'Todo not found')
            # Partial update
            if 'title' in data:
                title = data.get('title')
                if not isinstance(title, str) or title.strip() == '':
                    return self.send_error_json(400, 'Title is required')
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
                    # If provided but not boolean, reject with 400
                    return self.send_error_json(400, 'Invalid request')
            todo['updated_at'] = now_iso8601_utc_seconds()
            pub = self._todo_public_repr(todo)
        return self.send_json(200, pub)

    def handle_todos_delete(self, todo_id: int):
        token, user = self.require_auth()
        if not user:
            return
        with todos_lock:
            todo = TODOS.get(todo_id)
            if not todo or todo['user_id'] != user['id']:
                return self.send_error_json(404, 'Todo not found')
            TODOS.pop(todo_id, None)
        return self.send_no_content()

    def _todo_public_repr(self, todo: dict) -> dict:
        return {
            'id': todo['id'],
            'title': todo['title'],
            'description': todo['description'],
            'completed': todo['completed'],
            'created_at': todo['created_at'],
            'updated_at': todo['updated_at'],
        }


def run_server(port: int):
    handler = TodoHandler
    # ThreadingHTTPServer provides simple concurrency
    class ThreadingHTTPServer(http.server.ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = True
    with ThreadingHTTPServer(("0.0.0.0", port), handler) as httpd:
        httpd.serve_forever()


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    run_server(args.port)


if __name__ == '__main__':
    main()
