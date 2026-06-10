#!/usr/bin/env python3
"""
REST API server for managing personal todo items with cookie-based authentication.
"""
import json
import re
import uuid
from datetime import datetime, timezone
from http.cookies import SimpleCookie
from typing import Dict, List, Optional
from urllib.parse import urlparse

from http.server import HTTPServer, BaseHTTPRequestHandler


def get_current_timestamp():
    """Generate ISO 8601 UTC timestamp with second precision."""
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


class TodoAppServer(BaseHTTPRequestHandler):
    # Class variables for shared state across all requests
    users = {}  # {id: {'id': int, 'username': str, 'password': str}}
    usernames = {}  # {username: id}
    sessions = {}  # {session_id: user_id}
    todos = {}  # {id: {'id': int, 'user_id': int, 'title': str, 'description': str, 'completed': bool, 'created_at': str, 'updated_at': str}}
    next_user_id = 1
    next_todo_id = 1

    def _parse_request_body(self):
        """Parse the JSON request body."""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            body = self.rfile.read(content_length).decode('utf-8')
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                return None
        return {}

    def _get_session_id(self):
        """Extract session ID from cookies."""
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return None
        
        try:
            cookies = SimpleCookie()
            cookies.load(cookie_header)
            session_cookie = cookies.get('session_id')
            if session_cookie:
                return session_cookie.value
        except Exception:
            pass
        return None

    def _get_authenticated_user(self):
        """Get the authenticated user based on session ID."""
        session_id = self._get_session_id()
        if not session_id or session_id not in self.sessions:
            return None
        
        user_id = self.sessions[session_id]
        return self.users.get(user_id)

    def _send_json_response(self, status_code, data=None, headers=None):
        """Send a JSON response."""
        self.send_response(status_code)
        
        # Add Content-Type header
        self.send_header('Content-Type', 'application/json')
        
        # Add custom headers if provided
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
        
        self.end_headers()
        
        if data is not None:
            self.wfile.write(json.dumps(data).encode('utf-8'))

    def _send_error_response(self, status_code, message):
        """Send an error response."""
        error_data = {"error": message}
        self._send_json_response(status_code, error_data)

    def _require_auth(self):
        """Check if the request is authenticated. Return user if authenticated, else send 401."""
        user = self._get_authenticated_user()
        if not user:
            self._send_error_response(401, "Authentication required")
            return None
        return user

    def _is_valid_username(self, username):
        """Validate username format."""
        return username and len(username) >= 3 and len(username) <= 50 and re.match(r'^[a-zA-Z0-9_]+$', username)

    def _is_valid_password(self, password):
        """Validate password length."""
        return password and len(password) >= 8

    def do_POST(self):
        """Handle POST requests."""
        if self.path == '/register':
            self._handle_register()
        elif self.path == '/login':
            self._handle_login()
        elif self.path == '/logout':
            self._handle_logout()
        elif self.path == '/password':
            user = self._require_auth()
            if user:
                self._handle_change_password()
        elif self.path == '/todos':
            user = self._require_auth()
            if user:
                self._handle_create_todo()
        else:
            self._send_error_response(404, "Endpoint not found")

    def do_GET(self):
        """Handle GET requests."""
        if self.path == '/me':
            user = self._require_auth()
            if user:
                self._handle_get_me()
        elif self.path == '/todos':
            user = self._require_auth()
            if user:
                self._handle_get_todos()
        else:
            # Check if path matches /todos/:id
            import re
            match = re.match(r'^/todos/(\d+)$', self.path)
            if match:
                todo_id = int(match.group(1))
                user = self._require_auth()
                if user:
                    self._handle_get_todo(todo_id)
            else:
                self._send_error_response(404, "Endpoint not found")

    def do_PUT(self):
        """Handle PUT requests."""
        # Check if path matches /todos/:id
        import re
        match = re.match(r'^/todos/(\d+)$', self.path)
        if match:
            todo_id = int(match.group(1))
            user = self._require_auth()
            if user:
                self._handle_update_todo(todo_id)
        elif self.path == '/password':
            user = self._require_auth()
            if user:
                self._handle_change_password()
        else:
            self._send_error_response(404, "Endpoint not found")

    def do_DELETE(self):
        """Handle DELETE requests."""
        # Check if path matches /todos/:id
        import re
        match = re.match(r'^/todos/(\d+)$', self.path)
        if match:
            todo_id = int(match.group(1))
            user = self._require_auth()
            if user:
                self._handle_delete_todo(todo_id)
        else:
            self._send_error_response(404, "Endpoint not found")

    def _handle_register(self):
        """Handle user registration."""
        data = self._parse_request_body()
        if not data:
            self._send_error_response(400, "Invalid JSON")
            return

        username = data.get('username', '').strip()
        password = data.get('password', '')

        if not self._is_valid_username(username):
            self._send_error_response(400, "Invalid username")
            return

        if not self._is_valid_password(password):
            self._send_error_response(400, "Password too short")
            return

        if username in self.usernames:
            self._send_error_response(409, "Username already exists")
            return

        user_id = TodoAppServer.next_user_id
        TodoAppServer.next_user_id += 1

        # Store user data
        TodoAppServer.users[user_id] = {
            'id': user_id,
            'username': username,
            'password': password
        }
        TodoAppServer.usernames[username] = user_id

        # Success response
        response = {
            'id': user_id,
            'username': username
        }
        self._send_json_response(201, response)

    def _handle_login(self):
        """Handle user login."""
        data = self._parse_request_body()
        if not data:
            self._send_error_response(400, "Invalid JSON")
            return

        username = data.get('username', '').strip()
        password = data.get('password', '')

        if not username or not password:
            self._send_error_response(400, "Missing username or password")
            return

        user_id = TodoAppServer.usernames.get(username)
        if not user_id:
            self._send_error_response(401, "Invalid credentials")
            return

        user = TodoAppServer.users[user_id]
        if user['password'] != password:
            self._send_error_response(401, "Invalid credentials")
            return

        # Generate session token
        session_id = uuid.uuid4().hex
        TodoAppServer.sessions[session_id] = user_id

        # Send response with Set-Cookie header
        headers = {
            'Set-Cookie': f'session_id={session_id}; Path=/; HttpOnly'
        }
        response = {
            'id': user['id'],
            'username': user['username']
        }
        self._send_json_response(200, response, headers)

    def _handle_logout(self):
        """Handle user logout."""
        session_id = self._get_session_id()
        if session_id in TodoAppServer.sessions:
            del TodoAppServer.sessions[session_id]
        
        self._send_json_response(200, {})

    def _handle_get_me(self):
        """Return authenticated user info."""
        user = self._get_authenticated_user()
        if not user:
            self._send_error_response(401, "Authentication required")
            return
        
        response = {
            'id': user['id'],
            'username': user['username']
        }
        self._send_json_response(200, response)

    def _handle_change_password(self):
        """Handle password change."""
        data = self._parse_request_body()
        if not data:
            self._send_error_response(400, "Invalid JSON")
            return

        old_password = data.get('old_password', '')
        new_password = data.get('new_password', '')

        user = self._get_authenticated_user()
        if user['password'] != old_password:
            self._send_error_response(401, "Invalid credentials")
            return

        if not self._is_valid_password(new_password):
            self._send_error_response(400, "Password too short")
            return

        user['password'] = new_password  # Update user in place
        TodoAppServer.users[user['id']] = user  # Update in global storage
        self._send_json_response(200, {})

    def _handle_get_todos(self):
        """Get all todos for authenticated user."""
        user = self._get_authenticated_user()
        if not user:
            return  # Error response already sent by _require_auth

        user_todos = []
        for todo in TodoAppServer.todos.values():
            if todo['user_id'] == user['id']:
                user_todos.append(todo)
        
        # Sort by ID ascending
        user_todos.sort(key=lambda x: x['id'])
        self._send_json_response(200, user_todos)

    def _handle_create_todo(self):
        """Create a new todo."""
        data = self._parse_request_body()
        if not data:
            self._send_error_response(400, "Invalid JSON")
            return

        title = data.get('title', '').strip()
        description = data.get('description', '')

        if not title:
            self._send_error_response(400, "Title is required")
            return

        user = self._get_authenticated_user()
        if not user:
            return  # Error response already sent by _require_auth

        todo_id = TodoAppServer.next_todo_id
        TodoAppServer.next_todo_id += 1

        timestamp = get_current_timestamp()
        todo = {
            'id': todo_id,
            'user_id': user['id'],
            'title': title,
            'description': description,
            'completed': False,
            'created_at': timestamp,
            'updated_at': timestamp
        }
        TodoAppServer.todos[todo_id] = todo

        self._send_json_response(201, todo)

    def _handle_get_todo(self, todo_id):
        """Get a specific todo."""
        user = self._get_authenticated_user()
        if not user:
            return  # Error response already sent by _require_auth

        todo = TodoAppServer.todos.get(todo_id)
        if not todo or todo['user_id'] != user['id']:
            self._send_error_response(404, "Todo not found")
            return

        self._send_json_response(200, todo)

    def _handle_update_todo(self, todo_id):
        """Update a specific todo."""
        data = self._parse_request_body()
        if not data:
            self._send_error_response(400, "Invalid JSON")
            return

        user = self._get_authenticated_user()
        if not user:
            return  # Error response already sent by _require_auth

        todo = TodoAppServer.todos.get(todo_id)
        if not todo or todo['user_id'] != user['id']:
            self._send_error_response(404, "Todo not found")
            return

        # Validate title if present
        if 'title' in data and data['title'].strip() == '':
            self._send_error_response(400, "Title is required")
            return

        # Update fields if present in the request
        for field in ['title', 'description', 'completed']:
            if field in data:
                todo[field] = data[field]

        # If title was modified, trim whitespace
        if 'title' in data:
            todo['title'] = todo['title'].strip()

        # Update timestamp
        todo['updated_at'] = get_current_timestamp()

        # Save updated todo to storage
        TodoAppServer.todos[todo_id] = todo
        self._send_json_response(200, todo)

    def _handle_delete_todo(self, todo_id):
        """Delete a specific todo."""
        user = self._get_authenticated_user()
        if not user:
            return  # Error response already sent by _require_auth

        todo = TodoAppServer.todos.get(todo_id)
        if not todo or todo['user_id'] != user['id']:
            self._send_error_response(404, "Todo not found")
            return

        del TodoAppServer.todos[todo_id]
        self.send_response(204)
        self.end_headers()


if __name__ == '__main__':
    import sys
    import argparse
    
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, default=8080, help='Port to listen on')
    args = parser.parse_args()
    
    server = HTTPServer(('0.0.0.0', args.port), TodoAppServer)
    print(f"Starting server on 0.0.0.0:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        server.shutdown()