import argparse
import json
import re
import secrets
import sys
from datetime import datetime, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, Any, Optional, Tuple

# In-memory storage
users_by_id: Dict[int, Dict[str, Any]] = {}
users_by_username: Dict[str, Dict[str, Any]] = {}
sessions: Dict[str, int] = {}  # session_id -> user_id
next_user_id = 1

next_todo_id = 1
todos_by_id: Dict[int, Dict[str, Any]] = {}

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def now_iso_utc_seconds() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')


def hash_password(password: str, salt: Optional[bytes] = None) -> str:
    import hashlib
    if salt is None:
        salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, 100_000)
    return salt.hex() + ':' + dk.hex()


def verify_password(stored: str, password: str) -> bool:
    import hashlib
    try:
        salt_hex, dk_hex = stored.split(':', 1)
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(dk_hex)
    except Exception:
        return False
    test = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt, 100_000)
    return secrets.compare_digest(expected, test)


def get_cookies(header_value: Optional[str]) -> Dict[str, str]:
    if not header_value:
        return {}
    c = SimpleCookie()
    try:
        c.load(header_value)
    except Exception:
        return {}
    result = {}
    for k, morsel in c.items():
        result[k] = morsel.value
    return result


def make_set_cookie(name: str, value: str, path: str = '/', httponly: bool = True, expires: Optional[str] = None) -> str:
    morsel = SimpleCookie()
    morsel[name] = value
    morsel[name]['path'] = path
    if httponly:
        morsel[name]['httponly'] = True
    if expires is not None:
        morsel[name]['expires'] = expires
    # SimpleCookie outputs 'Set-Cookie: ...' when dumped; we need only the value
    return morsel.output(header='').strip()


