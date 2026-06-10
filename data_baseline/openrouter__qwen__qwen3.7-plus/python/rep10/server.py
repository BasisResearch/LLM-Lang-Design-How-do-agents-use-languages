#!/usr/bin/env python3
import argparse
import json
import re
import uuid
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

# In-memory storage
users = {}  # id -> {"id": int, "username": str, "password": str}
username_to_id = {}  # username -> id
sessions = {}  # session_id -> user_id

user_id_counter = 1
todo_id_counter = 1
todos = {}  # id -> {"id": int, "user_id": int, "title": str, "description": str, "completed": bool, "created_at": str, "updated_at": str}


def get_current_time():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


class TodoHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging

    def send_json_response(self, status_code, data):
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def send_empty_response(self, status_code):
        self.send_response(status_code)
        self.end_headers()

    def get_auth_user(self):
        cookies = self.headers.get('Cookie', '')
        session_id = None
        for cookie in cookies.split(';'):
            key, _, value = cookie.strip().partition('=')
            if key == 'session_id':
                session_id = value
                break

        if not session_id or session_id not in sessions:
            return None
        user_id = sessions[session_id]
        return users.get(user_id)

    def read_json_body(self):
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        body = self.rfile.read(content_length)
        try:
            return json.loads(body.decode('utf-8'))
        except json.JSONDecodeError:
            return {}

    def do_POST(self):
        path = urlparse(self.path).path

        if path == '/register':
            self.handle_register()
        elif path == '/login':
            self.handle_login()
        elif path == '/logout':
            self.handle_logout()
        elif path == '/todos':
            self.handle_create_todo()
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_GET(self):
        path = urlparse(self.path).path

        if path == '/me':
            self.handle_me()
        elif path == '/todos':
            self.handle_get_todos()
        elif path.startswith('/todos/'):
            todo_id_str = path[7:]
            if todo_id_str.isdigit():
                self.handle_get_todo(int(todo_id_str))
            else:
                self.send_json_response(404, {"error": "Todo not found"})
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_PUT(self):
        path = urlparse(self.path).path

        if path == '/password':
            self.handle_change_password()
        elif path.startswith('/todos/'):
            todo_id_str = path[7:]
            if todo_id_str.isdigit():
                self.handle_update_todo(int(todo_id_str))
            else:
                self.send_json_response(404, {"error": "Todo not found"})
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_DELETE(self):
        path = urlparse(self.path).path

        if path.startswith('/todos/'):
            todo_id_str = path[7:]
            if todo_id_str.isdigit():
                self.handle_delete_todo(int(todo_id_str))
            else:
                self.send_json_response(404, {"error": "Todo not found"})
        else:
            self.send_json_response(404, {"error": "Not found"})

    def handle_register(self):
        global user_id_counter
        data = self.read_json_body()
        username = data.get('username')
        password = data.get('password')

        if not username or not isinstance(username, str) or not re.match(r'^[a-zA-Z0-9_]{3,50}$', username):
            self.send_json_response(400, {"error": "Invalid username"})
            return

        if not password or not isinstance(password, str) or len(password) < 8:
            self.send_json_response(400, {"error": "Password too short"})
            return

        if username in username_to_id:
            self.send_json_response(409, {"error": "Username already exists"})
            return

        user_id = user_id_counter
        user_id_counter += 1

        users[user_id] = {
            "id": user_id,
            "username": username,
            "password": password
        }
        username_to_id[username] = user_id

        self.send_json_response(201, {"id": user_id, "username": username})

    def handle_login(self):
        data = self.read_json_body()
        username = data.get('username')
        password = data.get('password')

        user_id = username_to_id.get(username)
        if not user_id or users[user_id]['password'] != password:
            self.send_json_response(401, {"error": "Invalid credentials"})
            return

        session_id = uuid.uuid4().hex
        sessions[session_id] = user_id

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')
        self.end_headers()
        self.wfile.write(json.dumps({"id": user_id, "username": users[user_id]['username']}).encode('utf-8'))

    def handle_logout(self):
        user = self.get_auth_user()
        if not user:
            self.send_json_response(401, {"error": "Authentication required"})
            return

        cookies = self.headers.get('Cookie', '')
        session_id = None
        for cookie in cookies.split(';'):
            key, _, value = cookie.strip().partition('=')
            if key == 'session_id':
                session_id = value
                break

        if session_id and session_id in sessions:
            del sessions[session_id]

        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Set-Cookie', 'session_id=; Path=/; HttpOnly; Max-Age=0')
        self.end_headers()
        self.wfile.write(b'{}')

    def handle_me(self):
        user = self.get_auth_user()
        if not user:
            self.send_json_response(401, {"error": "Authentication required"})
            return
        self.send_json_response(200, {"id": user['id'], "username": user['username']})

    def handle_change_password(self):
        user = self.get_auth_user()
        if not user:
            self.send_json_response(401, {"error": "Authentication required"})
            return

        data = self.read_json_body()
        old_password = data.get('old_password')
        new_password = data.get('new_password')

        if user['password'] != old_password:
            self.send_json_response(401, {"error": "Invalid credentials"})
            return

        if not new_password or not isinstance(new_password, str) or len(new_password) < 8:
            self.send_json_response(400, {"error": "Password too short"})
            return

        user['password'] = new_password
        self.send_json_response(200, {})

    def handle_get_todos(self):
        user = self.get_auth_user()
        if not user:
            self.send_json_response(401, {"error": "Authentication required"})
            return

        user_todos = [
            {k: v for k, v in todo.items() if k != 'user_id'}
            for todo in todos.values() if todo['user_id'] == user['id']
        ]
        user_todos.sort(key=lambda x: x['id'])
        self.send_json_response(200, user_todos)

    def handle_create_todo(self):
        global todo_id_counter
        user = self.get_auth_user()
        if not user:
            self.send_json_response(401, {"error": "Authentication required"})
            return

        data = self.read_json_body()
        title = data.get('title')

        if not title or not isinstance(title, str) or len(title.strip()) == 0:
            self.send_json_response(400, {"error": "Title is required"})
            return

        description = data.get('description', '')
        if not isinstance(description, str):
            description = ''

        todo_id = todo_id_counter
        todo_id_counter += 1

        now = get_current_time()
        new_todo = {
            "id": todo_id,
            "user_id": user['id'],
            "title": title,
            "description": description,
            "completed": False,
            "created_at": now,
            "updated_at": now
        }
        todos[todo_id] = new_todo

        response_todo = {k: v for k, v in new_todo.items() if k != 'user_id'}
        self.send_json_response(201, response_todo)

    def handle_get_todo(self, todo_id):
        user = self.get_auth_user()
        if not user:
            self.send_json_response(401, {"error": "Authentication required"})
            return

        todo = todos.get(todo_id)
        if not todo or todo['user_id'] != user['id']:
            self.send_json_response(404, {"error": "Todo not found"})
            return

        response_todo = {k: v for k, v in todo.items() if k != 'user_id'}
        self.send_json_response(200, response_todo)

    def handle_update_todo(self, todo_id):
        user = self.get_auth_user()
        if not user:
            self.send_json_response(401, {"error": "Authentication required"})
            return

        todo = todos.get(todo_id)
        if not todo or todo['user_id'] != user['id']:
            self.send_json_response(404, {"error": "Todo not found"})
            return

        data = self.read_json_body()

        if 'title' in data:
            if not isinstance(data['title'], str) or len(data['title'].strip()) == 0:
                self.send_json_response(400, {"error": "Title is required"})
                return
            todo['title'] = data['title']

        if 'description' in data:
            todo['description'] = data['description'] if isinstance(data['description'], str) else ''

        if 'completed' in data:
            todo['completed'] = bool(data['completed'])

        todo['updated_at'] = get_current_time()

        response_todo = {k: v for k, v in todo.items() if k != 'user_id'}
        self.send_json_response(200, response_todo)

    def handle_delete_todo(self, todo_id):
        user = self.get_auth_user()
        if not user:
            self.send_json_response(401, {"error": "Authentication required"})
            return

        todo = todos.get(todo_id)
        if not todo or todo['user_id'] != user['id']:
            self.send_json_response(404, {"error": "Todo not found"})
            return

        del todos[todo_id]
        self.send_empty_response(204)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    server = HTTPServer(('0.0.0.0', args.port), TodoHandler)
    print(f"Server running on 0.0.0.0:{args.port}")
    server.serve_forever()


if __name__ == '__main__':
    main()
