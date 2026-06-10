import argparse
import json
import re
import threading
import uuid
from datetime import datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlparse

# In-memory storage protected by a lock for thread-safety
state_lock = threading.RLock()
users_by_id: Dict[int, Dict[str, Any]] = {}
users_by_username: Dict[str, Dict[str, Any]] = {}
sessions: Dict[str, int] = {}

todos_by_id: Dict[int, Dict[str, Any]] = {}

next_user_id = 1
next_todo_id = 1

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')


def now_iso_utc_seconds() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + 'Z'


def parse_cookies(cookie_header: Optional[str]) -> Dict[str, str]:
    cookies: Dict[str, str] = {}
    if not cookie_header:
        return cookies
    parts = cookie_header.split(';')
    for part in parts:
        if '=' in part:
            name, value = part.strip().split('=', 1)
            cookies[name] = value
    return cookies


def json_bytes(obj: Any) -> bytes:
    return json.dumps(obj, separators=(',', ':'), ensure_ascii=False).encode('utf-8')


def public_user(user: Dict[str, Any]) -> Dict[str, Any]:
    return {'id': user['id'], 'username': user['username']}


def public_todo(todo: Dict[str, Any]) -> Dict[str, Any]:
    return {
        'id': todo['id'],
        'title': todo['title'],
        'description': todo['description'],
        'completed': todo['completed'],
        'created_at': todo['created_at'],
        'updated_at': todo['updated_at'],
    }


def read_json_body(handler: BaseHTTPRequestHandler) -> Tuple[Optional[Dict[str, Any]], Optional[Tuple[int, Dict[str, str]]]]:
    try:
        length = int(handler.headers.get('Content-Length', '0'))
    except ValueError:
        length = 0
    try:
        raw = handler.rfile.read(length) if length > 0 else b''
        if not raw:
            return {}, None  # Treat empty body as empty dict
        data = json.loads(raw.decode('utf-8'))
        if not isinstance(data, dict):
            return None, (400, {'error': 'Invalid JSON'})
        return data, None
    except Exception:
        return None, (400, {'error': 'Invalid JSON'})


def get_authenticated_user(handler: BaseHTTPRequestHandler) -> Optional[Dict[str, Any]]:
    cookies = parse_cookies(handler.headers.get('Cookie'))
    token = cookies.get('session_id')
    if not token:
        return None
    with state_lock:
        uid = sessions.get(token)
        if not uid:
            return None
        return users_by_id.get(uid)


def require_auth(handler: BaseHTTPRequestHandler) -> Tuple[Optional[Dict[str, Any]], Optional[Tuple[int, Dict[str, str]]]]:
    user = get_authenticated_user(handler)
    if not user:
        return None, (401, {'error': 'Authentication required'})
    return user, None


def _get_user_todo_for(uid: int, todo_id: int) -> Optional[Dict[str, Any]]:
    todo = todos_by_id.get(todo_id)
    if not todo or todo.get('user_id') != uid:
        return None
    return todo


