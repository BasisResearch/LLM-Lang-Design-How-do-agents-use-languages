#!/usr/bin/env python3
"""
REST API server for managing personal todo items with cookie-based authentication
"""
import json
import re
import uuid
from datetime import datetime, timezone
from http.cookies import SimpleCookie
from typing import Dict, List, Optional
from urllib.parse import parse_qs, urlparse

from http.server import HTTPServer, BaseHTTPRequestHandler

# In-memory storage
users = {}
todos = {}
sessions = {}
next_user_id = 1
next_todo_id = 1

class User:
    def __init__(self, user_id: int, username: str, password: str):
        self.id = user_id
        self.username = username
        self.password = password # In production, this should be hashed
        self.todo_ids = []

class Todo:
    def __init__(self, todo_id: int, user_id: int, title: str, description: str = ""):
        self.id = todo_id
        self.user_id = user_id  # Reference to user who owns the todo
        self.title = title
        self.description = description
        self.completed = False
        self.created_at = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        self.updated_at = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def validate_username(username: str) -> bool:
    """Check if username matches the pattern ^[a-zA-Z0-9_]+$
    and has length between 3-50 characters."""
    return re.match(r'^[a-zA-Z0-9_]{3,50}$', username) is not None

def get_current_timestamp():
    """Get current UTC timestamp in the required format."""
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def authenticate_request(headers) -> Optional[int]:
    """Extract session ID from cookies and return associated user ID,
    or None if authentication fails."""
    auth_header = headers.get('Cookie')
    if not auth_header:
        return None
    
    cookies = SimpleCookie()
    cookies.load(auth_header)
    
    session_cookie = cookies.get('session_id')
    if not session_cookie:
        return None
    
    session_id = session_cookie.value
    return sessions.get(session_id)

