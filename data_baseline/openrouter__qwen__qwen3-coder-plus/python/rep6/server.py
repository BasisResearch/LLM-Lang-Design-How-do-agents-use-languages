#!/usr/bin/env python3
"""
Todo App API Server
REST API for managing personal TODO items with cookie-based authentication.
"""

import json
import re
import sys
import argparse
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import uuid
import hashlib
import threading


# Global storage accessible by all instances
users = {}  # {user_id: {"id": int, "username": str, "password_hash": str}, ...}
usernames = {}  # {username: user_id, ...}
sessions = {}  # {session_id: user_id, ...}
todos = {}  # {todo_id: {"id": int, "user_id": int, "title": str, "description": str, "completed": bool, "created_at": str, "updated_at": str}}

next_user_id = 1
next_todo_id = 1
lock = threading.Lock()  # Thread lock to manage concurrent access


def get_current_time():
    """Return current UTC time in YYYY-MM-DDTHH:MM:SSZ format."""
    return datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')


def hash_password(password):
    """Hash password using SHA256."""
    return hashlib.sha256(password.encode()).hexdigest()


def extract_session_id_from_headers(headers):
    """Extract session_id from cookies."""
    auth_header = headers.get('Cookie')
    if not auth_header:
        return None
    
    cookies = {}
    for cookie in auth_header.split(';'):
        cookie = cookie.strip()
        if '=' in cookie:
            key, value = cookie.split('=', 1)
            cookies[key] = value
    
    return cookies.get('session_id')


def authenticate(headers):
    """Check if request has valid session."""
    session_id = extract_session_id_from_headers(headers)
    if not session_id or session_id not in sessions:
        return False, None
    return True, sessions[session_id]


def send_json_response(handler, status_code, data=None, headers=None):
    """Send JSON response with proper content-type header."""
    handler.send_response(status_code)
    
    if headers:
        for key, value in headers.items():
            handler.send_header(key, value)
    
    if status_code != 204:  # No content for 204
        handler.send_header('Content-type', 'application/json')
        handler.end_headers()
        
        if data is not None:
            handler.wfile.write(json.dumps(data).encode())
    else:
        handler.end_headers()


def send_error(handler, status_code, message):
    """Send error response."""
    send_json_response(handler, status_code, {"error": message})


def parse_request_body(handler):
    """Parse and return JSON from request body."""
    content_length = int(handler.headers.get('Content-Length', 0))
    if content_length == 0:
        return {}
    body = handler.rfile.read(content_length)
    try:
        return json.loads(body.decode())
    except json.JSONDecodeError:
        return {}


def validate_username(username):
    """Validate username format."""
    if not username or len(username) < 3 or len(username) > 50:
        return False
    return re.match(r'^[a-zA-Z0-9_]+$', username) is not None


def handle_register(handler):
    """Register a new user."""
    global next_user_id
    
    data = parse_request_body(handler)
    username = data.get('username')
    password = data.get('password')

    # Validate username
    if not validate_username(username):
        send_error(handler, 400, "Invalid username")
        return

    # Validate password
    if not password or len(password) < 8:
        send_error(handler, 400, "Password too short")
        return

    # Check if username already exists
    with lock:
        if username in usernames:
            send_error(handler, 409, "Username already exists")
            return

        # Create new user
        user_id = next_user_id
        next_user_id += 1
        
        user = {
            'id': user_id,
            'username': username,
            'password_hash': hash_password(password)
        }
        
        users[user_id] = user
        usernames[username] = user_id
    
    send_json_response(handler, 201, {'id': user_id, 'username': username})


def handle_login(handler):
    """Login and create a session."""
    data = parse_request_body(handler)
    username = data.get('username')
    password = data.get('password')

    # Find user by username
    with lock:
        if username not in usernames:
            send_error(handler, 401, "Invalid credentials")
            return
        
        user_id = usernames[username]
        user = users[user_id]
        
        # Verify password
        if user['password_hash'] != hash_password(password):
            send_error(handler, 401, "Invalid credentials")
            return
        
        # Create session
        session_id = str(uuid.uuid4())
        sessions[session_id] = user_id
    
    # Send response with cookie
    headers = {'Set-Cookie': f'session_id={session_id}; Path=/; HttpOnly'}
    send_json_response(handler, 200, {'id': user['id'], 'username': user['username']}, headers)


def handle_logout(handler):
    """Logout by invalidating session."""
    is_auth, user_id = authenticate(handler.headers)
    if not is_auth:
        send_error(handler, 401, "Authentication required")
        return

    session_id = extract_session_id_from_headers(handler.headers)
    if session_id and session_id in sessions:
        with lock:
            if session_id in sessions:  # Double check under lock
                del sessions[session_id]
    
    send_json_response(handler, 200, {})


def handle_me(handler):
    """Get current user info."""
    is_auth, user_id = authenticate(handler.headers)
    if not is_auth:
        send_error(handler, 401, "Authentication required")
        return

    user = users[user_id]
    send_json_response(handler, 200, {'id': user['id'], 'username': user['username']})


def handle_change_password(handler):
    """Change user password."""
    is_auth, user_id = authenticate(handler.headers)
    if not is_auth:
        send_error(handler, 401, "Authentication required")
        return

    data = parse_request_body(handler)
    old_password = data.get('old_password')
    new_password = data.get('new_password')

    with lock:
        user = users[user_id]
        
        # Verify old password
        if user['password_hash'] != hash_password(old_password):
            send_error(handler, 401, "Invalid credentials")
            return

        # Validate new password
        if not new_password or len(new_password) < 8:
            send_error(handler, 400, "Password too short")
            return

        # Update password
        users[user_id]['password_hash'] = hash_password(new_password)
    
    send_json_response(handler, 200, {})


