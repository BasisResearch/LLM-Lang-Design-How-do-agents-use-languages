#!/usr/bin/env python3
"""
Todo REST API Server with Cookie-based Authentication
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import TCPServer
from urllib.parse import urlparse, parse_qs
import json
import uuid
import hashlib
import re
from datetime import datetime
from typing import Dict, List, Optional, Any, Union


def get_current_timestamp() -> str:
    """Get current time in ISO 8601 format: YYYY-MM-DDTHH:MM:SSZ"""
    return datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')


# Global store to maintain state between requests in the same server instance
# Using a custom server class that maintains the state across all request handlers
class StatefulHTTPServer(TCPServer):
    """
    A custom HTTPServer that maintains persistent state between requests
    """
    def __init__(self, server_address: tuple[str, int], RequestHandlerClass: type) -> None:
        super().__init__(server_address, RequestHandlerClass)
        self.users: Dict[int, Dict[str, Any]] = {}
        self.todos: Dict[int, Dict[str, Any]] = {}
        self.user_id_counter = 1
        self.todo_id_counter = 1 
        self.sessions: Dict[str, int] = {}  # session_id -> user_id
        self.passwords: Dict[int, str] = {}  # user_id -> hashed password


class TodoServer(BaseHTTPRequestHandler):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        # We can now access the server's attributes via self.server, but need proper typing
        super().__init__(*args, **kwargs)
    
    @property
    def server_state(self) -> StatefulHTTPServer:
        # Type assertion to ensure we're working with our StatefulHTTPServer
        return self.server  # type: ignore[return-value]
    
    @property
    def users(self) -> Dict[int, Dict[str, Any]]:
        return self.server_state.users
    
    @property
    def todos(self) -> Dict[int, Dict[str, Any]]:
        return self.server_state.todos
    
    @property
    def user_id_counter(self) -> int:
        return self.server_state.user_id_counter
    
    @user_id_counter.setter 
    def user_id_counter(self, value: int) -> None:
        self.server_state.user_id_counter = value
    
    @property
    def todo_id_counter(self) -> int:
        return self.server_state.todo_id_counter
    
    @todo_id_counter.setter 
    def todo_id_counter(self, value: int) -> None:
        self.server_state.todo_id_counter = value
    
    @property
    def sessions(self) -> Dict[str, int]:
        return self.server_state.sessions
    
    @property
    def passwords(self) -> Dict[int, str]:
        return self.server_state.passwords
    
    def _send_response(self, status_code: int, data: Any = None) -> None:
        """Send JSON response with appropriate headers."""
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        
        if data is not None:
            self.wfile.write(json.dumps(data).encode())
            
    def send_204_response(self) -> None:
        """Send 204 No Content response."""
        self.send_response(204)
        self.end_headers()
    
    def send_error_response(self, status_code: int, message: str) -> None:
        """Send an error response with the given status and message."""
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({"error": message}).encode())
        
    def validate_username(self, username: str) -> bool:
        """Validate username: 3-50 chars, alphanumeric and underscore only."""
        return 3 <= len(username) <= 50 and re.match(r'^[a-zA-Z0-9_]+$', username) is not None
        
    def get_request_body(self) -> Dict[str, Any]:
        """Get JSON body from the request."""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        raw_body = self.rfile.read(content_length)
        try:
            # Explicitly cast result to Any then return - mypy gets confused by json.loads return type
            parsed: Any = json.loads(raw_body.decode())
            # Verify it's a dict
            if isinstance(parsed, dict):
                return parsed
            else:
                return {}  # Fallback if not a dict
        except json.JSONDecodeError:
            return {}

    def set_session_cookie(self, session_id: str) -> None:
        """Set session cookie in response headers."""
        self.send_header('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')

    def authenticate_user(self, username: str, password: str) -> Optional[Dict[str, Any]]:
        """authenticate user and generate session"""
        # Find user by username
        matching_user = None
        for user_id, user in self.users.items():
            if user['username'] == username:
                matching_user = user
                break
                
        if not matching_user:
            return None
            
        user_id = matching_user['id']
        if user_id in self.passwords and self.verify_password(password, self.passwords[user_id]):
            return matching_user
        else:
            return None  # Explicitly return None if authentication fails
    
    def do_POST(self) -> None:
        """Handle POST requests for various endpoints"""
        path_parts = urlparse(self.path).path.split('/')
        
        if self.path == '/register':
            self.handle_register()
        elif self.path == '/login':
            self.handle_login()
        elif self.path == '/logout':
            self.handle_logout()
        elif self.path == '/todos':
            user = self.get_user_from_session()
            if user:
                self.handle_create_todo(user)
            else:
                self.send_error_response(401, "Authentication required")
        elif self.path.startswith('/password'):
            user = self.get_user_from_session()
            if user:
                self.handle_change_password(user)
            else:
                self.send_error_response(401, "Authentication required")
        else:
            self.send_error_404()
            
    def handle_register(self) -> None:
        """Handle user registration"""
        try:
            body = self.get_request_body()
            username = body.get('username', '').strip()
            password = body.get('password', '').strip()
            
            # Validate username
            if not username or not self.validate_username(username):
                self.send_error_response(400, "Invalid username")
                return
                
            # Validate password
            if not password or len(password) < 8:
                self.send_error_response(400, "Password too short")
                return
            
            # Check if username already exists
            for user in self.users.values():
                if user['username'] == username:
                    self.send_error_response(409, "Username already exists")
                    return
            
            # Create user
            user_id = self.user_id_counter
            self.user_id_counter += 1  # Increment counter
            
            new_user = {
                "id": user_id,
                "username": username
            }
            
            self.users[user_id] = new_user
            self.passwords[user_id] = self.hash_password(password)
            
            self._send_response(201, new_user)
            
        except Exception:
            self.send_error_response(400, "Invalid request data")
            
    def handle_login(self) -> None:
        """Handle user login"""
        try:
            body = self.get_request_body()
            username = body.get('username', '').strip()
            password = body.get('password', '').strip()
            
            user = self.authenticate_user(username, password)
            
            if not user:
                self.send_error_response(401, "Invalid credentials")
                return
            
            # Generate session
            session_id = str(uuid.uuid4())
            self.sessions[session_id] = user['id']
            
            # Send response with set cookie
            self.send_response(200)
            self.set_session_cookie(session_id)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            
            self.wfile.write(json.dumps(user).encode())
            
        except Exception:
            self.send_error_response(400, "Invalid request data")
                
    def handle_logout(self) -> None:
        """Handle user logout"""
        cookie_header = self.headers.get('Cookie', '')
        cookies = self._parse_cookies(cookie_header)
        
        session_id = cookies.get('session_id')
        
        if session_id and session_id in self.sessions:
            del self.sessions[session_id]
        
        self._send_response(200, {})
        
    def handle_change_password(self, user: Dict[str, Any]) -> None:
        """Handle changing password for current user"""
        try:
            body = self.get_request_body()
            old_password = str(body.get('old_password', ''))
            new_password = str(body.get('new_password', '')).strip()
            
            user_id = user['id']
            
            # Verify old password
            if user_id not in self.passwords or not self.verify_password(old_password, self.passwords[user_id]):
                self.send_error_response(401, "Invalid credentials")
                return
                
            # Validate new password
            if len(new_password) < 8:
                self.send_error_response(400, "Password too short")
                return
                
            # Update password
            self.passwords[user_id] = self.hash_password(new_password)
            self._send_response(200, {})
            
        except Exception:
            self.send_error_response(400, "Invalid request data")

    def handle_create_todo(self, user: Dict[str, Any]) -> None:
        """Create a new todo item"""
        try:
            body = self.get_request_body()
            title = body.get('title', '').strip()
            description = str(body.get('description', '')).strip()
            
            if not title:
                self.send_error_response(400, "Title is required")
                return
                
            # Create todo
            todo_id = self.todo_id_counter
            self.todo_id_counter += 1  # Increment counter
            
            created_at = get_current_timestamp()
            
            new_todo = {
                "id": todo_id,
                "title": title,
                "description": description,
                "completed": False,
                "user_id": user['id'],
                "created_at": created_at,
                "updated_at": created_at
            }
            
            self.todos[todo_id] = new_todo
            
            self._send_response(201, new_todo)
            
        except Exception:
            self.send_error_response(400, "Invalid request data")
    
    def do_GET(self) -> None:
        """Handle GET requests"""
        path_parts = urlparse(self.path).path.split('/')
        
        if self.path == '/me':
            user = self.get_user_from_session()
            if user:
                self._send_response(200, user)
            else:
                self.send_error_response(401, "Authentication required")
        elif self.path == '/todos':
            user = self.get_user_from_session()
            if user:
                self.handle_get_todos(user)
            else:
                self.send_error_response(401, "Authentication required")
        elif len(path_parts) == 3 and path_parts[1] == 'todos':
            # Match /todos/{id}
            try:
                todo_id = int(path_parts[2])
                user = self.get_user_from_session()
                if user:
                    self.handle_get_todo_by_id(todo_id, user)
                else:
                    self.send_error_response(401, "Authentication required")
            except ValueError:
                self.send_error_404()
        else:
            self.send_error_404()
    
    def get_user_from_session(self) -> Optional[Dict[str, Any]]:
        """Extract user from session cookie if valid"""
        cookie_header = self.headers.get('Cookie', '')
        cookies = self._parse_cookies(cookie_header)
        
        session_id = cookies.get('session_id')
        if session_id and session_id in self.sessions:
            user_id = self.sessions[session_id]
            if user_id in self.users:
                return self.users[user_id]
        return None
    
    def handle_get_todos(self, user: Dict[str, Any]) -> None:
        """Get all todos for the current user"""
        user_todos = [
            {k: v for k, v in todo.items() if k != 'user_id'}
            for todo in self.todos.values()
            if todo['user_id'] == user['id']
        ]
        
        # Sort by id ascending
        user_todos.sort(key=lambda x: x['id'])
        
        self._send_response(200, user_todos)
    
    def handle_get_todo_by_id(self, todo_id: int, user: Dict[str, Any]) -> None:
        """Get a specific todo by ID"""
        if todo_id in self.todos and self.todos[todo_id]['user_id'] == user['id']:
            todo = {k: v for k, v in self.todos[todo_id].items() if k != 'user_id'}
            self._send_response(200, todo)
        else:
            self.send_error_response(404, "Todo not found")
    
    def do_PUT(self) -> None:
        """Handle PUT requests"""
        path_parts = urlparse(self.path).path.split('/')
        
        if self.path.startswith('/password'):
            user = self.get_user_from_session()
            if user:
                self.handle_change_password(user)
            else:
                self.send_error_response(401, "Authentication required")
        elif len(path_parts) == 3 and path_parts[1] == 'todos':
            # Match /todos/{id}
            try:
                todo_id = int(path_parts[2])
                user = self.get_user_from_session()
                if user:
                    self.handle_update_todo(todo_id, user)
                else:
                    self.send_error_response(401, "Authentication required")
            except ValueError:
                self.send_error_404()
        else:
            self.send_error_404()
    
    def handle_update_todo(self, todo_id: int, user: Dict[str, Any]) -> None:
        """Update a specific todo (partial update)"""
        if todo_id not in self.todos or self.todos[todo_id]['user_id'] != user['id']:
            self.send_error_response(404, "Todo not found")
            return
        
        try:
            body = self.get_request_body()
            
            # Get current todo
            todo = self.todos[todo_id]
            
            # Validate title if provided
            if 'title' in body:
                title = str(body['title']).strip()
                if not title:
                    self.send_error_response(400, "Title is required")
                    return
                todo['title'] = title
            
            # Update other fields if provided
            if 'description' in body:
                todo['description'] = str(body['description'])
                
            if 'completed' in body:
                todo['completed'] = bool(body['completed'])
                
            # Update timestamp
            todo['updated_at'] = get_current_timestamp()
            
            # Remove user_id from response
            response_todo = {k: v for k, v in todo.items() if k != 'user_id'}
            
            self._send_response(200, response_todo)
            
        except Exception:
            self.send_error_response(400, "Invalid request data")

    def do_DELETE(self) -> None:
        """Handle DELETE requests"""
        path_parts = urlparse(self.path).path.split('/')
        
        if len(path_parts) == 3 and path_parts[1] == 'todos':
            # Match /todos/{id}
            try:
                todo_id = int(path_parts[2])
                user = self.get_user_from_session()
                if user:
                    self.handle_delete_todo(todo_id, user)
                else:
                    self.send_error_response(401, "Authentication required")
            except ValueError:
                self.send_error_404()
        else:
            self.send_error_404()
    
    def handle_delete_todo(self, todo_id: int, user: Dict[str, Any]) -> None:
        """Delete a specific todo"""
        if todo_id not in self.todos or self.todos[todo_id]['user_id'] != user['id']:
            self.send_error_response(404, "Todo not found")
            return
        
        del self.todos[todo_id]
        self.send_204_response()

    def _parse_cookies(self, cookie_str: str) -> Dict[str, str]:
        """Parse cookie string into dictionary of key-value pairs."""
        cookies: Dict[str, str] = {}
        if not cookie_str:
            return cookies
        for item in cookie_str.split(';'):
            item = item.strip()
            if '=' in item:
                key, value = item.split('=', 1)
                cookies[key] = value
        return cookies

    def hash_password(self, pwd: str) -> str:
        """Simple password hashing"""
        return hashlib.sha256(pwd.encode()).hexdigest()

    def verify_password(self, provided: str, actual_hashed: str) -> bool:
        """Verify provided password against stored hash"""
        return self.hash_password(provided) == actual_hashed

    def send_error_404(self) -> None:
        """Send 404 response"""
        self.send_response(404)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({"error": "Not found"}).encode())


if __name__ == '__main__':
    import sys
    import argparse
    
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8000)
    args = parser.parse_args()
    
    server = StatefulHTTPServer(('0.0.0.0', args.port), TodoServer)
    print(f"Starting server on 0.0.0.0:{args.port}")
    server.serve_forever()