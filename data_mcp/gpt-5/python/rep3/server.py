import argparse
import json
import re
import sys
import threading
import uuid
from datetime import datetime
from http import HTTPStatus
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from typing import Dict, Any, Optional, Tuple

# In-memory storage
users_by_id: Dict[int, Dict[str, Any]] = {}
users_by_username: Dict[str, Dict[str, Any]] = {}
sessions: Dict[str, int] = {}  # session_id -> user_id
todos_by_id: Dict[int, Dict[str, Any]] = {}

next_user_id = 1
next_todo_id = 1
store_lock = threading.Lock()

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')


def now_iso_utc_seconds() -> str:
    return datetime.utcnow().replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')


def json_bytes(obj: Any) -> bytes:
    return json.dumps(obj, separators=(',', ':')).encode('utf-8')


def parse_cookies(cookie_header: Optional[str]) -> Dict[str, str]:
    cookies: Dict[str, str] = {}
    if not cookie_header:
        return cookies
    parts = cookie_header.split(';')
    for part in parts:
        if '=' in part:
            name, value = part.split('=', 1)
            cookies[name.strip()] = value.strip()
    return cookies


class TodoHandler(BaseHTTPRequestHandler):
    server_version = 'TodoServer/1.0'

    def log_message(self, format: str, *args: Any) -> None:
        # Log to stderr with client address and time
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))

    # Utility methods
    def _read_json(self) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b''
        if not body:
            return None, 'Invalid JSON'
        try:
            data = json.loads(body.decode('utf-8'))
        except Exception:
            return None, 'Invalid JSON'
        if not isinstance(data, dict):
            return None, 'Invalid JSON'
        return data, None

    def _send_json(self, status: int, obj: Any) -> None:
        body = json_bytes(obj)
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_no_content(self) -> None:
        self.send_response(HTTPStatus.NO_CONTENT)
        # No Content-Type and no body per spec
        self.end_headers()

    def _error(self, status: int, message: str) -> None:
        self._send_json(status, {"error": message})

    def _current_user(self) -> Optional[Dict[str, Any]]:
        cookies = parse_cookies(self.headers.get('Cookie'))
        token = cookies.get('session_id')
        if not token:
            return None
        with store_lock:
            uid = sessions.get(token)
            if not uid:
                return None
            return users_by_id.get(uid)

    def _require_auth(self) -> Optional[Dict[str, Any]]:
        user = self._current_user()
        if not user:
            self._error(HTTPStatus.UNAUTHORIZED, 'Authentication required')
            return None
        return user

    # Routing helpers
    def _path_segments(self) -> list:
        path = self.path.split('?', 1)[0]
        # Remove leading and trailing slashes and split
        segs = [s for s in path.split('/') if s]
        return segs

    # HTTP method handlers
    def do_POST(self) -> None:
        segs = self._path_segments()
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
            self._handle_create_todo()
            return
        self._error(HTTPStatus.NOT_FOUND, 'Not found')

    def do_GET(self) -> None:
        segs = self._path_segments()
        if segs == ['me']:
            self._handle_me()
            return
        if segs == ['todos']:
            self._handle_list_todos()
            return
        if len(segs) == 2 and segs[0] == 'todos':
            try:
                todo_id = int(segs[1])
            except ValueError:
                self._error(HTTPStatus.NOT_FOUND, 'Not found')
                return
            self._handle_get_todo(todo_id)
            return
        # For readiness or unknown routes
        self._error(HTTPStatus.NOT_FOUND, 'Not found')

    def do_PUT(self) -> None:
        segs = self._path_segments()
        if segs == ['password']:
            self._handle_change_password()
            return
        if len(segs) == 2 and segs[0] == 'todos':
            try:
                todo_id = int(segs[1])
            except ValueError:
                self._error(HTTPStatus.NOT_FOUND, 'Not found')
                return
            self._handle_update_todo(todo_id)
            return
        self._error(HTTPStatus.NOT_FOUND, 'Not found')

    def do_DELETE(self) -> None:
        segs = self._path_segments()
        if len(segs) == 2 and segs[0] == 'todos':
            try:
                todo_id = int(segs[1])
            except ValueError:
                self._error(HTTPStatus.NOT_FOUND, 'Not found')
                return
            self._handle_delete_todo(todo_id)
            return
        self._error(HTTPStatus.NOT_FOUND, 'Not found')

    # Endpoint implementations
    def _handle_register(self) -> None:
        data, err = self._read_json()
        if err:
            self._error(HTTPStatus.BAD_REQUEST, err)
            return
        username = data.get('username')
        password = data.get('password')
        if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
            self._error(HTTPStatus.BAD_REQUEST, 'Invalid username')
            return
        if not isinstance(password, str) or len(password) < 8:
            self._error(HTTPStatus.BAD_REQUEST, 'Password too short')
            return
        with store_lock:
            if username in users_by_username:
                self._error(HTTPStatus.CONFLICT, 'Username already exists')
                return
            global next_user_id
            user = {
                'id': next_user_id,
                'username': username,
                'password': password,
            }
            users_by_id[next_user_id] = user
            users_by_username[username] = user
            next_user_id += 1
        self._send_json(HTTPStatus.CREATED, {"id": user['id'], "username": user['username']})

    def _handle_login(self) -> None:
        data, err = self._read_json()
        if err:
            self._error(HTTPStatus.BAD_REQUEST, err)
            return
        username = data.get('username')
        password = data.get('password')
        with store_lock:
            user = users_by_username.get(username)
            if not user or user.get('password') != password:
                self._error(HTTPStatus.UNAUTHORIZED, 'Invalid credentials')
                return
            token = uuid.uuid4().hex
            sessions[token] = user['id']
        body = json_bytes({"id": user['id'], "username": user['username']})
        self.send_response(HTTPStatus.OK)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        # Set-Cookie per spec
        self.send_header('Set-Cookie', f'session_id={token}; Path=/; HttpOnly')
        self.end_headers()
        self.wfile.write(body)

    def _handle_logout(self) -> None:
        user = self._require_auth()
        if not user:
            return
        cookies = parse_cookies(self.headers.get('Cookie'))
        token = cookies.get('session_id')
        with store_lock:
            if token and token in sessions:
                del sessions[token]
        self._send_json(HTTPStatus.OK, {})

    def _handle_me(self) -> None:
        user = self._require_auth()
        if not user:
            return
        self._send_json(HTTPStatus.OK, {"id": user['id'], "username": user['username']})

    def _handle_change_password(self) -> None:
        user = self._require_auth()
        if not user:
            return
        data, err = self._read_json()
        if err:
            self._error(HTTPStatus.BAD_REQUEST, err)
            return
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        if user.get('password') != old_password:
            self._error(HTTPStatus.UNAUTHORIZED, 'Invalid credentials')
            return
        if not isinstance(new_password, str) or len(new_password) < 8:
            self._error(HTTPStatus.BAD_REQUEST, 'Password too short')
            return
        with store_lock:
            # Fetch by id to ensure updating shared object
            u = users_by_id.get(user['id'])
            if u is not None:
                u['password'] = new_password
        self._send_json(HTTPStatus.OK, {})

    def _handle_list_todos(self) -> None:
        user = self._require_auth()
        if not user:
            return
        uid = user['id']
        with store_lock:
            todos = [t for t in todos_by_id.values() if t['user_id'] == uid]
            todos.sort(key=lambda x: x['id'])
            result = [self._serialize_todo(t) for t in todos]
        self._send_json(HTTPStatus.OK, result)

    def _handle_create_todo(self) -> None:
        user = self._require_auth()
        if not user:
            return
        data, err = self._read_json()
        if err:
            self._error(HTTPStatus.BAD_REQUEST, err)
            return
        title = data.get('title')
        description = data.get('description', '')
        if not isinstance(title, str) or title.strip() == '':
            self._error(HTTPStatus.BAD_REQUEST, 'Title is required')
            return
        if not isinstance(description, str):
            description = str(description)
        ts = now_iso_utc_seconds()
        with store_lock:
            global next_todo_id
            todo = {
                'id': next_todo_id,
                'user_id': user['id'],
                'title': title,
                'description': description,
                'completed': False,
                'created_at': ts,
                'updated_at': ts,
            }
            todos_by_id[next_todo_id] = todo
            next_todo_id += 1
            result = self._serialize_todo(todo)
        self._send_json(HTTPStatus.CREATED, result)

    def _get_owned_todo(self, uid: int, todo_id: int) -> Optional[Dict[str, Any]]:
        with store_lock:
            todo = todos_by_id.get(todo_id)
            if not todo or todo.get('user_id') != uid:
                return None
            return todo

    def _handle_get_todo(self, todo_id: int) -> None:
        user = self._require_auth()
        if not user:
            return
        todo = self._get_owned_todo(user['id'], todo_id)
        if not todo:
            self._error(HTTPStatus.NOT_FOUND, 'Todo not found')
            return
        self._send_json(HTTPStatus.OK, self._serialize_todo(todo))

    def _handle_update_todo(self, todo_id: int) -> None:
        user = self._require_auth()
        if not user:
            return
        todo = self._get_owned_todo(user['id'], todo_id)
        if not todo:
            self._error(HTTPStatus.NOT_FOUND, 'Todo not found')
            return
        data, err = self._read_json()
        if err:
            self._error(HTTPStatus.BAD_REQUEST, err)
            return
        with store_lock:
            if 'title' in data:
                title = data.get('title')
                if not isinstance(title, str) or title.strip() == '':
                    self._error(HTTPStatus.BAD_REQUEST, 'Title is required')
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
                    self._error(HTTPStatus.BAD_REQUEST, 'Invalid JSON')
                    return
            todo['updated_at'] = now_iso_utc_seconds()
            result = self._serialize_todo(todo)
        self._send_json(HTTPStatus.OK, result)

    def _handle_delete_todo(self, todo_id: int) -> None:
        user = self._require_auth()
        if not user:
            return
        with store_lock:
            todo = todos_by_id.get(todo_id)
            if not todo or todo.get('user_id') != user['id']:
                # For errors, return JSON body as per spec
                self._error(HTTPStatus.NOT_FOUND, 'Todo not found')
                return
            del todos_by_id[todo_id]
        self._send_no_content()

    @staticmethod
    def _serialize_todo(todo: Dict[str, Any]) -> Dict[str, Any]:
        return {
            'id': todo['id'],
            'title': todo['title'],
            'description': todo.get('description', ''),
            'completed': bool(todo.get('completed', False)),
            'created_at': todo['created_at'],
            'updated_at': todo['updated_at'],
        }


def main() -> None:
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