def handle_get_todos(handler):
    """Get all todos for current user."""
    is_auth, user_id = authenticate(handler.headers)
    if not is_auth:
        send_error(handler, 401, "Authentication required")
        return

    with lock:
        user_todos = []
        for todo_id, todo_item in todos.items():
            if todo_item['user_id'] == user_id:
                user_todos.append(todo_item)
    
    # Sort by id ascending
    user_todos.sort(key=lambda x: x['id'])
    send_json_response(handler, 200, user_todos)


def handle_create_todo(handler):
    """Create a new todo."""
    is_auth, user_id = authenticate(handler.headers)
    if not is_auth:
        send_error(handler, 401, "Authentication required")
        return

    global next_todo_id
    
    data = parse_request_body(handler)
    title = data.get('title')
    description = data.get('description', '')

    # Validate title
    if not title:
        send_error(handler, 400, "Title is required")
        return

    # Create new todo
    with lock:
        todo_id = next_todo_id
        next_todo_id += 1
        
        now = get_current_time()
        todo = {
            'id': todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now,
            'updated_at': now,
            'user_id': user_id
        }
        
        todos[todo_id] = todo
    
    send_json_response(handler, 201, todo)


def handle_get_todo_by_id(handler, todo_id):
    """Get a specific todo by ID."""
    is_auth, user_id = authenticate(handler.headers)
    if not is_auth:
        send_error(handler, 401, "Authentication required")
        return

    with lock:
        if todo_id not in todos:
            send_error(handler, 404, "Todo not found")
            return

        todo = todos[todo_id]
        
        # Check if the todo belongs to the current user
        if todo['user_id'] != user_id:
            send_error(handler, 404, "Todo not found")
            return

        send_json_response(handler, 200, todo)


def handle_update_todo(handler, todo_id):
    """Update a specific todo by ID."""
    is_auth, user_id = authenticate(handler.headers)
    if not is_auth:
        send_error(handler, 401, "Authentication required")
        return

    with lock:
        if todo_id not in todos:
            send_error(handler, 404, "Todo not found")
            return

        todo = todos[todo_id]
        
        # Check if the todo belongs to the current user
        if todo['user_id'] != user_id:
            send_error(handler, 404, "Todo not found")
            return

        data = parse_request_body(handler)
        
        # Validate title if provided
        if 'title' in data:
            if not data['title']:  # Empty title is not allowed
                send_error(handler, 400, "Title is required")
                return
            todo['title'] = data['title']

        # Update other fields if provided
        if 'description' in data:
            todo['description'] = data['description']
        if 'completed' in data:
            todo['completed'] = data['completed']

        # Update timestamp
        todo['updated_at'] = get_current_time()

        send_json_response(handler, 200, todo)


def handle_delete_todo(handler, todo_id):
    """Delete a specific todo by ID."""
    is_auth, user_id = authenticate(handler.headers)
    if not is_auth:
        send_error(handler, 401, "Authentication required")
        return

    with lock:
        if todo_id not in todos:
            send_error(handler, 404, "Todo not found")
            return

        todo = todos[todo_id]
        
        # Check if the todo belongs to the current user
        if todo['user_id'] != user_id:
            send_error(handler, 404, "Todo not found")
            return

        del todos[todo_id]
    
    send_json_response(handler, 204)


class TodoAppServer(BaseHTTPRequestHandler):
    def do_POST(self):
        """Handle POST requests."""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/register':
            handle_register(self)
        elif parsed_path.path == '/login':
            handle_login(self)
        elif parsed_path.path == '/logout':
            handle_logout(self)
        elif parsed_path.path == '/password':
            handle_change_password(self)
        elif parsed_path.path == '/todos':
            handle_create_todo(self)
        else:
            send_error(self, 404, "Not found")

    def do_GET(self):
        """Handle GET requests."""
        parsed_path = urlparse(self.path)

        if parsed_path.path == '/me':
            handle_me(self)
        elif parsed_path.path == '/todos':
            handle_get_todos(self)
        else:
            # Handle IDs in path
            path_parts = parsed_path.path.strip('/').split('/')
            if len(path_parts) == 2 and path_parts[0] == 'todos':
                try:
                    todo_id = int(path_parts[1])
                    handle_get_todo_by_id(self, todo_id)
                except ValueError:
                    send_error(self, 404, "Not found")
            else:
                send_error(self, 404, "Not found")

    def do_PUT(self):
        """Handle PUT requests."""
        parsed_path = urlparse(self.path)

        if parsed_path.path == '/password':
            handle_change_password(self)
        else:
            # Handle IDs in path
            path_parts = parsed_path.path.strip('/').split('/')
            if len(path_parts) == 2 and path_parts[0] == 'todos':
                try:
                    todo_id = int(path_parts[1])
                    handle_update_todo(self, todo_id)
                except ValueError:
                    send_error(self, 404, "Not found")
            else:
                send_error(self, 404, "Not found")

    def do_DELETE(self):
        """Handle DELETE requests."""
        parsed_path = urlparse(self.path)

        # Handle IDs in path for todos deletion
        path_parts = parsed_path.path.strip('/').split('/')
        if len(path_parts) == 2 and path_parts[0] == 'todos':
            try:
                todo_id = int(path_parts[1])
                handle_delete_todo(self, todo_id)
            except ValueError:
                send_error(self, 404, "Not found")
        else:
            send_error(self, 404, "Not found")


def run_server(port):
    """Run the server on specified port."""
    server = HTTPServer(('0.0.0.0', port), TodoAppServer)
    print(f"Server running on 0.0.0.0:{port}")
    server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Todo App API Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    run_server(args.port)