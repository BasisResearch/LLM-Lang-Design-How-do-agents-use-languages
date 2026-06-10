#!/usr/bin/env python3
import json
import re
import uuid
from datetime import datetime
try:
    from datetime import timezone  # newer Python versions
    def utcnow():
        return datetime.now(timezone.utc)
except ImportError:
    # For Python < 3.2, fall back to the original, with deprecation warning ignored
    # Actually, we'll still define a function that uses modern approach as much as possible
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", category=DeprecationWarning)
        def utcnow():
            return datetime.utcnow()

from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
try:
    from http.server import ThreadingHTTPServer
except ImportError:
    # Fallback for older Python versions
    from socketserver import ThreadingMixIn
    import socketserver
    
    class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True
    
import socket
import errno


class ThreadedTodoAppServer(BaseHTTPRequestHandler):
    # Class-level storage so all instances share the same data
    users = {}  # {id: {'username': str, 'password': str}}
    usernames = {}  # {username: user_id}
    todos = {}  # {id: {'user_id': int, 'title': str, 'desc': str, ...}}
    sessions = {}  # {session_id: user_id}
    next_user_id = 1
    next_todo_id = 1

    def _set_headers(self, status_code=200, content_type='application/json'):
        self.send_response(status_code)
        if content_type:
            self.send_header('Content-Type', content_type)
        self.end_headers()

    def _get_cookie_value(self, cookie_name):
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return None
        
        cookies = {}
        for cookie in cookie_header.split(';'):
            if '=' in cookie:
                name, value = cookie.strip().split('=', 1)
                cookies[name] = value
        
        return cookies.get(cookie_name)

    def _verify_auth(self):
        session_id = self._get_cookie_value('session_id')
        if not session_id or session_id not in self.sessions:
            return None
        return self.sessions[session_id]

    def _send_json_response(self, data, status_code=200, content_type='application/json'):
        try:
            response_data = json.dumps(data).encode()
            self.send_response(status_code)
            if content_type:
                self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(response_data)))
            self.end_headers()
            self.wfile.write(response_data)
        except BrokenPipeError:
            # Client disconnected, ignore
            pass

    def _send_empty_response(self, status_code=200):
        self.send_response(status_code)
        self.end_headers()

    def _send_error(self, message, status_code=400):
        try:
            self._send_json_response({'error': message}, status_code)
        except BrokenPipeError:
            # Client disconnected, ignore
            pass

    def _parse_body(self):
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            try:
                body = self.rfile.read(content_length).decode()
                return json.loads(body)
            except json.JSONDecodeError:
                return None
        else:
            return {}

    def _create_timestamp(self):
        return utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

    def _validate_username(self, username):
        if not username or len(username) < 3 or len(username) > 50:
            return False
        return bool(re.match(r'^[a-zA-Z0-9_]+$', username))

    def _validate_password(self, password):
        if not password or len(password) < 8:
            return False
        return True

    def do_POST(self):
        try:
            parsed_path = urlparse(self.path)
            
            if parsed_path.path == '/register':
                self._handle_register()
            elif parsed_path.path == '/login':
                self._handle_login()
            elif parsed_path.path == '/logout':
                self._handle_logout()
            elif parsed_path.path == '/todos':
                self._handle_create_todo()
            elif parsed_path.path == '/password':
                self._handle_change_password()
            else:
                self._send_error('Endpoint not found', 404)
        except BrokenPipeError:
            pass
        except Exception:
            self._send_error('Internal server error', 500)

    def do_GET(self):
        try:
            parsed_path = urlparse(self.path)
            
            if parsed_path.path == '/me':
                self._handle_get_me()
            elif parsed_path.path == '/todos':
                self._handle_get_todos()
            elif parsed_path.path.startswith('/todos/'):
                # Extract ID from /todos/{id}
                try:
                    todo_ids = parsed_path.path[len('/todos/'):]
                    if '/' in todo_ids:
                        parts = todo_ids.split('/', 1)
                        todo_id = int(parts[0])
                    else:
                        todo_id = int(todo_ids)
                    self._handle_get_todo(todo_id)
                except ValueError:
                    self._send_error('Invalid todo ID', 400)
            else:
                self._send_error('Endpoint not found', 404)
        except BrokenPipeError:
            pass
        except Exception:
            self._send_error('Internal server error', 500)

    def do_PUT(self):
        try:
            parsed_path = urlparse(self.path)
            
            if parsed_path.path == '/password':
                self._handle_change_password()
            elif parsed_path.path.startswith('/todos/'):
                # Extract ID from /todos/{id}
                try:
                    todo_ids = parsed_path.path[len('/todos/'):]
                    if '/' in todo_ids:
                        parts = todo_ids.split('/', 1)
                        todo_id = int(parts[0])
                    else:
                        todo_id = int(todo_ids)
                    self._handle_update_todo(todo_id)
                except ValueError:
                    self._send_error('Invalid todo ID', 400)
            else:
                self._send_error('Endpoint not found', 404)
        except BrokenPipeError:
            pass
        except Exception:
            self._send_error('Internal server error', 500)

    def do_DELETE(self):
        try:
            parsed_path = urlparse(self.path)
            
            if parsed_path.path.startswith('/todos/'):
                # Extract ID from /todos/{id}
                try:
                    todo_ids = parsed_path.path[len('/todos/'):]
                    if '/' in todo_ids:
                        parts = todo_ids.split('/', 1)
                        todo_id = int(parts[0])
                    else:
                        todo_id = int(todo_ids)
                    self._handle_delete_todo(todo_id)
                except ValueError:
                    self._send_error('Invalid todo ID', 400)
            else:
                self._send_error('Endpoint not found', 404)
        except BrokenPipeError:
            pass
        except Exception:
            self._send_error('Internal server error', 500)

    def _check_auth_or_send_error(self):
        user_id = self._verify_auth()
        if user_id is None:
            self._send_error('Authentication required', 401)
            return None
        return user_id

    def _handle_register(self):
        data = self._parse_body()
        if not data:
            self._send_error('Invalid JSON', 400)
            return

        username = data.get('username')
        password = data.get('password')

        # Validation checks
        if not username or not self._validate_username(username):
            self._send_error('Invalid username', 400)
            return

        if not password or not self._validate_password(password):
            self._send_error('Password too short', 400)
            return

        if username in self.__class__.usernames:
            self._send_error('Username already exists', 409)
            return

        user_id = self.__class__.next_user_id
        self.__class__.next_user_id += 1
        self.__class__.usernames[username] = user_id
        self.__class__.users[user_id] = {
            'id': user_id,
            'username': username,
            'password': password  # In production you'd hash this
        }

        response = {'id': user_id, 'username': username}
        self._send_json_response(response, 201)

    def _handle_login(self):
        data = self._parse_body()
        if not data:
            self._send_error('Invalid JSON', 400)
            return

        username = data.get('username')
        password = data.get('password')

        if not username or not password:
            self._send_error('Username and password required', 400)
            return

        user_id = self.__class__.usernames.get(username)
        if not user_id or self.__class__.users[user_id]['password'] != password:
            self._send_error('Invalid credentials', 401)
            return

        session_id = str(uuid.uuid4())
        self.__class__.sessions[session_id] = user_id

        response = {'id': user_id, 'username': username}
        self.send_response(200)
        self.send_header('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')
        self.send_header('Content-Type', 'application/json')
        response_data = json.dumps(response).encode()
        self.send_header('Content-Length', str(len(response_data)))
        self.end_headers()
        try:
            self.wfile.write(response_data)
        except BrokenPipeError:
            pass

    def _handle_logout(self):
        user_id = self._check_auth_or_send_error()
        if user_id is None:
            return

        session_id = self._get_cookie_value('session_id')
        if session_id and session_id in self.__class__.sessions:
            del self.__class__.sessions[session_id]

        self._send_json_response({})

    def _handle_get_me(self):
        user_id = self._check_auth_or_send_error()
        if user_id is None:
            return

        user = self.__class__.users.get(user_id)
        if not user:
            self._send_error('User not found', 404)
            return

        self._send_json_response({'id': user['id'], 'username': user['username']})

    def _handle_change_password(self):
        user_id = self._check_auth_or_send_error()
        if user_id is None:
            return

        data = self._parse_body()
        if not data:
            self._send_error('Invalid JSON', 400)
            return

        old_password = data.get('old_password')
        new_password = data.get('new_password')

        if not old_password or not new_password:
            self._send_error('Both old_password and new_password are required', 400)
            return

        current_password = self.__class__.users[user_id]['password']
        if current_password != old_password:
            self._send_error('Invalid credentials', 401)
            return

        if not self._validate_password(new_password):
            self._send_error('Password too short', 400)
            return

        self.__class__.users[user_id]['password'] = new_password
        self._send_json_response({})

    def _handle_get_todos(self):
        user_id = self._check_auth_or_send_error()
        if user_id is None:
            return

        user_todos = []
        for todo_id, todo in self.__class__.todos.items():
            if todo['user_id'] == user_id:
                user_todos.append({
                    'id': todo_id,
                    'title': todo['title'],
                    'description': todo['description'],
                    'completed': todo['completed'],
                    'created_at': todo['created_at'],
                    'updated_at': todo['updated_at']
                })

        # Sort by ID ascending
        user_todos.sort(key=lambda x: x['id'])
        self._send_json_response(user_todos)

    def _handle_create_todo(self):
        user_id = self._check_auth_or_send_error()
        if user_id is None:
            return

        data = self._parse_body()
        if not data:
            self._send_error('Invalid JSON', 400)
            return

        title = data.get('title')
        description = data.get('description', '')

        if not title:
            self._send_error('Title is required', 400)
            return

        now = self._create_timestamp()
        todo_id = self.__class__.next_todo_id
        self.__class__.next_todo_id += 1

        self.__class__.todos[todo_id] = {
            'user_id': user_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now,
            'updated_at': now
        }

        response = {
            'id': todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now,
            'updated_at': now
        }
        self._send_json_response(response, 201)

    def _handle_get_todo(self, todo_id):
        user_id = self._check_auth_or_send_error()
        if user_id is None:
            return

        todo = self.__class__.todos.get(todo_id)
        if todo is None or todo['user_id'] != user_id:
            self._send_error('Todo not found', 404)
            return

        response = {
            'id': todo_id,
            'title': todo['title'],
            'description': todo['description'],
            'completed': todo['completed'],
            'created_at': todo['created_at'],
            'updated_at': todo['updated_at']
        }
        self._send_json_response(response)

    def _handle_update_todo(self, todo_id):
        user_id = self._check_auth_or_send_error()
        if user_id is None:
            return

        todo = self.__class__.todos.get(todo_id)
        if todo is None or todo['user_id'] != user_id:
            self._send_error('Todo not found', 404)
            return

        data = self._parse_body()
        if not data:
            self._send_error('Invalid JSON', 400)
            return

        # Validate title if provided
        if 'title' in data:
            title = data['title']
            if not title:  # Empty title
                self._send_error('Title is required', 400)
                return
            todo['title'] = title

        # Update other fields if provided
        if 'description' in data:
            todo['description'] = data['description']

        if 'completed' in data:
            todo['completed'] = data['completed']

        now = self._create_timestamp()
        todo['updated_at'] = now

        response = {
            'id': todo_id,
            'title': todo['title'],
            'description': todo['description'],
            'completed': todo['completed'],
            'created_at': todo['created_at'],
            'updated_at': now
        }
        self._send_json_response(response)

    def _handle_delete_todo(self, todo_id):
        user_id = self._check_auth_or_send_error()
        if user_id is None:
            return

        todo = self.__class__.todos.get(todo_id)
        if todo is None or todo['user_id'] != user_id:
            self._send_error('Todo not found', 404)
            return

        del self.__class__.todos[todo_id]
        self.send_response(204)  # 204 No Content for successful deletion
        self.end_headers()


def run_server(port):
    server = ThreadingHTTPServer(('0.0.0.0', port), ThreadedTodoAppServer)
    print(f"Starting Todo app server on 0.0.0.0:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        server.shutdown()


if __name__ == '__main__':
    import sys
    import argparse

    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, default=8000, help='Port number to listen on')
    
    args = parser.parse_args()
    run_server(args.port)