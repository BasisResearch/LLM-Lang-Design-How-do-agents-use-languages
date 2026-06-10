#!/usr/bin/env python3
import argparse
import http.server
import json
import re
import threading
import uuid
from datetime import datetime, timezone
from urllib.parse import urlparse

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")

def now_utc_iso_seconds():
    # Format: YYYY-MM-DDTHH:MM:SSZ
    return datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

class InMemoryDB:
    def __init__(self):
        self.lock = threading.RLock()
        self.users_by_id = {}
        self.usernames = {}  # username -> id
        self.next_user_id = 1

        self.todos_by_id = {}
        self.user_todos = {}  # user_id -> list of todo ids
        self.next_todo_id = 1

        self.sessions = {}  # session_id -> user_id

    def create_user(self, username, password):
        with self.lock:
            if username in self.usernames:
                return None
            user_id = self.next_user_id
            self.next_user_id += 1
            user = {
                'id': user_id,
                'username': username,
                'password': password,  # stored as plain text per minimal spec
            }
            self.users_by_id[user_id] = user
            self.usernames[username] = user_id
            return {'id': user_id, 'username': username}

    def get_user_by_username(self, username):
        with self.lock:
            uid = self.usernames.get(username)
            if uid is None:
                return None
            u = self.users_by_id.get(uid)
            if u is None:
                return None
            return dict(u)

    def get_user_by_id(self, user_id):
        with self.lock:
            u = self.users_by_id.get(user_id)
            if u is None:
                return None
            return dict(u)

    def set_password(self, user_id, new_password):
        with self.lock:
            if user_id not in self.users_by_id:
                return False
            self.users_by_id[user_id]['password'] = new_password
            return True

    def create_session(self, user_id):
        with self.lock:
            token = uuid.uuid4().hex
            self.sessions[token] = user_id
            return token

    def get_user_id_by_session(self, token):
        with self.lock:
            return self.sessions.get(token)

    def invalidate_session(self, token):
        with self.lock:
            if token in self.sessions:
                del self.sessions[token]
                return True
            return False

    def create_todo(self, user_id, title, description=""):
        with self.lock:
            todo_id = self.next_todo_id
            self.next_todo_id += 1
            ts = now_utc_iso_seconds()
            todo = {
                'id': todo_id,
                'title': title,
                'description': description or "",
                'completed': False,
                'created_at': ts,
                'updated_at': ts,
                'owner_id': user_id,
            }
            self.todos_by_id[todo_id] = todo
            self.user_todos.setdefault(user_id, []).append(todo_id)
            return self._public_todo(todo)

    def list_todos(self, user_id):
        with self.lock:
            ids = sorted(self.user_todos.get(user_id, []))
            return [self._public_todo(self.todos_by_id[i]) for i in ids if i in self.todos_by_id]

    def get_todo_for_user(self, user_id, todo_id):
        with self.lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo or todo.get('owner_id') != user_id:
                return None
            return self._public_todo(todo)

    def update_todo_for_user(self, user_id, todo_id, fields):
        with self.lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo or todo.get('owner_id') != user_id:
                return None
            changed = False
            if 'title' in fields:
                todo['title'] = fields['title']
                changed = True
            if 'description' in fields:
                todo['description'] = fields['description'] if fields['description'] is not None else ""
                changed = True
            if 'completed' in fields:
                todo['completed'] = bool(fields['completed'])
                changed = True
            if changed:
                todo['updated_at'] = now_utc_iso_seconds()
            return self._public_todo(todo)

    def delete_todo_for_user(self, user_id, todo_id):
        with self.lock:
            todo = self.todos_by_id.get(todo_id)
            if not todo or todo.get('owner_id') != user_id:
                return False
            del self.todos_by_id[todo_id]
            if user_id in self.user_todos:
                try:
                    self.user_todos[user_id].remove(todo_id)
                except ValueError:
                    pass
            return True

    def _public_todo(self, todo):
        return {
            'id': todo['id'],
            'title': todo['title'],
            'description': todo['description'],
            'completed': todo['completed'],
            'created_at': todo['created_at'],
            'updated_at': todo['updated_at'],
        }

DB = InMemoryDB()

