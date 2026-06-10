#!/usr/bin/env python3

import json
import re
import uuid
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from datetime import datetime
from hashlib import sha256


class TodoServer(BaseHTTPRequestHandler):
    # Class variables to persist between requests
    users = {}
    todos_by_user = {}
    passwords_hashed = {}
    session_tokens = {}
    user_id_counter = 1
    todo_id_counter = 1

    def do_GET(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if path_parts[0] == 'me':
            self.handle_get_me()
        elif path_parts[0] == 'todos':
            if len(path_parts) == 1:
                self.handle_get_todos()
            elif len(path_parts) == 2:
                try:
                    todo_id = int(path_parts[1])
                    self.handle_get_todo(todo_id)
                except (ValueError, IndexError):
                    self.send_json_response({'error': 'Invalid todo ID'}, 400)
            else:
                self.send_json_response({'error': 'Not Found'}, 404)
        else:
            self.send_json_response({'error': 'Not Found'}, 404)

    def do_POST(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if path_parts[0] == 'register':
            self.handle_post_register()
        elif path_parts[0] == 'login':
            self.handle_post_login()
        elif path_parts[0] == 'logout':
            self.handle_post_logout()
        elif path_parts[0] == 'todos':
            self.handle_post_todos()
        elif path_parts[0] == 'password':
            self.handle_put_password()
        else:
            self.send_json_response({'error': 'Not Found'}, 404)

    def do_PUT(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if path_parts[0] == 'password':
            self.handle_put_password()
        elif path_parts[0] == 'todos':
            if len(path_parts) == 2:
                try:
                    todo_id = int(path_parts[1])
                    self.handle_put_todo(todo_id)
                except (ValueError, IndexError):
                    self.send_json_response({'error': 'Invalid todo ID'}, 400)
            else:
                self.send_json_response({'error': 'Not Found'}, 404)
        else:
            self.send_json_response({'error': 'Not Found'}, 404)

    def do_DELETE(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if path_parts[0] == 'todos':
            if len(path_parts) == 2:
                try:
                    todo_id = int(path_parts[1])
                    self.handle_delete_todo(todo_id)
                except (ValueError, IndexError):
                    self.send_json_response({'error': 'Invalid todo ID'}, 400)
            else:
                self.send_json_response({'error': 'Not Found'}, 404)
        else:
            self.send_json_response({'error': 'Not Found'}, 404)

    # Helper methods
    def get_request_body(self):
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            return self.rfile.read(content_length).decode('utf-8')
        return ''

    def send_json_response(self, data, status_code=200, headers=None):
        self.send_response(status_code)
        
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
                
        # Send Content-Type for JSON unless 204 (No Content)
        if status_code != 204:
            self.send_header('Content-Type', 'application/json')
        self.end_headers()
        
        if status_code != 204:
            response_body = json.dumps(data)
            self.wfile.write(response_body.encode('utf-8'))

    def require_auth(self):
        """Check authentication using session ID cookie"""
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return None, {'error': 'Authentication required'}
        
        # Parse cookies - simplified way to extract session_id
        cookies = {}
        for cookie in cookie_header.split(';'):
            if '=' in cookie:
                k, v = cookie.strip().split('=', 1)
                cookies[k] = v
        
        session_id = cookies.get('session_id')
        if not session_id or session_id not in self.session_tokens:
            return None, {'error': 'Authentication required'}
        
        user_id = self.session_tokens[session_id]
        user = self.users.get(user_id)
        if not user:
            return None, {'error': 'Authentication required'}
        
        return user, None

    # Authentication endpoints
    def handle_post_register(self):
        try:
            request_data = json.loads(self.get_request_body())
        except json.JSONDecodeError:
            self.send_json_response({'error': 'Invalid JSON'}, 400)
            return

        username = request_data.get('username', '').strip()
        password = request_data.get('password', '').strip()

        # Validation
        if not username:
            self.send_json_response({'error': 'Invalid username'}, 400)
            return
            
        if len(username) < 3 or len(username) > 50 or not re.match(r'^[a-zA-Z0-9_]+$', username):
            self.send_json_response({'error': 'Invalid username'}, 400)
            return
            
        if len(password) < 8:
            self.send_json_response({'error': 'Password too short'}, 400)
            return

        # Check if username exists - check across all users
        for user in self.users.values():
            if user['username'] == username:
                self.send_json_response({'error': 'Username already exists'}, 409)
                return

        # Create new user
        user_id = self.__class__.user_id_counter
        self.__class__.user_id_counter += 1
        new_user = {
            'id': user_id,
            'username': username
        }
        self.users[user_id] = new_user
        self.passwords_hashed[user_id] = sha256(password.encode()).hexdigest()
        self.todos_by_user[user_id] = {}

        self.send_json_response(new_user, 201)

    def handle_post_login(self):
        try:
            request_data = json.loads(self.get_request_body())
        except json.JSONDecodeError:
            self.send_json_response({'error': 'Invalid JSON'}, 400)
            return

        username = request_data.get('username', '').strip()
        password = request_data.get('password', '').strip()

        # Find user by username
        user = None
        user_id = None
        for uid, u in self.users.items():
            if u['username'] == username:
                user = u
                user_id = uid
                break

        if not user or self.passwords_hashed.get(user_id) != sha256(password.encode()).hexdigest():
            self.send_json_response({'error': 'Invalid credentials'}, 401)
            return

        # Create session
        session_id = uuid.uuid4().hex
        self.session_tokens[session_id] = user_id

        headers = {
            'Set-Cookie': f'session_id={session_id}; Path=/; HttpOnly'
        }
        self.send_json_response(user, 200, headers)

    def handle_post_logout(self):
        user, error = self.require_auth()
        if error:
            self.send_json_response(error, 401)
            return

        cookie_header = self.headers.get('Cookie')
        session_id = None
        if cookie_header:
            cookies = {}
            for cookie in cookie_header.split(';'):
                if '=' in cookie:
                    k, v = cookie.strip().split('=', 1)
                    cookies[k] = v
            session_id = cookies.get('session_id')

        if session_id and session_id in self.session_tokens:
            del self.session_tokens[session_id]

        self.send_json_response({}, 200)

    # User operations
    def handle_get_me(self):
        user, error = self.require_auth()
        if error:
            self.send_json_response(error, 401)
            return

        self.send_json_response(user, 200)

    def handle_put_password(self):
        user, error = self.require_auth()
        if error:
            self.send_json_response(error, 401)
            return

        try:
            request_data = json.loads(self.get_request_body())
        except json.JSONDecodeError:
            self.send_json_response({'error': 'Invalid JSON'}, 400)
            return

        old_password = request_data.get('old_password', '').strip()
        new_password = request_data.get('new_password', '').strip()

        if self.passwords_hashed[user['id']] != sha256(old_password.encode()).hexdigest():
            self.send_json_response({'error': 'Invalid credentials'}, 401)
            return

        if len(new_password) < 8:
            self.send_json_response({'error': 'Password too short'}, 400)
            return

        self.passwords_hashed[user['id']] = sha256(new_password.encode()).hexdigest()
        self.send_json_response({}, 200)

    # Todo operations
    def handle_get_todos(self):
        user, error = self.require_auth()
        if error:
            self.send_json_response(error, 401)
            return

        todos = list(self.todos_by_user.get(user['id'], {}).values())
        # Sort by id ascending
        todos.sort(key=lambda x: x['id'])
        self.send_json_response(todos, 200)

    def handle_post_todos(self):
        user, error = self.require_auth()
        if error:
            self.send_json_response(error, 401)
            return

        try:
            request_data = json.loads(self.get_request_body())
        except json.JSONDecodeError:
            self.send_json_response({'error': 'Invalid JSON'}, 400)
            return

        title = request_data.get('title', '').strip()
        description = request_data.get('description', '').strip() or ""

        if not title:
            self.send_json_response({'error': 'Title is required'}, 400)
            return

        # Create timestamp - fix deprecation warning
        now_str = datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')

        todo_id = self.__class__.todo_id_counter
        self.__class__.todo_id_counter += 1

        new_todo = {
            'id': todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now_str,
            'updated_at': now_str
        }

        # Ensure user's todo list exists
        if user['id'] not in self.todos_by_user:
            self.todos_by_user[user['id']] = {}
            
        self.todos_by_user[user['id']][todo_id] = new_todo
        self.send_json_response(new_todo, 201)

    def handle_get_todo(self, todo_id):
        user, error = self.require_auth()
        if error:
            self.send_json_response(error, 401)
            return

        # Check if todo belongs to user
        user_todos = self.todos_by_user.get(user['id'], {})
        todo = user_todos.get(todo_id)
        if not todo:
            self.send_json_response({'error': 'Todo not found'}, 404)
            return

        self.send_json_response(todo, 200)

    def handle_put_todo(self, todo_id):
        user, error = self.require_auth()
        if error:
            self.send_json_response(error, 401)
            return

        # Check if todo belongs to user
        user_todos = self.todos_by_user.get(user['id'], {})
        todo = user_todos.get(todo_id)
        if not todo:
            self.send_json_response({'error': 'Todo not found'}, 404)
            return

        try:
            request_data = json.loads(self.get_request_body())
        except json.JSONDecodeError:
            self.send_json_response({'error': 'Invalid JSON'}, 400)
            return

        # Validate title if it exists in request
        title = request_data.get('title')
        if title is not None and title.strip() == "":
            self.send_json_response({'error': 'Title is required'}, 400)
            return

        # Update fields based on provided data
        if 'title' in request_data:
            todo['title'] = request_data['title'].strip()
        if 'description' in request_data:
            todo['description'] = request_data['description'].strip()
        if 'completed' in request_data:
            todo['completed'] = bool(request_data['completed'])

        # Update timestamp
        todo['updated_at'] = datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')

        self.send_json_response(todo, 200)

    def handle_delete_todo(self, todo_id):
        user, error = self.require_auth()
        if error:
            self.send_json_response(error, 401)
            return

        # Check if todo belongs to user
        user_todos = self.todos_by_user.get(user['id'], {})
        if todo_id not in user_todos:
            self.send_json_response({'error': 'Todo not found'}, 404)
            return

        del self.todos_by_user[user['id']][todo_id]
        self.send_response(204)
        # Note: 204 should not have Content-Type or body, per HTTP standards
        self.end_headers()


def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='TodoApp Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to listen on')
    
    args = parser.parse_args()
    port = args.port
    
    server = HTTPServer(('0.0.0.0', port), TodoServer)
    print(f"Starting server on 0.0.0.0:{port}")
    server.serve_forever()


if __name__ == '__main__':
    main()