class TodoHandler(BaseHTTPRequestHandler):
    server_version = 'TodoServer/1.0'

    def log_message(self, format: str, *args: Any) -> None:
        # Log to stderr as usual but avoid noisy prints in tests if needed
        super().log_message(format, *args)

    def send_json(self, status: int, obj: Any, set_cookie: Optional[str] = None) -> None:
        body = json_bytes(obj)
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        if set_cookie:
            self.send_header('Set-Cookie', set_cookie)
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status: int, message: str) -> None:
        self.send_json(status, {'error': message})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/register':
            self.handle_register()
        elif path == '/login':
            self.handle_login()
        elif path == '/logout':
            self.handle_logout()
        elif path == '/todos':
            self.handle_create_todo()
        else:
            self.send_error_json(404, 'Not found')

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/me':
            self.handle_me()
        elif path == '/todos':
            self.handle_list_todos()
        elif path.startswith('/todos/'):
            self.handle_get_todo(path)
        else:
            self.send_error_json(404, 'Not found')

    def do_PUT(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == '/password':
            self.handle_change_password()
        elif path.startswith('/todos/'):
            self.handle_update_todo(path)
        else:
            self.send_error_json(404, 'Not found')

    def do_DELETE(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path.startswith('/todos/'):
            self.handle_delete_todo(path)
        else:
            self.send_error_json(404, 'Not found')

    # Endpoint handlers

    def handle_register(self) -> None:
        data, err = read_json_body(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        username = data.get('username') if isinstance(data, dict) else None
        password = data.get('password') if isinstance(data, dict) else None

        if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
            self.send_error_json(400, 'Invalid username')
            return
        if not isinstance(password, str) or len(password) < 8:
            self.send_error_json(400, 'Password too short')
            return

        with state_lock:
            if username in users_by_username:
                self.send_error_json(409, 'Username already exists')
                return
            global next_user_id
            user = {'id': next_user_id, 'username': username, 'password': password}
            users_by_id[next_user_id] = user
            users_by_username[username] = user
            next_user_id += 1
        self.send_json(HTTPStatus.CREATED, public_user(user))

    def handle_login(self) -> None:
        data, err = read_json_body(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        username = data.get('username') if isinstance(data, dict) else None
        password = data.get('password') if isinstance(data, dict) else None
        with state_lock:
            user = users_by_username.get(username)
            if not user or user.get('password') != password:
                self.send_error_json(401, 'Invalid credentials')
                return
            token = uuid.uuid4().hex
            sessions[token] = user['id']
        cookie = f'session_id={token}; Path=/; HttpOnly'
        self.send_json(HTTPStatus.OK, public_user(user), set_cookie=cookie)

    def handle_logout(self) -> None:
        user, err = require_auth(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        # Invalidate session token
        cookies = parse_cookies(self.headers.get('Cookie'))
        token = cookies.get('session_id')
        with state_lock:
            if token and token in sessions:
                del sessions[token]
        self.send_json(HTTPStatus.OK, {})

    def handle_me(self) -> None:
        user, err = require_auth(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        self.send_json(HTTPStatus.OK, public_user(user))

    def handle_change_password(self) -> None:
        user, err = require_auth(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        data, derr = read_json_body(self)
        if derr:
            code, obj = derr
            self.send_json(code, obj)
            return
        old_password = data.get('old_password') if isinstance(data, dict) else None
        new_password = data.get('new_password') if isinstance(data, dict) else None
        with state_lock:
            if user.get('password') != old_password:
                self.send_error_json(401, 'Invalid credentials')
                return
            if not isinstance(new_password, str) or len(new_password) < 8:
                self.send_error_json(400, 'Password too short')
                return
            user['password'] = new_password
        self.send_json(HTTPStatus.OK, {})

    def handle_list_todos(self) -> None:
        user, err = require_auth(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        uid = user['id']
        with state_lock:
            todos = [public_todo(t) for t in sorted(todos_by_id.values(), key=lambda x: x['id']) if t['user_id'] == uid]
        self.send_json(HTTPStatus.OK, todos)

    def handle_create_todo(self) -> None:
        user, err = require_auth(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        data, derr = read_json_body(self)
        if derr:
            code, obj = derr
            self.send_json(code, obj)
            return
        title = data.get('title') if isinstance(data, dict) else None
        description = data.get('description', '') if isinstance(data, dict) else ''
        if not isinstance(title, str) or title.strip() == '':
            self.send_error_json(400, 'Title is required')
            return
        if not isinstance(description, str):
            description = str(description)
        created = now_iso_utc_seconds()
        with state_lock:
            global next_todo_id
            todo = {
                'id': next_todo_id,
                'user_id': user['id'],
                'title': title,
                'description': description,
                'completed': False,
                'created_at': created,
                'updated_at': created,
            }
            todos_by_id[next_todo_id] = todo
            next_todo_id += 1
        self.send_json(HTTPStatus.CREATED, public_todo(todo))

    def _parse_todo_id(self, path: str) -> Optional[int]:
        parts = path.split('/')
        if len(parts) >= 3 and parts[1] == 'todos':
            try:
                return int(parts[2])
            except ValueError:
                return None
        return None

    def handle_get_todo(self, path: str) -> None:
        user, err = require_auth(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        todo_id = self._parse_todo_id(path)
        if todo_id is None:
            self.send_error_json(404, 'Todo not found')
            return
        with state_lock:
            todo = _get_user_todo_for(user['id'], todo_id)
            if not todo:
                self.send_error_json(404, 'Todo not found')
                return
            self.send_json(HTTPStatus.OK, public_todo(todo))

    def handle_update_todo(self, path: str) -> None:
        user, err = require_auth(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        todo_id = self._parse_todo_id(path)
        if todo_id is None:
            self.send_error_json(404, 'Todo not found')
            return
        data, derr = read_json_body(self)
        if derr:
            code, obj = derr
            self.send_json(code, obj)
            return
        with state_lock:
            todo = _get_user_todo_for(user['id'], todo_id)
            if not todo:
                self.send_error_json(404, 'Todo not found')
                return
            if 'title' in data:
                title = data.get('title')
                if not isinstance(title, str) or title.strip() == '':
                    self.send_error_json(400, 'Title is required')
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
                    todo['completed'] = bool(comp)
            todo['updated_at'] = now_iso_utc_seconds()
            updated = public_todo(todo)
        self.send_json(HTTPStatus.OK, updated)

    def handle_delete_todo(self, path: str) -> None:
        user, err = require_auth(self)
        if err:
            code, obj = err
            self.send_json(code, obj)
            return
        todo_id = self._parse_todo_id(path)
        if todo_id is None:
            self.send_error_json(404, 'Todo not found')
            return
        with state_lock:
            todo = _get_user_todo_for(user['id'], todo_id)
            if not todo:
                self.send_error_json(404, 'Todo not found')
                return
            del todos_by_id[todo_id]
        # 204 No Content, no body and no Content-Type header
        self.send_response(HTTPStatus.NO_CONTENT)
        self.end_headers()


def run_server(port: int) -> None:
    server = ThreadingHTTPServer(('0.0.0.0', port), TodoHandler)
    server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    run_server(args.port)


if __name__ == '__main__':
    main()
