#!/usr/bin/env python3
import argparse
import json
import re
import threading
from http import HTTPStatus
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import uuid
from datetime import datetime, timezone

# In-memory storage with simple thread-safety
class InMemoryStore:
    def __init__(self):
        self.lock = threading.RLock()
        self.next_user_id = 1
        self.users_by_id = {}
        self.users_by_username = {}
        self.sessions = {}  # session_id -> user_id
        self.next_todo_id = 1
        self.todos_by_id = {}  # todo_id -> todo dict with user_id

    # Utility methods
    def _now_iso(self):
        return datetime.utcnow().replace(microsecond=0, tzinfo=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

    # User related operations
    def create_user(self, username, password):
        with self.lock:
            if username in self.users_by_username:
                return None, 'exists'
            uid = self.next_user_id
            self.next_user_id += 1
            user = {"id": uid, "username": username, "password": password}
            self.users_by_id[uid] = user
            self.users_by_username[username] = uid
            return {"id": uid, "username": username}, None

    def get_user_by_username(self, username):
        with self.lock:
            uid = self.users_by_username.get(username)
            if not uid:
                return None
            u = self.users_by_id.get(uid)
            if not u:
                return None
            return {"id": u["id"], "username": u["username"], "password": u["password"]}

    def get_user_public(self, user_id):
        with self.lock:
            u = self.users_by_id.get(user_id)
            if not u:
                return None
            return {"id": u["id"], "username": u["username"]}

    def update_user_password(self, user_id, new_password):
        with self.lock:
            u = self.users_by_id.get(user_id)
            if not u:
                return False
            u["password"] = new_password
            return True

    # Session operations
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

    # Todo operations
    def list_todos_for_user(self, user_id):
        with self.lock:
            todos = [t for t in self.todos_by_id.values() if t["user_id"] == user_id]
            todos.sort(key=lambda x: x["id"])  # order by id ascending
            # strip user_id for output
            return [self._public_todo(t) for t in todos]

    def create_todo(self, user_id, title, description):
        with self.lock:
            tid = self.next_todo_id
            self.next_todo_id += 1
            now = self._now_iso()
            todo = {
                "id": tid,
                "user_id": user_id,
                "title": title,
                "description": description if description is not None else "",
                "completed": False,
                "created_at": now,
                "updated_at": now,
            }
            self.todos_by_id[tid] = todo
            return self._public_todo(todo)

    def get_todo_for_user(self, user_id, todo_id):
        with self.lock:
            t = self.todos_by_id.get(todo_id)
            if not t or t["user_id"] != user_id:
                return None
            return self._public_todo(t)

    def update_todo_for_user(self, user_id, todo_id, fields):
        with self.lock:
            t = self.todos_by_id.get(todo_id)
            if not t or t["user_id"] != user_id:
                return None, 'not_found'
            # Only update provided fields
            if 'title' in fields:
                t['title'] = fields['title']
            if 'description' in fields:
                t['description'] = fields['description'] if fields['description'] is not None else ""
            if 'completed' in fields:
                t['completed'] = bool(fields['completed'])
            t['updated_at'] = self._now_iso()
            return self._public_todo(t), None

    def delete_todo_for_user(self, user_id, todo_id):
        with self.lock:
            t = self.todos_by_id.get(todo_id)
            if not t or t["user_id"] != user_id:
                return False
            del self.todos_by_id[todo_id]
            return True

    def _public_todo(self, t):
        return {
            "id": t["id"],
            "title": t["title"],
            "description": t["description"],
            "completed": t["completed"],
            "created_at": t["created_at"],
            "updated_at": t["updated_at"],
        }

store = InMemoryStore()

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')

class TodoRequestHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    # Ensure we don't print to stderr noisily
    def log_message(self, format, *args):
        return

    # Helper methods
    def parse_json_body(self):
        length = self.headers.get('Content-Length')
        if length is None:
            return None, None  # treat as no body
        try:
            n = int(length)
        except ValueError:
            return None, 'Invalid Content-Length'
        try:
            raw = self.rfile.read(n)
        except Exception:
            return None, 'Failed to read body'
        if not raw:
            return None, None
        try:
            data = json.loads(raw.decode('utf-8'))
        except Exception:
            return None, 'Invalid JSON'
        return data, None

    def send_json(self, code, obj, set_cookie=None):
        body = json.dumps(obj).encode('utf-8')
        self.send_response(code)
        if set_cookie:
            self.send_header('Set-Cookie', set_cookie)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, code, message):
        self.send_json(code, {"error": message})

    def send_no_content(self):
        # For DELETE 204 with no body
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()

    def get_session_token(self):
        cookie = self.headers.get('Cookie')
        if not cookie:
            return None
        # Simple cookie parsing
        parts = [p.strip() for p in cookie.split(';') if p.strip()]
        for p in parts:
            if p.startswith('session_id='):
                return p.split('=', 1)[1]
        return None

    def require_auth(self):
        token = self.get_session_token()
        if not token:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None, None
        uid = store.get_user_id_by_session(token)
        if not uid:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, "Authentication required")
            return None, None
        return uid, token

    # Routing
    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == '/register':
            return self.handle_register()
        elif parsed.path == '/login':
            return self.handle_login()
        elif parsed.path == '/logout':
            return self.handle_logout()
        elif parsed.path == '/todos':
            return self.handle_todos_create()
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == '/me':
            return self.handle_me()
        elif parsed.path == '/todos':
            return self.handle_todos_list()
        elif parsed.path.startswith('/todos/'):
            return self.handle_todo_get(parsed.path)
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')

    def do_PUT(self):
        parsed = urlparse(self.path)
        if parsed.path == '/password':
            return self.handle_password_change()
        elif parsed.path.startswith('/todos/'):
            return self.handle_todo_update(parsed.path)
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')

    def do_DELETE(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith('/todos/'):
            return self.handle_todo_delete(parsed.path)
        else:
            # Even for errors, the spec mandates JSON content-type, but DELETE success must be no body.
            # For consistency, return JSON error for non-existing route
            self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')

    # Handlers
    def handle_register(self):
        data, err = self.parse_json_body()
        if err:
            return self.send_error_json(HTTPStatus.BAD_REQUEST, err if err == 'Invalid JSON' else 'Bad Request')
        if not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not USERNAME_RE.match(username):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid username')
        if not isinstance(password, str) or len(password) < 8:
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Password too short')
        user, reason = store.create_user(username, password)
        if reason == 'exists':
            return self.send_error_json(HTTPStatus.CONFLICT, 'Username already exists')
        return self.send_json(HTTPStatus.CREATED, user)

    def handle_login(self):
        data, err = self.parse_json_body()
        if err:
            return self.send_error_json(HTTPStatus.BAD_REQUEST, err if err == 'Invalid JSON' else 'Bad Request')
        if not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        username = data.get('username')
        password = data.get('password')
        u = store.get_user_by_username(username) if isinstance(username, str) else None
        if not u or not isinstance(password, str) or u.get('password') != password:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Invalid credentials')
        token = store.create_session(u['id'])
        cookie = f'session_id={token}; Path=/; HttpOnly'
        public = {"id": u['id'], "username": u['username']}
        return self.send_json(HTTPStatus.OK, public, set_cookie=cookie)

    def handle_logout(self):
        uid, token = self.require_auth()
        if uid is None:
            return
        store.invalidate_session(token)
        return self.send_json(HTTPStatus.OK, {})

    def handle_me(self):
        uid, _ = self.require_auth()
        if uid is None:
            return
        user = store.get_user_public(uid)
        return self.send_json(HTTPStatus.OK, user)

    def handle_password_change(self):
        uid, _ = self.require_auth()
        if uid is None:
            return
        data, err = self.parse_json_body()
        if err:
            return self.send_error_json(HTTPStatus.BAD_REQUEST, err if err == 'Invalid JSON' else 'Bad Request')
        if not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        u = store.users_by_id.get(uid)
        if not isinstance(old_password, str) or u.get('password') != old_password:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Invalid credentials')
        if not isinstance(new_password, str) or len(new_password) < 8:
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Password too short')
        store.update_user_password(uid, new_password)
        return self.send_json(HTTPStatus.OK, {})

    def handle_todos_list(self):
        uid, _ = self.require_auth()
        if uid is None:
            return
        todos = store.list_todos_for_user(uid)
        return self.send_json(HTTPStatus.OK, todos)

    def handle_todos_create(self):
        uid, _ = self.require_auth()
        if uid is None:
            return
        data, err = self.parse_json_body()
        if err:
            return self.send_error_json(HTTPStatus.BAD_REQUEST, err if err == 'Invalid JSON' else 'Bad Request')
        if not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        title = data.get('title')
        description = data.get('description') if 'description' in data else ""
        if not isinstance(title, str) or title.strip() == '':
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Title is required')
        todo = store.create_todo(uid, title, description)
        return self.send_json(HTTPStatus.CREATED, todo)

    def _parse_todo_id(self, path):
        # path format /todos/:id
        parts = path.split('/')
        if len(parts) != 3 or parts[1] != 'todos' or not parts[2]:
            return None
        try:
            tid = int(parts[2])
            if tid < 1:
                return None
            return tid
        except ValueError:
            return None

    def handle_todo_get(self, path):
        uid, _ = self.require_auth()
        if uid is None:
            return
        tid = self._parse_todo_id(path)
        if tid is None:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Todo not found')
        todo = store.get_todo_for_user(uid, tid)
        if not todo:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Todo not found')
        return self.send_json(HTTPStatus.OK, todo)

    def handle_todo_update(self, path):
        uid, _ = self.require_auth()
        if uid is None:
            return
        tid = self._parse_todo_id(path)
        if tid is None:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Todo not found')
        data, err = self.parse_json_body()
        if err:
            return self.send_error_json(HTTPStatus.BAD_REQUEST, err if err == 'Invalid JSON' else 'Bad Request')
        if data is None:
            data = {}
        if not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        fields = {}
        if 'title' in data:
            title = data['title']
            if not isinstance(title, str) or title.strip() == '':
                return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Title is required')
            fields['title'] = title
        if 'description' in data:
            desc = data['description'] if data['description'] is not None else ""
            if not isinstance(desc, str):
                # Coerce to string? Spec doesn't require; keep strict
                return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
            fields['description'] = desc
        if 'completed' in data:
            comp = data['completed']
            if not isinstance(comp, bool):
                return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
            fields['completed'] = comp
        updated, reason = store.update_todo_for_user(uid, tid, fields)
        if reason == 'not_found':
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Todo not found')
        return self.send_json(HTTPStatus.OK, updated)

    def handle_todo_delete(self, path):
        uid, _ = self.require_auth()
        if uid is None:
            return
        tid = self._parse_todo_id(path)
        if tid is None:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Todo not found')
        ok = store.delete_todo_for_user(uid, tid)
        if not ok:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Todo not found')
        return self.send_no_content()


def main():
    parser = argparse.ArgumentParser(description='Todo App REST API Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    server_address = ('0.0.0.0', args.port)
    httpd = ThreadingHTTPServer(server_address, TodoRequestHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()

if __name__ == '__main__':
    main()
