#!/usr/bin/env python3
"""
REST API server for a Todo app with cookie-based authentication.
Built with strict mypy typing.
"""

import uuid
import json
import re
import hashlib
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import argparse
from typing import Dict, List, Optional, Any, Callable


class User:
    def __init__(self, user_id: int, username: str, password_hash: str):
        self.id = user_id
        self.username = username
        self.password_hash = password_hash  # This will store the hashed password


class Todo:
    def __init__(
        self,
        todo_id: int,
        title: str,
        description: str,
        completed: bool,
        created_at: str,
        updated_at: str,
        user_id: int
    ):
        self.id = todo_id
        self.title = title
        self.description = description
        self.completed = completed
        self.created_at = created_at
        self.updated_at = updated_at
        self.user_id = user_id


def hash_password(password: str) -> str:
    """Hash a password using SHA256."""
    return hashlib.sha256(password.encode()).hexdigest()


def get_iso_timestamp() -> str:
    """Generate ISO 8601 UTC timestamp with second precision."""
    return datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')


class TodoAppServer(BaseHTTPRequestHandler):
    # Class-level storage to persist between requests (in production this would be a DB)
    users: Dict[int, User] = {}
    next_user_id = 1
    
    todos: Dict[int, Todo] = {}
    next_todo_id = 1
    
    # Session storage: maps session_ids to user_id
    active_sessions: Dict[str, int] = {}

    def _set_headers(self, status_code: int = 200, content_type: str = "application/json") -> None:
        """Set response headers."""
        self.send_response(status_code)
        if content_type:
            self.send_header("Content-type", content_type)
        self.end_headers()

    def _get_cookie_value(self, cookie_name: str) -> Optional[str]:
        """Extract a cookie value from the request headers."""
        cookies_str = self.headers.get('Cookie')
        if not cookies_str:
            return None
        
        cookies = {}
        for cookie in cookies_str.split(';'):
            cookie = cookie.strip()
            if '=' in cookie:
                key, value = cookie.split('=', 1)
                cookies[key] = value
        
        return cookies.get(cookie_name)

    def _parse_request_body(self) -> Dict[str, Any]:
        """Parse JSON request body."""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        
        request_body = self.rfile.read(content_length).decode('utf-8')
        try:
            body_data: Dict[str, Any] = json.loads(request_body)
            return body_data
        except json.JSONDecodeError:
            return {}

    def _send_json_response(self, data: Any, status_code: int = 200) -> None:
        """Send JSON response."""
        self._set_headers(status_code)
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def _send_error_response(self, message: str, status_code: int = 400) -> None:
        """Send error response."""
        self._send_json_response({"error": message}, status_code)

    def _authenticate_user(self) -> Optional[User]:
        """Authenticate user based on session cookie."""
        session_id = self._get_cookie_value('session_id')
        if not session_id or session_id not in self.active_sessions:
            return None
        
        user_id = self.active_sessions[session_id]
        return self.users.get(user_id)

    def _require_authentication(self) -> Optional[User]:
        """Check authentication and return user if valid, else send 401."""
        user = self._authenticate_user()
        if not user:
            self._send_error_response("Authentication required", 401)
        return user

    def _register_session(self, user_id: int) -> str:
        """Register a new session for the given user and return the session_id."""
        session_id = str(uuid.uuid4())
        self.active_sessions[session_id] = user_id
        return session_id

    def _invalidate_session(self) -> None:
        """Invalidate the current session."""
        session_id = self._get_cookie_value('session_id')
        if session_id and session_id in self.active_sessions:
            del self.active_sessions[session_id]

    def do_POST(self) -> None:
        """Handle POST requests."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')

        if len(path_parts) == 1 and path_parts[0] == 'register':
            self._handle_register()
        elif len(path_parts) == 1 and path_parts[0] == 'login':
            self._handle_login()
        elif len(path_parts) == 1 and path_parts[0] == 'logout':
            self._handle_logout()
        elif len(path_parts) == 1 and path_parts[0] == 'todos':
            self._handle_create_todo()
        else:
            self._send_error_response("Not Found", 404)

    def do_GET(self) -> None:
        """Handle GET requests."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')

        if len(path_parts) == 1 and path_parts[0] == 'me':
            self._handle_get_me()
        elif len(path_parts) == 1 and path_parts[0] == 'todos':
            self._handle_list_todos()
        elif len(path_parts) == 2 and path_parts[0] == 'todos':
            try:
                todo_id = int(path_parts[1])
                self._handle_get_todo(todo_id)
            except ValueError:
                self._send_error_response("Invalid todo ID", 400)
        else:
            self._send_error_response("Not Found", 404)

    def do_PUT(self) -> None:
        """Handle PUT requests."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')

        if len(path_parts) == 1 and path_parts[0] == 'password':
            self._handle_update_password()
        elif len(path_parts) == 2 and path_parts[0] == 'todos':
            try:
                todo_id = int(path_parts[1])
                self._handle_update_todo(todo_id)
            except ValueError:
                self._send_error_response("Invalid todo ID", 400)
        else:
            self._send_error_response("Not Found", 404)

    def do_DELETE(self) -> None:
        """Handle DELETE requests."""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')

        if len(path_parts) == 2 and path_parts[0] == 'todos':
            try:
                todo_id = int(path_parts[1])
                self._handle_delete_todo(todo_id)
            except ValueError:
                self._send_error_response("Invalid todo ID", 400)
        else:
            self._send_error_response("Not Found", 404)

    def _handle_register(self) -> None:
        """Handle register endpoint."""
        request_data = self._parse_request_body()

        username = request_data.get('username')
        password = request_data.get('password')

        if not username or not isinstance(username, str):
            self._send_error_response("Invalid username", 400)
            return

        if not password or not isinstance(password, str):
            self._send_error_response("Password too short", 400)
            return

        # Validate username format: 3-50 chars, alphanumeric and underscore only
        if not re.match(r'^[a-zA-Z0-9_]{3,50}$', username):
            self._send_error_response("Invalid username", 400)
            return

        if len(password) < 8:
            self._send_error_response("Password too short", 400)
            return

        # Check if username already exists
        if any(user.username == username for user in self.users.values()):
            self._send_error_response("Username already exists", 409)
            return

        # Create a new user
        password_hash = hash_password(password)
        user = User(self.next_user_id, username, password_hash)
        self.users[self.next_user_id] = user
        
        response = {
            "id": user.id,
            "username": user.username
        }
        
        self.next_user_id += 1
        self._send_json_response(response, 201)

    def _handle_login(self) -> None:
        """Handle login endpoint."""
        request_data = self._parse_request_body()

        username = request_data.get('username')
        password = request_data.get('password')

        if not username or not password:
            self._send_error_response("Invalid credentials", 401)
            return

        # Find user by username
        user = None
        for u in self.users.values():
            if u.username == username:
                user = u
                break

        if not user or user.password_hash != hash_password(password):
            self._send_error_response("Invalid credentials", 401)
            return

        # Register a new session
        session_id = self._register_session(user.id)
        
        response = {
            "id": user.id,
            "username": user.username
        }
        
        # Send session in Set-Cookie header
        self.send_response(200)
        self.send_header("Content-type", "application/json")
        self.send_header("Set-Cookie", f"session_id={session_id}; Path=/; HttpOnly")
        self.end_headers()
        self.wfile.write(json.dumps(response).encode('utf-8'))

    def _handle_logout(self) -> None:
        """Handle logout endpoint."""
        user = self._require_authentication()
        if not user:
            return

        self._invalidate_session()
        self._send_json_response({})

    def _handle_get_me(self) -> None:
        """Handle get me endpoint."""
        user = self._require_authentication()
        if not user:
            return

        response = {
            "id": user.id,
            "username": user.username
        }
        self._send_json_response(response)

    def _handle_update_password(self) -> None:
        """Handle update password endpoint."""
        user = self._require_authentication()
        if not user:
            return

        request_data = self._parse_request_body()

        old_password = request_data.get('old_password')
        new_password = request_data.get('new_password')

        if not old_password or hash_password(old_password) != user.password_hash:
            self._send_error_response("Invalid credentials", 401)
            return

        if not new_password or len(new_password) < 8:
            self._send_error_response("Password too short", 400)
            return

        # Update password
        user.password_hash = hash_password(new_password)
        self._send_json_response({})

    def _handle_list_todos(self) -> None:
        """Handle list todos endpoint."""
        user = self._require_authentication()
        if not user:
            return

        # Filter todos by user_id
        user_todos = [
            self._todo_to_dict(todo) 
            for todo in self.todos.values() 
            if todo.user_id == user.id
        ]
        # Sort by ID in ascending order
        user_todos.sort(key=lambda t: t['id'])

        self._send_json_response(user_todos)

    def _handle_create_todo(self) -> None:
        """Handle create todo endpoint."""
        user = self._require_authentication()
        if not user:
            return

        request_data = self._parse_request_body()

        title = request_data.get('title')
        description = request_data.get('description', "")

        if not title or not isinstance(title, str) or title.strip() == "":
            self._send_error_response("Title is required", 400)
            return

        if not isinstance(description, str):
            description = ""

        # Create a new todo
        now_time = get_iso_timestamp()
        todo = Todo(
            todo_id=self.next_todo_id,
            title=title,
            description=description,
            completed=False,
            created_at=now_time,
            updated_at=now_time,
            user_id=user.id
        )
        self.todos[self.next_todo_id] = todo
        
        response = self._todo_to_dict(todo)
        self.next_todo_id += 1
        self._send_json_response(response, 201)

    def _handle_get_todo(self, todo_id: int) -> None:
        """Handle get specific todo endpoint."""
        user = self._require_authentication()
        if not user:
            return

        todo = self.todos.get(todo_id)
        if not todo or todo.user_id != user.id:
            self._send_error_response("Todo not found", 404)
            return

        response = self._todo_to_dict(todo)
        self._send_json_response(response)

    def _handle_update_todo(self, todo_id: int) -> None:
        """Handle update todo endpoint."""
        user = self._require_authentication()
        if not user:
            return

        todo = self.todos.get(todo_id)
        if not todo or todo.user_id != user.id:
            self._send_error_response("Todo not found", 404)
            return

        request_data = self._parse_request_body()
        
        # Partial updates: only update provided fields
        updated = False
        if 'title' in request_data:
            title = request_data['title']
            if not title or title.strip() == "":
                self._send_error_response("Title is required", 400)
                return
            todo.title = title
            updated = True

        if 'description' in request_data:
            description = request_data['description']
            if isinstance(description, str):
                todo.description = description
            else:
                todo.description = ""
            updated = True

        if 'completed' in request_data:
            completed = request_data['completed']
            if isinstance(completed, bool):
                todo.completed = completed
                updated = True

        # Always update updated_at if anything changed
        if updated:
            todo.updated_at = get_iso_timestamp()

        response = self._todo_to_dict(todo)
        self._send_json_response(response)

    def _handle_delete_todo(self, todo_id: int) -> None:
        """Handle delete todo endpoint."""
        user = self._require_authentication()
        if not user:
            return

        todo = self.todos.get(todo_id)
        if not todo or todo.user_id != user.id:
            self._send_error_response("Todo not found", 404)
            return

        del self.todos[todo_id]
        
        # Set content type to text/plain for DELETE with no body
        self.send_response(204)
        self.send_header("Content-type", "text/plain")
        self.end_headers()

    def _todo_to_dict(self, todo: Todo) -> Dict[str, Any]:
        """Convert a Todo object to a dictionary."""
        return {
            "id": todo.id,
            "title": todo.title,
            "description": todo.description,
            "completed": todo.completed,
            "created_at": todo.created_at,
            "updated_at": todo.updated_at
        }


def main() -> None:
    """Main entry point."""
    parser = argparse.ArgumentParser(description='Todo REST API Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to run the server on')
    args = parser.parse_args()

    server_address = ('0.0.0.0', args.port)
    httpd = HTTPServer(server_address, TodoAppServer)
    
    print(f"Starting server on {server_address[0]}:{server_address[1]}")
    httpd.serve_forever()


if __name__ == "__main__":
    main()