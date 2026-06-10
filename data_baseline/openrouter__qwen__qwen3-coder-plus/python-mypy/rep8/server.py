#!/usr/bin/env python3
"""
Todo App REST API Server

This implementation manages personal todo items using cookie-based authentication.
All data is stored in-memory for simplicity.
"""

import argparse
import json
import re
import secrets
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple, Any
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Lock


class User:
    """Represents a user in the system."""
    
    def __init__(self, user_id: int, username: str, password_hash: str) -> None:
        self.id: int = user_id
        self.username: str = username
        self.password_hash: str = password_hash  # In a real app, store hashed passwords
    

class Todo:
    """Represents a todo item."""
    
    def __init__(
            self,
            todo_id: int,
            title: str,
            description: str,
            completed: bool,
            created_at: str,
            updated_at: str
    ) -> None:
        self.id: int = todo_id
        self.title: str = title
        self.description: str = description
        self.completed: bool = completed
        self.created_at: str = created_at
        self.updated_at: str = updated_at
    

# Global variables for shared state
_shared_users: Dict[int, User] = {}
_shared_todos: Dict[int, Tuple[int, Todo]] = {}
_shared_sessions: Dict[str, int] = {}
_next_user_id = 1  # Using module-level state
_next_todo_id = 1
_state_lock = Lock()