class TodoHandler(BaseHTTPRequestHandler):
    server_version = "TodoServer/1.0"

    # Utility response helpers
    def send_json(self, status: int, data: Any):
        body = json.dumps(data).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status: int, message: str):
        self.send_json(status, {"error": message})

    def send_no_content(self):
        self.send_response(HTTPStatus.NO_CONTENT)
        # No Content-Type and no body for DELETE success
        self.end_headers()

    # Parse request body JSON
    def read_json(self) -> Tuple[bool, Optional[Dict[str, Any]]]:
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length > 0 else b''
        if not raw:
            return True, {}
        try:
            data = json.loads(raw.decode('utf-8'))
            if isinstance(data, dict):
                return True, data
            else:
                return False, None
        except Exception:
            return False, None

    # Authentication helpers
    def get_auth_user(self) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
        cookies = get_cookies(self.headers.get('Cookie'))
        token = cookies.get('session_id')
        if not token:
            return None, None
        user_id = sessions.get(token)
        if not user_id:
            return None, token
        user = users_by_id.get(user_id)
        if not user:
            return None, token
        return user, token

    def require_auth(self) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
        user, token = self.get_auth_user()
        if not user:
            self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Authentication required')
            return None, token
        return user, token

    # Routing
    def do_POST(self):
        if self.path == '/register':
            return self.handle_register()
        if self.path == '/login':
            return self.handle_login()
        if self.path == '/logout':
            return self.handle_logout()
        # Unknown
        self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')

    def do_GET(self):
        if self.path == '/me':
            return self.handle_me()
        if self.path == '/todos':
            return self.handle_list_todos()
        if self.path.startswith('/todos/'):
            return self.handle_get_todo()
        self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')

    def do_PUT(self):
        if self.path == '/password':
            return self.handle_change_password()
        if self.path.startswith('/todos/'):
            return self.handle_update_todo()
        self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')

    def do_DELETE(self):
        if self.path.startswith('/todos/'):
            return self.handle_delete_todo()
        self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')

    # Handlers
    def handle_register(self):
        global next_user_id
        ok, data = self.read_json()
        if not ok or not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid username')
        if not isinstance(password, str) or len(password) < 8:
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Password too short')
        if username in users_by_username:
            return self.send_error_json(HTTPStatus.CONFLICT, 'Username already exists')
        user = {
            'id': next_user_id,
            'username': username,
            'password_hash': hash_password(password),
        }
        users_by_id[next_user_id] = user
        users_by_username[username] = user
        next_user_id += 1
        self.send_json(HTTPStatus.CREATED, {'id': user['id'], 'username': user['username']})

    def handle_login(self):
        ok, data = self.read_json()
        if not ok or not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not isinstance(password, str):
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Invalid credentials')
        user = users_by_username.get(username)
        if not user or not verify_password(user['password_hash'], password):
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Invalid credentials')
        token = secrets.token_hex(32)
        sessions[token] = user['id']
        # Prepare headers
        body = json.dumps({'id': user['id'], 'username': user['username']}).encode('utf-8')
        self.send_response(HTTPStatus.OK)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Set-Cookie', f"{make_set_cookie('session_id', token)}")
        self.end_headers()
        self.wfile.write(body)

    def handle_logout(self):
        user, token = self.get_auth_user()
        if not user:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Authentication required')
        if token and token in sessions:
            del sessions[token]
        # Clear cookie on client
        body = json.dumps({}).encode('utf-8')
        self.send_response(HTTPStatus.OK)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Set-Cookie', make_set_cookie('session_id', '', expires='Thu, 01 Jan 1970 00:00:00 GMT'))
        self.end_headers()
        self.wfile.write(body)

    def handle_me(self):
        user, _ = self.get_auth_user()
        if not user:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Authentication required')
        self.send_json(HTTPStatus.OK, {'id': user['id'], 'username': user['username']})

    def handle_change_password(self):
        user, _ = self.get_auth_user()
        if not user:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Authentication required')
        ok, data = self.read_json()
        if not ok or not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        if not isinstance(old_password, str) or not verify_password(user['password_hash'], old_password):
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Invalid credentials')
        if not isinstance(new_password, str) or len(new_password) < 8:
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Password too short')
        user['password_hash'] = hash_password(new_password)
        self.send_json(HTTPStatus.OK, {})

    def handle_list_todos(self):
        user, _ = self.get_auth_user()
        if not user:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Authentication required')
        user_id = user['id']
        items = [
            {k: v for k, v in todo.items() if k != 'owner_id'}
            for todo in sorted(todos_by_id.values(), key=lambda t: t['id'])
            if todo.get('owner_id') == user_id
        ]
        self.send_json(HTTPStatus.OK, items)

    def handle_create_todo(self):
        # Not used; POST /todos routed via do_POST? We routed in do_GET/POST accordingly.
        pass

    def handle_get_todo(self):
        user, _ = self.get_auth_user()
        if not user:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Authentication required')
        todo_id = self._extract_todo_id()
        if todo_id is None:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')
        todo = todos_by_id.get(todo_id)
        if not todo or todo.get('owner_id') != user['id']:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Todo not found')
        self.send_json(HTTPStatus.OK, {k: v for k, v in todo.items() if k != 'owner_id'})

    def handle_update_todo(self):
        user, _ = self.get_auth_user()
        if not user:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Authentication required')
        todo_id = self._extract_todo_id()
        if todo_id is None:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')
        todo = todos_by_id.get(todo_id)
        if not todo or todo.get('owner_id') != user['id']:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Todo not found')
        ok, data = self.read_json()
        if not ok or not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        if 'title' in data:
            title = data.get('title')
            if not isinstance(title, str) or title.strip() == '':
                return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Title is required')
            todo['title'] = title
        if 'description' in data:
            description = data.get('description')
            if not isinstance(description, str):
                return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
            todo['description'] = description
        if 'completed' in data:
            completed = data.get('completed')
            if not isinstance(completed, bool):
                return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
            todo['completed'] = completed
        todo['updated_at'] = now_iso_utc_seconds()
        self.send_json(HTTPStatus.OK, {k: v for k, v in todo.items() if k != 'owner_id'})

    def handle_delete_todo(self):
        user, _ = self.get_auth_user()
        if not user:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Authentication required')
        todo_id = self._extract_todo_id()
        if todo_id is None:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')
        todo = todos_by_id.get(todo_id)
        if not todo or todo.get('owner_id') != user['id']:
            return self.send_error_json(HTTPStatus.NOT_FOUND, 'Todo not found')
        del todos_by_id[todo_id]
        self.send_no_content()

    def do_POST(self):  # type: ignore[override]
        # re-define to include /todos route for create
        if self.path == '/register':
            return self.handle_register()
        if self.path == '/login':
            return self.handle_login()
        if self.path == '/logout':
            return self.handle_logout()
        if self.path == '/todos':
            return self.handle_create_todo_post()
        self.send_error_json(HTTPStatus.NOT_FOUND, 'Not found')

    def handle_create_todo_post(self):
        global next_todo_id
        user, _ = self.get_auth_user()
        if not user:
            return self.send_error_json(HTTPStatus.UNAUTHORIZED, 'Authentication required')
        ok, data = self.read_json()
        if not ok or not isinstance(data, dict):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        if 'title' not in data or not isinstance(data.get('title'), str) or data.get('title').strip() == '':
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Title is required')
        title = data.get('title')
        description = data.get('description', '')
        if not isinstance(description, str):
            return self.send_error_json(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
        ts = now_iso_utc_seconds()
        todo = {
            'id': next_todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': ts,
            'updated_at': ts,
            'owner_id': user['id'],
        }
        todos_by_id[next_todo_id] = todo
        next_todo_id += 1
        self.send_json(HTTPStatus.CREATED, {k: v for k, v in todo.items() if k != 'owner_id'})

    def _extract_todo_id(self) -> Optional[int]:
        parts = self.path.split('/')
        if len(parts) >= 3 and parts[1] == 'todos':
            try:
                return int(parts[2])
            except ValueError:
                return None
        return None

    # Silence default logging to stderr to keep test output clean
    def log_message(self, format: str, *args) -> None:  # noqa: A003 - match BaseHTTPRequestHandler signature
        sys.stderr.write("%s - - [%s] %s\n" % (self.client_address[0], self.log_date_time_string(), format % args))


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('0.0.0.0', args.port), TodoHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
