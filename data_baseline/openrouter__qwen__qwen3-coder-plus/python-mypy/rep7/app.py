#!/usr/bin/env python3
"""
REST API Server for managing personal todo items with cookie-based authentication.

This implementation handles user registration, login/logout flows, and CRUD operations
for todos using in-memory storage.
"""

import argparse
import json
import re
import secrets
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Optional, Tuple, Union, cast
from urllib.parse import urlparse, parse_qs


# Type definitions
UserId = int
TodoId = int
SessionId = str
UserDict = Dict[str, Any]
TodoDict = Dict[str, Any]
ResponseBody = Union[Dict[str, Any], List[Dict[str, Any]], None]


class TodoAppServer(BaseHTTPRequestHandler):
    """Main server class handling HTTP requests for the Todo App API."""
    
    # Class attributes for runtime storage
    users: Dict[UserId, UserDict] = {}
    next_user_id: UserId = 1
    todos: Dict[TodoId, TodoDict] = {}
    next_todo_id: TodoId = 1
    sessions: Dict[SessionId, UserId] = {}
    
    @staticmethod
    def _generate_timestamp() -> str:
        """Generate ISO 8601 formatted timestamp with second precision."""
        return datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    
    def _send_response(self, status_code: int, body: ResponseBody = None, 
                      headers: Optional[Dict[str, str]] = None) -> None:
        """
        Send standardized response with JSON content-type.
        
        Args:
            status_code: HTTP status code
            body: JSON response body (optional for DELETE methods)
            headers: Additional headers to send
        """
        self.send_response(status_code)
        
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
        
        # Always include Content-Type unless it's specifically a DELETE response
        if status_code != 204:
            self.send_header('Content-Type', 'application/json')
        self.end_headers()
        
        if body is not None:
            self.wfile.write(json.dumps(body).encode('utf-8'))
    
    def _parse_request_body(self) -> Optional[Dict[str, Any]]:
        """
        Parse JSON request body.
        
        Returns:
            Request body as dictionary, or None if no body
        """
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            body = self.rfile.read(content_length).decode('utf-8')
            try:
                return cast(Dict[str, Any], json.loads(body))
            except json.JSONDecodeError:
                return None
        return None
    
    def _get_session_id(self) -> Optional[SessionId]:
        """
        Extract session ID from cookies in headers.
        
        Returns:
            Session ID if found, None otherwise
        """
        cookie_header = self.headers.get('Cookie', '')
        session_match = re.search(r'session_id=([^;\s]+)', cookie_header)
        return session_match.group(1) if session_match else None
    
    def _is_authenticated(self) -> bool:
        """
        Check if the current request has a valid session.
        
        Returns:
            True if has valid session, False otherwise
        """
        session_id = self._get_session_id()
        if not session_id:
            return False
        
        return session_id in self.sessions
    
    def _get_current_user(self) -> Optional[UserDict]:
        """
        Get currently authenticated user.
        
        Returns:
            User dictionary if authenticated, None otherwise
        """
        session_id = self._get_session_id()
        if not session_id:
            return None
        
        user_id = self.sessions.get(session_id)
        if not user_id:
            return None
        
        return self.users.get(user_id)
    
    def _validate_username(self, username: str) -> Tuple[bool, Optional[str]]:
        """
        Validate username format.
        
        Args:
            username: Username to validate
            
        Returns:
            Tuple of (valid, error_message)
        """
        if not username:
            return False, "Invalid username"
        
        if len(username) < 3 or len(username) > 50:
            return False, "Invalid username"
        
        if not re.match(r'^[a-zA-Z0-9_]+$', username):
            return False, "Invalid username"
        
        return True, None
    
    def do_POST(self) -> None:
        """Handle POST requests for user management and TODO creation."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if len(path_parts) == 1 and path_parts[0] == 'register':
            self._handle_register()
        elif len(path_parts) == 1 and path_parts[0] == 'login':
            self._handle_login()
        elif len(path_parts) == 1 and path_parts[0] == 'logout':
            if self._is_authenticated():
                self._handle_logout()
            else:
                self._handle_auth_required()
        elif len(path_parts) == 1 and path_parts[0] == 'password':
            if self._is_authenticated():
                self._handle_change_password()
            else:
                self._handle_auth_required()
        elif len(path_parts) == 1 and path_parts[0] == 'todos':
            if self._is_authenticated():
                self._handle_create_todo()
            else:
                self._handle_auth_required()
        else:
            self._send_response(404, {"error": "Not Found"})
    
    def do_GET(self) -> None:
        """Handle GET requests for protected resources."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if len(path_parts) == 1 and path_parts[0] == 'me':
            if self._is_authenticated():
                self._handle_get_me()
            else:
                self._handle_auth_required()
        elif len(path_parts) == 1 and path_parts[0] == 'todos':
            if self._is_authenticated():
                self._handle_get_todos()
            else:
                self._handle_auth_required()
        elif len(path_parts) == 2 and path_parts[0] == 'todos':
            try:
                todo_id = int(path_parts[1])
            except ValueError:
                todo_id = -1
            if self._is_authenticated():
                self._handle_get_todo(todo_id)
            else:
                self._handle_auth_required()
        else:
            self._send_response(404, {"error": "Not Found"})
    
    def do_PUT(self) -> None:
        """Handle PUT requests for resource updates."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if len(path_parts) == 1 and path_parts[0] == 'password':
            if self._is_authenticated():
                self._handle_change_password()
            else:
                self._handle_auth_required()
        elif len(path_parts) == 2 and path_parts[0] == 'todos':
            try:
                todo_id = int(path_parts[1])
            except ValueError:
                todo_id = -1
            if self._is_authenticated():
                self._handle_update_todo(todo_id)
            else:
                self._handle_auth_required()
        else:
            self._send_response(404, {"error": "Not Found"})
    
    def do_DELETE(self) -> None:
        """Handle DELETE requests for resource deletion."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if len(path_parts) == 2 and path_parts[0] == 'todos':
            try:
                todo_id = int(path_parts[1])
            except ValueError:
                todo_id = -1
            if self._is_authenticated():
                self._handle_delete_todo(todo_id)
            else:
                self._handle_auth_required()
        else:
            self._send_response(404, {"error": "Not Found"})
    
    # Handler methods
    def _handle_register(self) -> None:
        """Handle user registration."""
        try:
            request_data = self._parse_request_body()
            if not request_data:
                self._send_response(400, {"error": "Invalid request body"})
                return
            
            username_raw = request_data.get('username')
            password_raw = request_data.get('password')
            
            if not isinstance(username_raw, str) or not isinstance(password_raw, str):
                self._send_response(400, {"error": "Invalid request body"})
                return
                
            username = username_raw
            password = password_raw
            
            # Validate username
            is_valid, error_msg = self._validate_username(username)
            if not is_valid:
                self._send_response(400, {"error": error_msg})
                return
            
            # Check if username exists
            for user in self.users.values():
                if user['username'] == username:
                    self._send_response(409, {"error": "Username already exists"})
                    return
            
            # Validate password length
            if not password or len(password) < 8:
                self._send_response(400, {"error": "Password too short"})
                return
            
            # Create user
            user_id = self.next_user_id
            self.next_user_id += 1
            
            user_data: UserDict = {
                'id': user_id,
                'username': username,
                'password': password  # In production, this would be hashed
            }
            
            self.users[user_id] = user_data
            self._send_response(201, {"id": user_id, "username": username})
        except Exception as e:
            print(f"Register error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _handle_login(self) -> None:
        """Handle user login."""
        try:
            request_data = self._parse_request_body()
            if not request_data:
                self._send_response(400, {"error": "Invalid request body"})
                return
            
            username_raw = request_data.get('username')
            password_raw = request_data.get('password')
            
            if not isinstance(username_raw, str) or not isinstance(password_raw, str):
                self._send_response(400, {"error": "Invalid request body"})
                return
                
            username = username_raw
            password = password_raw
            
            user_found = False
            user_data: Optional[UserDict] = None
            
            for uid, user in self.users.items():
                if user['username'] == username and user['password'] == password:
                    user_found = True
                    user_data = user
                    break
            
            if not user_found:
                self._send_response(401, {"error": "Invalid credentials"})
                return
            
            if not user_data:
                self._send_response(500, {"error": "Internal server error"})
                return
            
            # Generate session
            session_id = secrets.token_hex(32)
            self.sessions[session_id] = user_data['id']
            
            headers = {
                'Set-Cookie': f'session_id={session_id}; Path=/; HttpOnly'
            }
            
            self._send_response(200, {"id": user_data['id'], "username": user_data['username']}, headers=headers)
        except Exception as e:
            print(f"Login error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _handle_logout(self) -> None:
        """Handle user logout."""
        try:
            session_id = self._get_session_id()
            if session_id and session_id in self.sessions:
                del self.sessions[session_id]
            
            self._send_response(200, {})
        except Exception as e:
            print(f"Logout error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _handle_get_me(self) -> None:
        """Handle getting current user info."""
        try:
            user = self._get_current_user()
            if not user:
                self._send_response(401, {"error": "Authentication required"})
                return
            
            response_user: Dict[str, Any] = {"id": user['id'], "username": user['username']}
            self._send_response(200, response_user)
        except Exception as e:
            print(f"GetMe error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _handle_change_password(self) -> None:
        """Handle changing user password."""
        try:
            user = self._get_current_user()
            if not user:
                self._send_response(401, {"error": "Authentication required"})
                return
            
            request_data = self._parse_request_body()
            if not request_data:
                self._send_response(400, {"error": "Invalid request body"})
                return
            
            old_password_raw = request_data.get('old_password')
            new_password_raw = request_data.get('new_password')
            
            if not isinstance(old_password_raw, str) or not isinstance(new_password_raw, str):
                self._send_response(400, {"error": "Invalid request body"})
                return
                
            old_password = old_password_raw
            new_password = new_password_raw
            
            # Verify old password
            if user['password'] != old_password:
                self._send_response(401, {"error": "Invalid credentials"})
                return
            
            # Validate new password
            if not new_password or len(new_password) < 8:
                self._send_response(400, {"error": "Password too short"})
                return
            
            # Update password
            user['password'] = new_password
            self._send_response(200, {})
        except Exception as e:
            print(f"Change password error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _handle_get_todos(self) -> None:
        """Handle getting all todos for current user."""
        try:
            user = self._get_current_user()
            if not user:
                self._send_response(401, {"error": "Authentication required"})
                return
            
            user_id = user['id']
            user_todos: List[Dict[str, Any]] = []
            
            # Filter todos for this user and sort by ID
            for todo in sorted(self.todos.values(), key=lambda t: t['id']):
                if todo['user_id'] == user_id:
                    public_todo = todo.copy()
                    del public_todo['user_id']
                    user_todos.append(public_todo)
            
            self._send_response(200, user_todos)
        except Exception as e:
            print(f"GetTodos error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _handle_create_todo(self) -> None:
        """Handle creating a new todo."""
        try:
            user = self._get_current_user()
            if not user:
                self._send_response(401, {"error": "Authentication required"})
                return
            
            request_data = self._parse_request_body()
            if not request_data:
                self._send_response(400, {"error": "Invalid request body"})
                return
            
            # Check for required field 'title'
            if 'title' not in request_data:
                self._send_response(400, {"error": "Title is required"})
                return
            
            title_raw = request_data.get('title')
            description_raw = request_data.get('description', "")
            
            if not isinstance(title_raw, str) or not isinstance(description_raw, str):
                self._send_response(400, {"error": "Invalid request body"})
                return
                
            title = title_raw
            description = description_raw
            
            if not title:
                self._send_response(400, {"error": "Title is required"})
                return
            
            # Generate todo
            todo_id = self.next_todo_id
            self.next_todo_id += 1
            
            timestamp = self._generate_timestamp()
            
            todo_data: TodoDict = {
                'id': todo_id,
                'title': title,
                'description': description,
                'completed': False,
                'created_at': timestamp,
                'updated_at': timestamp,
                'user_id': user['id']
            }
            
            self.todos[todo_id] = todo_data
            
            # Remove user-specific field for public representation
            public_todo = todo_data.copy()
            del public_todo['user_id']
            
            self._send_response(201, public_todo)
        except Exception as e:
            print(f"CreateTodo error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _handle_get_todo(self, todo_id: TodoId) -> None:
        """Handle getting a specific todo."""
        try:
            if todo_id <= 0:
                self._send_response(404, {"error": "Todo not found"})
                return
            
            user = self._get_current_user()
            if not user:
                self._send_response(401, {"error": "Authentication required"})
                return
            
            todo = self.todos.get(todo_id)
            if not todo or todo['user_id'] != user['id']:
                self._send_response(404, {"error": "Todo not found"})
                return
            
            # Prepare public representation (without user_id)
            public_todo = todo.copy()
            del public_todo['user_id']
            
            self._send_response(200, public_todo)
        except Exception as e:
            print(f"GetTodo error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _update_todo_internal(self, todo_id: TodoId, updates: Dict[str, Any]) -> bool:
        """Internal method to update a todo in place."""
        if todo_id not in self.todos:
            return False
        
        todo = self.todos[todo_id]
        
        # Only allow updating of these fields
        allowed_fields = {'title', 'description', 'completed'}
        for key, value in updates.items():
            if key in allowed_fields:
                if key == 'title' and (not isinstance(value, str) or not value):
                    return False  # Title cannot be empty per spec
                todo[key] = value
        
        todo['updated_at'] = self._generate_timestamp()
        return True
    
    def _handle_update_todo(self, todo_id: TodoId) -> None:
        """Handle updating a specific todo."""
        try:
            if todo_id <= 0:
                self._send_response(404, {"error": "Todo not found"})
                return
            
            user = self._get_current_user()
            if not user:
                self._send_response(401, {"error": "Authentication required"})
                return
            
            request_data = self._parse_request_body()
            if not request_data:
                self._send_response(400, {"error": "Invalid request body"})
                return
            
            todo = self.todos.get(todo_id)
            if not todo or todo['user_id'] != user['id']:
                self._send_response(404, {"error": "Todo not found"})
                return
            
            # Validate title if provided
            title_val = request_data.get('title')
            if title_val is not None and (not isinstance(title_val, str) or not title_val):
                self._send_response(400, {"error": "Title is required"})
                return
            
            success = self._update_todo_internal(todo_id, request_data)
            if success:
                # Prepare public representation (without user_id)
                public_todo = self.todos[todo_id].copy()
                del public_todo['user_id']
                
                self._send_response(200, public_todo)
            else:
                self._send_response(400, {"error": "Invalid updates"})
        except Exception as e:
            print(f"UpdateTodo error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _handle_delete_todo(self, todo_id: TodoId) -> None:
        """Handle deleting a specific todo."""
        try:
            if todo_id <= 0:
                self._send_response(404, {"error": "Todo not found"})
                return
            
            user = self._get_current_user()
            if not user:
                self._send_response(401, {"error": "Authentication required"})
                return
            
            todo = self.todos.get(todo_id)
            if not todo or todo['user_id'] != user['id']:
                self._send_response(404, {"error": "Todo not found"})
                return
            
            del self.todos[todo_id]
            self._send_response(204, None)  # No content for delete
        except Exception as e:
            print(f"DeleteTodo error: {e}", file=sys.stderr)
            self._send_response(500, {"error": "Internal server error"})
    
    def _handle_auth_required(self) -> None:
        """Send standard auth required response."""
        self._send_response(401, {"error": "Authentication required"})


def main() -> None:
    """Main entrypoint to start the server."""
    parser = argparse.ArgumentParser(description="Todo App REST API Server")
    parser.add_argument('--port', type=int, default=8000, help='Port to listen on')
    args = parser.parse_args()
    
    server_address = ('0.0.0.0', args.port)
    httpd = HTTPServer(server_address, TodoAppServer)
    
    print(f"Starting server on {server_address[0]}:{server_address[1]}")
    
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        httpd.server_close()


if __name__ == '__main__':
    main()