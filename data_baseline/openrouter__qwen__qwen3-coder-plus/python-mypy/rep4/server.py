#!/usr/bin/env python3
"""
REST API server for managing personal todo items with cookie-based authentication.
"""

import argparse
import json
import re
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Union
from http.server import HTTPServer, BaseHTTPRequestHandler


class TodoAppServer:
    """Main server class for the Todo application."""
    
    def __init__(self) -> None:
        self.users: Dict[int, Dict[str, Any]] = {}
        self.sessions: Dict[str, int] = {}  # session_id -> user_id
        self.todos: Dict[int, Dict[str, Any]] = {}
        self.next_user_id: int = 1
        self.next_todo_id: int = 1
        self.password_hashes: Dict[int, str] = {}  # user_id -> hashed password
    
    def validate_username(self, username: str) -> bool:
        """Validate username format (3-50 chars, alphanumeric/underscore only)."""
        return 3 <= len(username) <= 50 and bool(re.match(r'^[a-zA-Z0-9_]+$', username))
    
    def get_current_timestamp(self) -> str:
        """Generate current timestamp in ISO 8601 UTC format."""
        return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    
    def hash_password(self, password: str) -> str:
        """Simple password hashing (in real app, use bcrypt or similar)."""
        return f"hash_{password}"  # Simplified for demo purposes
    
    def register_user(self, username: str, password: str) -> Optional[Dict[str, Any]]:
        """Register a new user."""
        if not self.validate_username(username):
            return None
        
        if len(password) < 8:
            return None
            
        # Check if username already exists  
        for user in self.users.values():
            if user['username'] == username:
                return None
        
        user_id = self.next_user_id
        self.next_user_id += 1
        
        new_user = {
            'id': user_id,
            'username': username,
        }
        
        self.users[user_id] = new_user
        self.password_hashes[user_id] = self.hash_password(password)
        
        return new_user
    
    def authenticate_user(self, username: str, password: str) -> Optional[Dict[str, Any]]:
        """Authenticate a user."""
        for user in self.users.values():
            if user['username'] == username:
                hashed_password = self.hash_password(password)
                if self.password_hashes[user['id']] == hashed_password:
                    return user
                else:
                    return None
        
        return None
    
    def create_session(self, user_id: int) -> str:
        """Create a new session for a user."""
        session_id = str(uuid.uuid4())
        self.sessions[session_id] = user_id
        return session_id
    
    def get_user_from_session(self, session_id: str) -> Optional[Dict[str, Any]]:
        """Retrieve user by session ID."""
        user_id = self.sessions.get(session_id)
        if user_id is not None:
            return self.users.get(user_id)
        return None
    
    def logout_session(self, session_id: str) -> bool:
        """Remove a session."""
        if session_id in self.sessions:
            del self.sessions[session_id]
            return True
        return False
    
    def create_todo(self, user_id: int, title: str, description: str) -> Dict[str, Any]:
        """Create a new todo item."""
        todo_id = self.next_todo_id
        self.next_todo_id += 1
        
        created_at = self.get_current_timestamp()
        updated_at = created_at
        
        new_todo = {
            'id': todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'user_id': user_id,
            'created_at': created_at,
            'updated_at': updated_at
        }
        
        self.todos[todo_id] = new_todo
        return new_todo
    
    def get_user_todos(self, user_id: int) -> List[Dict[str, Any]]:
        """Get all todos for a user."""
        user_todos = []
        for todo in self.todos.values():
            if todo['user_id'] == user_id:
                # Remove user_id from the response to satisfy spec
                todo_response = {k: v for k, v in todo.items() if k != 'user_id'}
                user_todos.append(todo_response)
        
        # Sort by id in ascending order
        user_todos.sort(key=lambda x: x['id'])
        return user_todos
    
    def get_todo(self, user_id: int, todo_id: int) -> Optional[Dict[str, Any]]:
        """Get a specific todo by id."""
        todo = self.todos.get(todo_id)
        if todo and todo['user_id'] == user_id:
            # Remove user_id from response for API
            todo_response = {k: v for k, v in todo.items() if k != 'user_id'}
            return todo_response
        return None
    
    def update_todo(self, user_id: int, todo_id: int, updates: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Update a specific todo."""
        todo = self.todos.get(todo_id)
        if not todo or todo['user_id'] != user_id:
            return None
        
        # Validate title if provided
        if 'title' in updates and not updates['title']:
            return None
        
        # Apply updates
        for field, value in updates.items():
            if field in todo and field in ['title', 'description', 'completed']:
                todo[field] = value
        
        # Updated timestamp
        todo['updated_at'] = self.get_current_timestamp()
        
        # Return the updated todo without user_id
        todo_response = {k: v for k, v in todo.items() if k != 'user_id'}
        return todo_response
    
    def delete_todo(self, user_id: int, todo_id: int) -> bool:
        """Delete a specific todo."""
        todo = self.todos.get(todo_id)
        if todo and todo['user_id'] == user_id:
            del self.todos[todo_id]
            return True
        return False
    
    def update_password(self, user_id: int, old_password: str, new_password: str) -> bool:
        """Update user's password."""
        if len(new_password) < 8:
            return False
        
        # Verify old password
        hashed_old = self.hash_password(old_password)
        if self.password_hashes[user_id] != hashed_old:
            return False
        
        # Update password
        self.password_hashes[user_id] = self.hash_password(new_password)
        return True


class RequestHandler(BaseHTTPRequestHandler):
    """HTTP request handler for the TodoApp server."""
    
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self.server_instance: TodoAppServer = kwargs.pop('server_instance')
        super().__init__(*args, **kwargs)
    
    def _parse_cookies(self) -> Dict[str, str]:
        """Parse cookies from the request headers."""
        cookies: Dict[str, str] = {}
        cookie_header: Optional[str] = self.headers.get('Cookie')  # Specify type explicitly
        if cookie_header:
            for cookie in cookie_header.split(';'):
                cookie = cookie.strip()
                if cookie and '=' in cookie:
                    parts = cookie.split('=', 1)
                    if len(parts) == 2:
                        name, value = parts[0], parts[1]  # Explicit tuple unpacking
                        cookies[name] = value
                    else:
                        # Only key exists (no value after equals)
                        name = parts[0]
                        cookies[name] = ""
        return cookies
    
    def _get_session_id(self) -> Optional[str]:
        """Get the session ID from cookies."""
        cookies = self._parse_cookies()
        return cookies.get('session_id')
    
    def _send_json(self, 
                   data: Union[Dict[str, Any], List[Dict[str, Any]]], 
                   status_code: int = 200, 
                   set_cookie: Optional[str] = None) -> None:
        """Send JSON response."""
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        if set_cookie:
            self.send_header('Set-Cookie', set_cookie)
        self.end_headers()
        if data:  # Don't send body for DELETE responses
            response_body = json.dumps(data, ensure_ascii=False).encode('utf-8')
            self.wfile.write(response_body)
    
    def _handle_error(self, message: str, status: int = 400) -> None:
        """Send error response."""
        self._send_json({'error': message}, status)
    
    def _get_request_data(self) -> Dict[str, Any]:
        """Extract request body as JSON."""
        content_length_str: Optional[str] = self.headers.get('Content-Length')
        content_length = int(content_length_str) if content_length_str else 0
        body = self.rfile.read(content_length).decode('utf-8')
        return json.loads(body) if body else {}
    
    def _auth_required(self) -> Optional[Dict[str, Any]]:
        """Check if authentication is required and return authenticated user."""
        session_id = self._get_session_id()
        if not session_id:
            self._handle_error("Authentication required", 401)
            return None
        
        user = self.server_instance.get_user_from_session(session_id)
        if not user:
            self._handle_error("Authentication required", 401)
            return None
        
        return user
    
    def do_POST(self) -> None:
        """Handle POST requests."""
        if self.path == '/register':
            try:
                data = self._get_request_data()
                
                if 'username' not in data or 'password' not in data:
                    self._handle_error("Username and password required", 400)
                    return
                
                username = data['username']
                password = data['password']
                
                # Validate input
                if not self.server_instance.validate_username(username):
                    self._handle_error("Invalid username", 400)
                    return
                    
                if len(password) < 8:
                    self._handle_error("Password too short", 400)
                    return
                
                # Try to register user
                user = self.server_instance.register_user(username, password)
                if not user:
                    # Check if username exists to decide error message
                    for u in self.server_instance.users.values():
                        if u['username'] == username:
                            self._handle_error("Username already exists", 409)
                            return
                    # Generic message if validation failed for reasons other than uniqueness
                    self._handle_error("Registration failed", 400)
                    return
                
                self._send_json(user, 201)
                
            except json.JSONDecodeError:
                self._handle_error("Invalid JSON in request", 400)
            except Exception:
                self._handle_error("Server error", 500)
                
        elif self.path == '/login':
            try:
                data = self._get_request_data()
                
                if 'username' not in data or 'password' not in data:
                    self._handle_error("Username and password required", 400)
                    return
                
                username = data['username']
                password = data['password']
                
                user = self.server_instance.authenticate_user(username, password)
                if not user:
                    self._handle_error("Invalid credentials", 401)
                    return
                
                session_id = self.server_instance.create_session(user['id'])
                cookie_str = f"session_id={session_id}; Path=/; HttpOnly"
                
                self._send_json(user, 200, cookie_str)
                
            except json.JSONDecodeError:
                self._handle_error("Invalid JSON in request", 400)
            except Exception:
                self._handle_error("Server error", 500)
                
        elif self.path == '/logout':
            try:
                user = self._auth_required()
                if not user:
                    return
                
                session_id = self._get_session_id()
                if session_id:
                    self.server_instance.logout_session(session_id)
                
                self._send_json({})
                
            except Exception:
                self._handle_error("Server error", 500)
                
        elif self.path == '/todos':
            try:
                user = self._auth_required()
                if not user:
                    return
                
                data = self._get_request_data()
                
                if 'title' not in data or not data['title']:
                    self._handle_error("Title is required", 400)
                    return
                
                title = data['title']
                description = data.get('description', "")
                
                todo = self.server_instance.create_todo(user['id'], title, description)
                
                # Remove user_id from response
                todo_response = {k: v for k, v in todo.items() if k != 'user_id'}
                
                self._send_json(todo_response, 201)
                
            except json.JSONDecodeError:
                self._handle_error("Invalid JSON in request", 400)
            except Exception:
                self._handle_error("Server error", 500)
                
        elif self.path == '/password':
            try:
                user = self._auth_required()
                if not user:
                    return
                
                data = self._get_request_data()
                
                if 'old_password' not in data or 'new_password' not in data:
                    self._handle_error("Old and new password required", 400)
                    return
                
                old_password = data['old_password']
                new_password = data['new_password']
                
                # Verify old password
                user_obj = self.server_instance.authenticate_user(user['username'], old_password)
                if not user_obj:
                    self._handle_error("Invalid credentials", 401)
                    return
                
                if len(new_password) < 8:
                    self._handle_error("Password too short", 400)
                    return
                
                success = self.server_instance.update_password(user['id'], old_password, new_password)
                if not success:
                    self._handle_error("Failed to update password", 400)
                    return
                
                self._send_json({})
                
            except json.JSONDecodeError:
                self._handle_error("Invalid JSON in request", 400)
            except Exception:
                self._handle_error("Server error", 500)
        
        else:
            self._handle_error("Not found", 404)
    
    def do_GET(self) -> None:
        """Handle GET requests."""
        if self.path == '/me':
            try:
                user = self._auth_required()
                if not user:
                    return
                
                self._send_json(user)
                
            except Exception:
                self._handle_error("Server error", 500)
        
        elif self.path == '/todos':
            try:
                user = self._auth_required()
                if not user:
                    return
                
                todos = self.server_instance.get_user_todos(user['id'])
                self._send_json(todos)
                
            except Exception:
                self._handle_error("Server error", 500)
                
        elif self.path.startswith('/todos/'):
            try:
                user = self._auth_required()
                if not user:
                    return
                
                # Extract todo id
                todo_id_part = self.path[7:]  # remove '/todos/'
                if not todo_id_part:
                    self._handle_error("Not found", 404)
                    return
                
                try:
                    todo_id = int(todo_id_part)
                except ValueError:
                    self._handle_error("Not found", 404)
                    return
                
                todo = self.server_instance.get_todo(user['id'], todo_id)
                if not todo:
                    self._handle_error("Todo not found", 404)
                    return
                
                self._send_json(todo)
                
            except Exception:
                self._handle_error("Server error", 500)
        
        else:
            self._handle_error("Not found", 404)
    
    def do_PUT(self) -> None:
        """Handle PUT requests."""
        if self.path.startswith('/todos/') and not self.path == '/password':
            try:
                user = self._auth_required()
                if not user:
                    return
                
                # Extract todo id
                todo_id_part = self.path[7:]
                if not todo_id_part:
                    self._handle_error("Not found", 404)
                    return
                
                try:
                    todo_id = int(todo_id_part)
                except ValueError:
                    self._handle_error("Not found", 404)
                    return
                
                data = self._get_request_data()
                
                # Validate title if present and empty
                if 'title' in data and not data['title']:
                    self._handle_error("Title is required", 400)
                    return
                
                updated_todo = self.server_instance.update_todo(user['id'], todo_id, data)
                if not updated_todo:
                    self._handle_error("Todo not found", 404)
                    return
                
                self._send_json(updated_todo)
                
            except json.JSONDecodeError:
                self._handle_error("Invalid JSON in request", 400)
            except Exception:
                self._handle_error("Server error", 500)
        
        elif self.path == '/password':
            # This would be handled in POST, put here for completeness in case specs change
            self._handle_error("Use POST to update password", 405)
        
        else:
            self._handle_error("Not found", 404)
    
    def do_DELETE(self) -> None:
        """Handle DELETE requests."""
        if self.path.startswith('/todos/'):
            try:
                user = self._auth_required()
                if not user:
                    return
                
                # Extract todo id
                todo_id_part = self.path[7:]
                if not todo_id_part:
                    self._handle_error("Not found", 404)
                    return
                
                try:
                    todo_id = int(todo_id_part)
                except ValueError:
                    self._handle_error("Not found", 404)
                    return
                
                if self.server_instance.delete_todo(user['id'], todo_id):
                    # 204 has no body
                    self.send_response(204)
                    self.end_headers()
                else:
                    self._handle_error("Todo not found", 404)
                    
            except Exception:
                self._handle_error("Server error", 500)
        
        else:
            self._handle_error("Not found", 404)
    
    def log_message(self, format: str, *args: Any) -> None:
        """Disable logging messages to stderr."""
        pass


def run_server(port: int) -> None:
    """Run the server on the specified port."""
    server_instance = TodoAppServer()
    
    def handler(*args: Any, **kwargs: Any) -> RequestHandler:
        return RequestHandler(server_instance=server_instance, *args, **kwargs)
    
    server = HTTPServer(('0.0.0.0', port), handler)
    print(f"Server running on http://0.0.0.0:{port}")
    server.serve_forever()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    
    run_server(args.port)