class TodoRequestHandler(BaseHTTPRequestHandler):
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        
    def _set_headers(self, status_code=200, content_type='application/json'):
        """Set response headers."""
        self.send_response(status_code)
        if content_type:
            self.send_header('Content-Type', content_type)
        self.end_headers()
    
    def _send_json_response(self, data, status_code=200):
        """Send JSON response."""
        self._set_headers(status_code)
        if data is not None:
            self.wfile.write(json.dumps(data).encode())
    
    def _send_no_content(self, status_code=204):
        """Send 204 No Content response."""
        self.send_response(status_code)
        self.end_headers()
    
    def _get_body(self):
        """Get request body as JSON."""
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        return json.loads(body.decode()) if body else {}
    
    def _require_auth(self):
        """Check if request is authenticated."""
        user_id = authenticate_request(self.headers)
        if not user_id:
            return False, None
        return True, user_id
    
    def _check_todo_access(self, todo_id: int, user_id: int) -> bool:
        """Check if a user has access to a particular todo."""
        todo = todos.get(todo_id)
        if not todo:
            return False
        return todo.user_id == user_id
    
    def do_GET(self):
        """Handle GET requests."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if path_parts[0] == 'me':
            # Check authentication
            auth, user_id = self._require_auth()
            if not auth:
                self._send_json_response({'error': 'Authentication required'}, 401)
                return
            
            # Get user by ID
            user = users.get(user_id)
            if not user:
                self._send_json_response({'error': 'User not found'}, 500)  # Should never happen
                return
            
            result = {
                'id': user.id,
                'username': user.username
            }
            self._send_json_response(result)
            
        elif len(path_parts) == 2 and path_parts[0] == 'todos':
            # Get specific todo
            try:
                todo_id = int(path_parts[1])
            except ValueError:
                self._send_json_response({'error': 'Invalid todo ID'}, 400)
                return
            
            # Check authentication
            auth, user_id = self._require_auth()
            if not auth:
                self._send_json_response({'error': 'Authentication required'}, 401)
                return
                
            # Check if user can access this todo
            if not self._check_todo_access(todo_id, user_id):
                self._send_json_response({'error': 'Todo not found'}, 404)
                return
            
            # Return todo
            todo = todos.get(todo_id)
            if not todo:
                self._send_json_response({'error': 'Todo not found'}, 404)
                return
            self._send_json_response(todo.__dict__)
            
        elif path_parts[0] == 'todos':
            # Check authentication
            auth, user_id = self._require_auth()
            if not auth:
                self._send_json_response({'error': 'Authentication required'}, 401)
                return
            
            # List all todos for this user
            user = users.get(user_id)
            if not user:
                self._send_json_response([], 200)
                return
            user_todos = [todo.__dict__ for todo_id in user.todo_ids 
                          for todo in [todos.get(todo_id)] 
                          if todo is not None]
            self._send_json_response(user_todos)
            
        else:
            self._send_json_response({'error': 'Endpoint not found'}, 404)
    
    def do_POST(self):
        """Handle POST requests."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if path_parts[0] == 'register':
            # Handle registration
            try:
                request_data = self._get_body()
            except json.JSONDecodeError:
                self._send_json_response({'error': 'Invalid JSON in request'}, 400)
                return
            
            username = request_data.get('username')
            password = request_data.get('password')
            
            if not username:
                self._send_json_response({'error': 'Invalid username'}, 400)
                return
                
            if not validate_username(username):
                self._send_json_response({'error': 'Invalid username'}, 400)
                return
                
            if not password or len(password) < 8:
                self._send_json_response({'error': 'Password too short'}, 400)
                return
            
            # Check if username already exists
            for user in users.values():
                if user.username == username:
                    self._send_json_response({'error': 'Username already exists'}, 409)
                    return
            
            # Create new user (auto-increment ID)
            global next_user_id
            user_id = next_user_id
            next_user_id += 1
            new_user = User(user_id, username, password)
            users[user_id] = new_user
            
            result = {
                'id': new_user.id,
                'username': new_user.username
            }
            self._send_json_response(result, 201)
        
        elif path_parts[0] == 'login':
            # Handle login
            try:
                request_data = self._get_body()
            except json.JSONDecodeError:
                self._send_json_response({'error': 'Invalid JSON in request'}, 400)
                return
            
            username = request_data.get('username')
            password = request_data.get('password')
            
            # Find user by username
            target_user = None
            for user in users.values():
                if user.username == username:
                    target_user = user
                    break
                    
            if not target_user or target_user.password != password:
                self._send_json_response({'error': 'Invalid credentials'}, 401)
                return
            
            # Generate session
            session_id = str(uuid.uuid4())
            sessions[session_id] = target_user.id
            
            # Send response with SET_COOKIE header
            result = {
                'id': target_user.id,
                'username': target_user.username
            }
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
        
        elif path_parts[0] == 'logout':
            # Check authentication
            auth, user_id = self._require_auth()
            if not auth:
                self._send_json_response({'error': 'Authentication required'}, 401)
                return
            
            # Remove session for current user (based on cookie)
            auth_header = self.headers.get('Cookie')
            if auth_header:
                cookies = SimpleCookie()
                cookies.load(auth_header)
                
                session_cookie = cookies.get('session_id')
                if session_cookie:
                    session_id = session_cookie.value
                    if session_id in sessions:
                        del sessions[session_id]
                        
            self._send_json_response({})
        
        elif path_parts[0] == 'todos':
            # Check authentication
            auth, user_id = self._require_auth()
            if not auth:
                self._send_json_response({'error': 'Authentication required'}, 401)
                return
            
            # Create new todo
            try:
                request_data = self._get_body()
            except json.JSONDecodeError:
                self._send_json_response({'error': 'Invalid JSON in request'}, 400)
                return
                
            title = request_data.get('title')
            description = request_data.get('description') or ""
            
            if not title:
                self._send_json_response({'error': 'Title is required'}, 400)
                return
                
            # Create new todo
            global next_todo_id
            todo_id = next_todo_id
            next_todo_id += 1
            new_todo = Todo(todo_id, user_id, title, description)
            todos[todo_id] = new_todo
            users[user_id].todo_ids.append(todo_id)
            
            self._send_json_response(new_todo.__dict__, 201)
        
        else:
            self._send_json_response({'error': 'Endpoint not found'}, 404)
    
    def do_PUT(self):
        """Handle PUT requests."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if path_parts[0] == 'password':
            # Update password
            auth, user_id = self._require_auth()
            if not auth:
                self._send_json_response({'error': 'Authentication required'}, 401)
                return
            
            try:
                request_data = self._get_body()
            except json.JSONDecodeError:
                self._send_json_response({'error': 'Invalid JSON in request'}, 400)
                return
            
            old_password = request_data.get('old_password')
            new_password = request_data.get('new_password')
            
            # Validate current password
            user = users.get(user_id)
            if user.password != old_password:
                self._send_json_response({'error': 'Invalid credentials'}, 401)
                return
                
            # Validate new password length
            if not new_password or len(new_password) < 8:
                self._send_json_response({'error': 'Password too short'}, 400)
                return
                
            # Update password
            user.password = new_password
            self._send_json_response({})
        
        elif len(path_parts) == 2 and path_parts[0] == 'todos':
            # Check authentication
            auth, user_id = self._require_auth()
            if not auth:
                self._send_json_response({'error': 'Authentication required'}, 401)
                return
                
            # Update specific todo
            try:
                todo_id = int(path_parts[1])
            except ValueError:
                self._send_json_response({'error': 'Invalid todo ID'}, 400)
                return
            
            # Check if user can access this todo
            if not self._check_todo_access(todo_id, user_id):
                self._send_json_response({'error': 'Todo not found'}, 404)
                return
            
            try:
                request_data = self._get_body()
            except json.JSONDecodeError:
                self._send_json_response({'error': 'Invalid JSON in request'}, 400)
                return
            
            # Get the todo object
            todo = todos.get(todo_id)
            if not todo:
                self._send_json_response({'error': 'Todo not found'}, 404)
                return
            
            # Update fields that exist in the request
            # Handle updating title (if provided)
            if 'title' in request_data:
                title = request_data['title']
                if not title:
                    self._send_json_response({'error': 'Title is required'}, 400)
                    return
                todo.title = title
            
            # Handle updating description (if provided)
            if 'description' in request_data:
                todo.description = request_data['description']
            
            # Handle setting completed status (if provided)
            if 'completed' in request_data:
                completed = request_data['completed']
                if not isinstance(completed, bool):
                    self._send_json_response({'error': 'Completed field must be boolean'}, 400)
                    return
                todo.completed = completed
            
            # Update the timestamp
            todo.updated_at = get_current_timestamp()
            self._send_json_response(todo.__dict__)
        
        else:
            self._send_json_response({'error': 'Endpoint not found'}, 404)
    
    def do_DELETE(self):
        """Handle DELETE requests."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if len(path_parts) == 2 and path_parts[0] == 'todos':
            # Check authentication
            auth, user_id = self._require_auth()
            if not auth:
                self._send_json_response({'error': 'Authentication required'}, 401)
                return
            
            # Delete specific todo
            try:
                todo_id = int(path_parts[1])
            except ValueError:
                self._send_json_response({'error': 'Invalid todo ID'}, 400)
                return
            
            # Check if user can access this todo
            if not self._check_todo_access(todo_id, user_id):
                self._send_json_response({'error': 'Todo not found'}, 404)
                return
                
            # Remove from user's todo list and delete the todo
            user = users.get(user_id)
            if user and todo_id in user.todo_ids:
                user.todo_ids.remove(todo_id)
            if todo_id in todos:
                del todos[todo_id]
            
            self._send_no_content(204)
        
        else:
            self._send_json_response({'error': 'Endpoint not found'}, 404)


def run_server(port):
    """Run the HTTP server on the specified port."""
    server_address = ('0.0.0.0', port)
    httpd = HTTPServer(server_address, TodoRequestHandler)
    print(f'Starting server on {server_address[0]}:{server_address[1]}...')
    httpd.serve_forever()


if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='Todo REST API Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    
    args = parser.parse_args()
    run_server(args.port)