class TodoHandler(http.server.BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    def log_message(self, format, *args):
        # Simpler logging
        return super().log_message(format, *args)

    # Utility methods
    def parse_json_body(self):
        length = self.headers.get('Content-Length')
        if not length:
            return None
        try:
            n = int(length)
        except ValueError:
            n = 0
        if n <= 0:
            return None
        raw = self.rfile.read(n)
        if not raw:
            return None
        try:
            return json.loads(raw.decode('utf-8'))
        except Exception:
            return None

    def send_json(self, code, obj, extra_headers=None):
        body = json.dumps(obj, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_no_content(self):
        self.send_response(204)
        # Do not send Content-Type for DELETE per spec; also no body
        self.send_header('Content-Length', '0')
        self.end_headers()

    def parse_cookies(self):
        cookies = {}
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return cookies
        parts = cookie_header.split(';')
        for part in parts:
            if '=' in part:
                name, value = part.split('=', 1)
                cookies[name.strip()] = value.strip()
        return cookies

    def require_auth(self):
        cookies = self.parse_cookies()
        token = cookies.get('session_id')
        if not token:
            self.send_json(401, {"error": "Authentication required"})
            return None, None
        user_id = DB.get_user_id_by_session(token)
        if not user_id:
            self.send_json(401, {"error": "Authentication required"})
            return None, None
        user = DB.get_user_by_id(user_id)
        if not user:
            # Invalidate stale session
            DB.invalidate_session(token)
            self.send_json(401, {"error": "Authentication required"})
            return None, None
        return token, user

    # Request handlers
    def do_POST(self):
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
        self.send_json(404, {"error": "Not found"})

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/me':
            return self.handle_me()
        if path == '/todos':
            return self.handle_list_todos()
        # /todos/:id
        m = re.match(r'^/todos/(\d+)$', path)
        if m:
            return self.handle_get_todo(int(m.group(1)))
        self.send_json(404, {"error": "Not found"})

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/password':
            return self.handle_change_password()
        m = re.match(r'^/todos/(\d+)$', path)
        if m:
            return self.handle_update_todo(int(m.group(1)))
        self.send_json(404, {"error": "Not found"})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path
        m = re.match(r'^/todos/(\d+)$', path)
        if m:
            return self.handle_delete_todo(int(m.group(1)))
        self.send_json(404, {"error": "Not found"})

    # Endpoint implementations
    def handle_register(self):
        data = self.parse_json_body() or {}
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not USERNAME_RE.match(username):
            return self.send_json(400, {"error": "Invalid username"})
        if not isinstance(password, str) or len(password) < 8:
            return self.send_json(400, {"error": "Password too short"})
        created = DB.create_user(username, password)
        if created is None:
            return self.send_json(409, {"error": "Username already exists"})
        return self.send_json(201, created)

    def handle_login(self):
        data = self.parse_json_body() or {}
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not isinstance(password, str):
            return self.send_json(401, {"error": "Invalid credentials"})
        user = DB.get_user_by_username(username)
        if not user or user.get('password') != password:
            return self.send_json(401, {"error": "Invalid credentials"})
        token = DB.create_session(user['id'])
        headers = {
            'Set-Cookie': f'session_id={token}; Path=/; HttpOnly'
        }
        public_user = {'id': user['id'], 'username': user['username']}
        return self.send_json(200, public_user, extra_headers=headers)

    def handle_logout(self):
        token, user = self.require_auth()
        if not user:
            return  # response already sent
        # Invalidate the session
        DB.invalidate_session(token)
        return self.send_json(200, {})

    def handle_me(self):
        token, user = self.require_auth()
        if not user:
            return
        public_user = {'id': user['id'], 'username': user['username']}
        return self.send_json(200, public_user)

    def handle_change_password(self):
        token, user = self.require_auth()
        if not user:
            return
        data = self.parse_json_body() or {}
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        if not isinstance(old_password, str) or user.get('password') != old_password:
            return self.send_json(401, {"error": "Invalid credentials"})
        if not isinstance(new_password, str) or len(new_password) < 8:
            return self.send_json(400, {"error": "Password too short"})
        DB.set_password(user['id'], new_password)
        return self.send_json(200, {})

    def handle_list_todos(self):
        token, user = self.require_auth()
        if not user:
            return
        todos = DB.list_todos(user['id'])
        return self.send_json(200, todos)

    def handle_create_todo(self):
        token, user = self.require_auth()
        if not user:
            return
        data = self.parse_json_body() or {}
        title = data.get('title')
        description = data.get('description', "")
        if not isinstance(title, str) or title.strip() == '':
            return self.send_json(400, {"error": "Title is required"})
        todo = DB.create_todo(user['id'], title, description)
        return self.send_json(201, todo)

    def handle_get_todo(self, todo_id):
        token, user = self.require_auth()
        if not user:
            return
        todo = DB.get_todo_for_user(user['id'], todo_id)
        if not todo:
            return self.send_json(404, {"error": "Todo not found"})
        return self.send_json(200, todo)

    def handle_update_todo(self, todo_id):
        token, user = self.require_auth()
        if not user:
            return
        data = self.parse_json_body() or {}
        fields = {}
        if 'title' in data:
            if not isinstance(data['title'], str) or data['title'].strip() == '':
                return self.send_json(400, {"error": "Title is required"})
            fields['title'] = data['title']
        if 'description' in data:
            # description optional; allow non-str by converting to str?
            # Spec doesn't define; we'll ensure it's a string if provided
            desc = data['description']
            if desc is None:
                desc = ""
            elif not isinstance(desc, str):
                desc = str(desc)
            fields['description'] = desc
        if 'completed' in data:
            comp = data['completed']
            if isinstance(comp, bool):
                fields['completed'] = comp
            else:
                # Coerce truthy/falsy
                if isinstance(comp, str):
                    lc = comp.lower().strip()
                    if lc in ('true','1','yes','y','on'):
                        compv = True
                    elif lc in ('false','0','no','n','off'):
                        compv = False
                    else:
                        compv = bool(comp)
                else:
                    compv = bool(comp)
                fields['completed'] = compv
        updated = DB.update_todo_for_user(user['id'], todo_id, fields)
        if not updated:
            return self.send_json(404, {"error": "Todo not found"})
        return self.send_json(200, updated)

    def handle_delete_todo(self, todo_id):
        token, user = self.require_auth()
        if not user:
            return
        ok = DB.delete_todo_for_user(user['id'], todo_id)
        if not ok:
            return self.send_json(404, {"error": "Todo not found"})
        return self.send_no_content()


def run_server(port):
    server_address = ('0.0.0.0', port)
    httpd = http.server.ThreadingHTTPServer(server_address, TodoHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to listen on')
    args = parser.parse_args()
    run_server(args.port)