class TodoAppServer(BaseHTTPRequestHandler):
    """HTTP request handler for the Todo App server."""
    
    def _get_cookie_value(self, cookie_name: str) -> Optional[str]:
        """Extract cookie value from headers."""
        cookie_header = self.headers.get('Cookie', '')
        if not cookie_header:
            return None
        
        cookies = [c.strip() for c in cookie_header.split(';')]
        for cookie in cookies:
            if '=' in cookie:
                key, value = cookie.split('=', 1)
                if key.strip() == cookie_name:
                    return value.strip()
        
        return None
    
    def _generate_session_id(self) -> str:
        """Generate a random session ID."""
        # In a production system, use a cryptographically secure method
        return secrets.token_hex(16)
    
    def _set_session(self, user_id: int) -> str:
        """Create a new session for the given user."""
        session_id = self._generate_session_id()
        _shared_sessions[session_id] = user_id
        return session_id
    
    def _validate_auth(self) -> Optional[int]:
        """Validate authentication and return user_id if valid."""
        session_id = self._get_cookie_value('session_id')
        if not session_id or session_id not in _shared_sessions:
            return None
        return _shared_sessions[session_id]
    
    def _send_response(
            self,
            status: int,
            data: Optional[Dict[str, Any]] = None,
            content_type: str = 'application/json'
    ) -> None:
        """Send an HTTP response with the given data."""
        self.send_response(status)
        if content_type:
            self.send_header('Content-Type', content_type)
        self.end_headers()
        if data is not None:
            json_bytes = json.dumps(data).encode('utf-8')
            self.wfile.write(json_bytes)
    
    def _validate_and_get_body(self) -> Optional[Dict[str, Any]]:
        """Parse and validate request body JSON."""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        raw_data = self.rfile.read(content_length)
        try:
            result: Dict[str, Any] = json.loads(raw_data.decode('utf-8'))
            return result
        except json.JSONDecodeError:
            return None  # Return None on decode error
    
    def _get_current_timestamp(self) -> str:
        """Return current timestamp in ISO 8601 format."""
        # Updated version to remove deprecation warning
        return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    
    def do_POST(self) -> None:  # pylint: disable=invalid-name
        """Handle POST requests."""
        if self.path == '/register':
            self._handle_register()
        elif self.path == '/login':
            self._handle_login()
        elif self.path == '/logout':
            self._handle_logout()
        elif self.path == '/password':
            self._handle_password_change()
        elif self.path == '/todos':
            self._handle_create_todo()
        else:
            self._send_error(404, 'Endpoint not found')
    
    def do_GET(self) -> None:  # pylint: disable=invalid-name
        """Handle GET requests."""
        if self.path == '/me':
            self._handle_get_me()
        elif self.path.startswith('/todos/'):
            self._handle_get_todo()
        elif self.path == '/todos':
            self._handle_list_todos()
        else:
            self._send_error(404, 'Endpoint not found')
    
    def do_PUT(self) -> None:  # pylint: disable=invalid-name
        """Handle PUT requests."""
        if self.path == '/password':
            self._handle_password_change()
        elif self.path.startswith('/todos/'):
            self._handle_update_todo()
        else:
            self._send_error(404, 'Endpoint not found')
    
    def do_DELETE(self) -> None:  # pylint: disable=invalid-name
        """Handle DELETE requests."""
        if self.path.startswith('/todos/'):
            self._handle_delete_todo()
        else:
            self._send_error(404, 'Endpoint not found')
    
    def _handle_register(self) -> None:
        """Handle user registration."""
        body = self._validate_and_get_body()
        if body is None:
            self._send_error(400, 'Invalid JSON')
            return
        
        global _next_user_id  # Declare global here to satisfy mypy
        
        username = body.get('username')
        password = body.get('password')
        
        # Validate username
        if not isinstance(username, str):
            self._send_error(400, 'Invalid username')
            return
        if len(username) < 3 or len(username) > 50 or not re.match(r'^[a-zA-Z0-9_]+$', username):
            self._send_error(400, 'Invalid username')
            return
        
        # Validate password
        if not isinstance(password, str) or len(password) < 8:
            self._send_error(400, 'Password too short')
            return
        
        # Check if username already exists
        with _state_lock:
            if any(user.username == username for user in _shared_users.values()):
                self._send_response(409, {'error': 'Username already exists'})
                return
        
            # Create new user
            user_id = _next_user_id
            _next_user_id += 1
            user = User(user_id, username, password)  # In a real app, hash the password
            _shared_users[user_id] = user
        
        self._send_response(201, {
            'id': user.id,
            'username': user.username
        })
    
    def _handle_login(self) -> None:
        """Handle user login."""
        body = self._validate_and_get_body()
        if body is None:
            self._send_error(400, 'Invalid JSON')
            return
        
        username = body.get('username')
        password = body.get('password')
        
        # Find user by username
        user = None
        with _state_lock:
            for u in _shared_users.values():
                if u.username == username:
                    user = u
                    break
        
        if user is None or user.password_hash != password:
            self._send_response(401, {'error': 'Invalid credentials'})
            return
        
        # Create session
        with _state_lock:
            session_id = self._set_session(user.id)
        
        # Send response with Set-Cookie header
        response_body = {
            'id': user.id,
            'username': user.username
        }
        
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')
        self.end_headers()
        
        json_bytes = json.dumps(response_body).encode('utf-8')
        self.wfile.write(json_bytes)
    
    def _handle_logout(self) -> None:
        """Handle user logout."""
        user_id = self._validate_auth()
        if user_id is None:
            self._send_error(401, 'Authentication required')
            return
        
        # Remove session
        session_id = self._get_cookie_value('session_id')
        if session_id:
            with _state_lock:
                if session_id in _shared_sessions:
                    del _shared_sessions[session_id]
        
        # Respond with empty object
        self._send_response(200, {})
    
    def _handle_get_me(self) -> None:
        """Handle fetching authenticated user details."""
        user_id = self._validate_auth()
        if user_id is None:
            self._send_error(401, 'Authentication required')
            return
        
        with _state_lock:
            user = _shared_users.get(user_id)
        if not user:
            self._send_error(401, 'Authentication required')  # Shouldn't happen theoretically
            return
        
        response = {
            'id': user.id,
            'username': user.username
        }
        self._send_response(200, response)
    
    def _handle_password_change(self) -> None:
        """Handle password change."""
        user_id = self._validate_auth()
        if user_id is None:
            self._send_error(401, 'Authentication required')
            return
        
        with _state_lock:
            user = _shared_users.get(user_id)
        if not user:
            self._send_error(401, 'Authentication required')
            return
        
        body = self._validate_and_get_body()
        if body is None:
            self._send_error(400, 'Invalid JSON')
            return
        
        old_password = body.get('old_password')
        new_password = body.get('new_password')
        
        # Verify old password
        if old_password != user.password_hash:
            self._send_response(401, {'error': 'Invalid credentials'})
            return
        
        # Validate new password length
        if not isinstance(new_password, str) or len(new_password) < 8:
            self._send_error(400, 'Password too short')
            return
        
        # Update password
        with _state_lock:
            user.password_hash = new_password
        self._send_response(200, {})
    
    def _handle_list_todos(self) -> None:
        """Handle listing todos for the authenticated user."""
        user_id = self._validate_auth()
        if user_id is None:
            self._send_error(401, 'Authentication required')
            return
        
        # Filter todos belonging to this user
        user_todos: List[Dict[str, Any]] = []
        with _state_lock:
            for todo_ref in _shared_todos.values():
                owner_id, todo = todo_ref
                if owner_id == user_id:
                    user_todos.append({
                        'id': todo.id,
                        'title': todo.title,
                        'description': todo.description,
                        'completed': todo.completed,
                        'created_at': todo.created_at,
                        'updated_at': todo.updated_at
                    })
        
        # Sort by id in ascending order
        user_todos.sort(key=lambda td: td['id'])
        
        # Send the todo list directly without passing through _send_response
        # because our type annotation doesn't support lists
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        json_bytes = json.dumps(user_todos).encode('utf-8')
        self.wfile.write(json_bytes)
    
    def _handle_create_todo(self) -> None:
        """Handle creating a new todo."""
        global _next_todo_id  # Declare global here to satisfy mypy
        
        user_id = self._validate_auth()
        if user_id is None:
            self._send_error(401, 'Authentication required')
            return
        
        body = self._validate_and_get_body()
        if body is None:
            self._send_error(400, 'Invalid JSON')
            return
        
        title = body.get('title')
        description = body.get('description', '')
        
        if not isinstance(title, str) or len(title) == 0:
            self._send_error(400, 'Title is required')
            return
        
        if not isinstance(description, str):
            self._send_error(400, 'Description must be a string')
            return
        
        # Create new todo
        now = self._get_current_timestamp()
        with _state_lock:
            todo_id = _next_todo_id
            _next_todo_id += 1
            todo = Todo(
                todo_id=todo_id,
                title=title,
                description=description,
                completed=False,
                created_at=now,
                updated_at=now
            )
            
            _shared_todos[todo_id] = (user_id, todo)
        
        response = {
            'id': todo.id,
            'title': todo.title,
            'description': todo.description,
            'completed': todo.completed,
            'created_at': todo.created_at,
            'updated_at': todo.updated_at
        }
        
        self._send_response(201, response)
    
    def _handle_get_todo(self) -> None:
        """Handle getting a specific todo."""
        user_id = self._validate_auth()
        if user_id is None:
            self._send_error(401, 'Authentication required')
            return
        
        # Extract todo ID from path
        path_parts = self.path.split('/')
        if len(path_parts) != 3 or path_parts[1] != 'todos':
            self._send_error(404, 'Todo not found')
            return
        
        todo_id_str = path_parts[2]
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self._send_error(404, 'Todo not found')
            return
        
        # Get todo
        with _state_lock:
            if todo_id not in _shared_todos:
                self._send_error(404, 'Todo not found')
                return
            
            owner_id, todo = _shared_todos[todo_id]
            if owner_id != user_id:
                self._send_error(404, 'Todo not found')
                return
        
        response = {
            'id': todo.id,
            'title': todo.title,
            'description': todo.description,
            'completed': todo.completed,
            'created_at': todo.created_at,
            'updated_at': todo.updated_at
        }
        
        self._send_response(200, response)
    
    def _handle_update_todo(self) -> None:
        """Handle updating a specific todo."""
        user_id = self._validate_auth()
        if user_id is None:
            self._send_error(401, 'Authentication required')
            return
        
        # Extract todo ID from path - correct split
        path_parts = self.path.split('/')
        if len(path_parts) != 3 or path_parts[1] != 'todos':
            self._send_error(404, 'Todo not found')
            return
        
        todo_id_str = path_parts[2]
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self._send_error(404, 'Todo not found')
            return
        
        # Get todo
        with _state_lock:
            if todo_id not in _shared_todos:
                self._send_error(404, 'Todo not found')
                return
            
            owner_id, original_todo = _shared_todos[todo_id]
            if owner_id != user_id:
                self._send_error(404, 'Todo not found')
                return
        
        body = self._validate_and_get_body()
        if body is None:
            self._send_error(400, 'Invalid JSON')
            return
        
        # Use values from the request or keep existing values
        updated_title = original_todo.title 
        if 'title' in body:
            title = body['title']
            if not isinstance(title, str) or len(title) == 0:
                self._send_error(400, 'Title is required')
                return
            updated_title = title
        
        updated_description = original_todo.description
        if 'description' in body:
            description = body['description']
            if not isinstance(description, str):
                self._send_error(400, 'Description must be a string')
                return
            updated_description = description
            
        updated_completed = original_todo.completed
        if 'completed' in body:
            completed = body['completed']
            if not isinstance(completed, bool):
                self._send_error(400, 'Completed must be a boolean')
                return
            updated_completed = completed
        
        # Create updated todo
        updated_todo = Todo(
            todo_id=original_todo.id,
            title=updated_title,
            description=updated_description,
            completed=updated_completed,
            created_at=original_todo.created_at,
            updated_at=self._get_current_timestamp()
        )
        
        with _state_lock:
            _shared_todos[todo_id] = (owner_id, updated_todo)
        
        response = {
            'id': updated_todo.id,
            'title': updated_todo.title,
            'description': updated_todo.description,
            'completed': updated_todo.completed,
            'created_at': updated_todo.created_at,
            'updated_at': updated_todo.updated_at
        }
        
        self._send_response(200, response)
    
    def _handle_delete_todo(self) -> None:
        """Handle deleting a specific todo."""
        user_id = self._validate_auth()
        if user_id is None:
            self._send_error(401, 'Authentication required')
            return
        
        # Extract todo ID from path
        path_parts = self.path.split('/')
        if len(path_parts) != 3 or path_parts[1] != 'todos':
            self._send_error(404, 'Todo not found')
            return
        
        todo_id_str = path_parts[2]
        try:
            todo_id = int(todo_id_str)
        except ValueError:
            self._send_error(404, 'Todo not found')
            return
        
        # Get todo  
        with _state_lock:
            if todo_id not in _shared_todos:
                self._send_error(404, 'Todo not found')
                return
            
            owner_id, todo = _shared_todos[todo_id]
            if owner_id != user_id:
                self._send_error(404, 'Todo not found')
                return
        
            # Delete todo
            del _shared_todos[todo_id]
        
        self.send_response(204)
        self.end_headers()
    
    def _send_error(self, status: int, message: str) -> None:
        """Send an error response."""
        self._send_response(status, {'error': message})


def main() -> None:
    """Main server entry point."""
    parser = argparse.ArgumentParser(description='Todo App REST API Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to listen on')
    args = parser.parse_args()
    
    # Clear state at startup (not typical, but for testing purposes we might want this)
    global _shared_users, _shared_todos, _shared_sessions, _next_user_id, _next_todo_id
    _shared_users.clear()
    _shared_todos.clear()
    _shared_sessions.clear()
    _next_user_id = 1
    _next_todo_id = 1
    
    server = ('0.0.0.0', args.port)
    httpd = HTTPServer(server, TodoAppServer)
    
    print(f'Starting Todo App server on {server[0]}:{server[1]}')
    httpd.serve_forever()


if __name__ == '__main__':
    main()