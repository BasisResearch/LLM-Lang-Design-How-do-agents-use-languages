#!/usr/bin/env python3
"""
Todo REST API Server with Cookie-based Authentication
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
import json
import uuid
import re
from datetime import datetime, timezone  # Import timezone too
from typing import Dict, List, Any, Optional


def get_current_timestamp() -> str:
    """Get current time in ISO 8601 format with second precision"""
    # Fixed to use timezone-aware datetime to avoid deprecation warning
    dt = datetime.now(timezone.utc)
    return dt.strftime('%Y-%m-%dT%H:%M:%SZ')


class AuthManager:
    """Manages user authentication and sessions"""
    
    def __init__(self) -> None:
        self.users: Dict[int, Dict[str, Any]] = {}
        self.todos: Dict[int, Dict[str, Any]] = {}
        self.sessions: Dict[str, int] = {}  # session_id -> user_id mapping
        self.next_user_id = 1
        self.next_todo_id = 1
        self.username_to_id: Dict[str, int] = {}

    def register_user(self, username: str, password: str) -> Optional[Dict[str, Any]]:
        """Register a new user"""
        if not re.match(r'^[a-zA-Z0-9_]+$', username):
            return None  # Invalid username  
        if len(username) < 3 or len(username) > 50:
            return None  # Invalid username length
        if len(password) < 8:
            return None  # Password too short
        if username in self.username_to_id:
            return None  # Username already taken
        
        user_id = self.next_user_id
        self.next_user_id += 1
        
        user_data: Dict[str, Any] = {
            'id': user_id,
            'username': username,
            'password': password  # In real app, you'd hash this
        }
        
        self.users[user_id] = user_data
        self.username_to_id[username] = user_id
        return {'id': user_id, 'username': username}

    def authenticate_user(self, username: str, password: str) -> Optional[Dict[str, Any]]:
        """Authenticate user credentials and return user info"""
        user_id = self.username_to_id.get(username)
        if user_id is None:
            return None
        
        user = self.users[user_id]
        if user['password'] != password:
            return None
            
        return {'id': user_id, 'username': user['username']}
    
    def create_session(self, user_id: int) -> str:
        """Create a new session and return the session ID"""
        session_id = uuid.uuid4().hex
        self.sessions[session_id] = user_id
        return session_id
    
    def get_user_from_session(self, session_id: str) -> Optional[Dict[str, Any]]:
        """Get user info from session ID"""
        user_id = self.sessions.get(session_id)
        if user_id is None:
            return None
        return self.users.get(user_id)
    
    def validate_session(self, session_id: str) -> bool:
        """Validate if session is active"""
        return session_id in self.sessions
    
    def logout(self, session_id: str) -> bool:
        """Invalidate a session"""
        if session_id in self.sessions:
            del self.sessions[session_id]
            return True
        return False
    
    def change_password(self, session_id: str, old_pwd: str, new_pwd: str) -> bool:
        """Change password for authenticated user"""
        user = self.get_user_from_session(session_id)
        if user is None:
            return False
        if user['password'] != old_pwd or len(new_pwd) < 8:
            return False
        
        user['password'] = new_pwd
        return True
    
    def create_todo(self, user_id: int, title: str, description: str) -> Dict[str, Any]:
        """Create a new todo for a user"""
        todo_id = self.next_todo_id
        self.next_todo_id += 1
        
        created_at = get_current_timestamp()
        todo: Dict[str, Any] = {
            'id': todo_id,
            'user_id': user_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': created_at,
            'updated_at': created_at
        }
        
        self.todos[todo_id] = todo
        return todo
    
    def get_todos_for_user(self, user_id: int) -> List[Dict[str, Any]]:
        """Get all todos for a specific user"""
        user_todos = []
        for todo in self.todos.values():
            if todo['user_id'] == user_id:
                # Remove internal field so only API-exposed fields are sent
                public_todo = {k: v for k, v in todo.items() if k != 'user_id'}
                user_todos.append(public_todo)
        
        # Sort todos by id in ascending order
        user_todos.sort(key=lambda x: x['id'])
        return user_todos
    
    def get_todo_by_id(self, user_id: int, todo_id: int) -> Optional[Dict[str, Any]]:
        """Get a specific todo if it belongs to the user"""
        todo = self.todos.get(todo_id)
        if todo is None or todo['user_id'] != user_id:
            return None
        
        # Remove internal field before returning to client
        public_todo = {k: v for k, v in todo.items() if k != 'user_id'}
        return public_todo
    
    def update_todo(
        self, 
        user_id: int, 
        todo_id: int, 
        updates: Dict[str, Any]
    ) -> Optional[Dict[str, Any]]:
        """Update properties of a todo"""
        todo = self.todos.get(todo_id)
        if todo is None or todo['user_id'] != user_id:
            return None
        
        # Validate title if provided
        if 'title' in updates and not updates['title'].strip():
            return None  # Title cannot be empty
        
        # Apply updates
        for key, value in updates.items():
            if key in ['title', 'description', 'completed']:
                todo[key] = value
        
        # Update the timestamp for the last modification
        todo['updated_at'] = get_current_timestamp()
        
        # Return public view of the updated todo
        public_todo = {k: v for k, v in todo.items() if k != 'user_id'}
        return public_todo
    
    def delete_todo(self, user_id: int, todo_id: int) -> bool:
        """Delete a user's todo"""
        if todo_id not in self.todos:
            return False
        if self.todos[todo_id]['user_id'] != user_id:
            return False
        
        del self.todos[todo_id]
        return True


# Global auth manager (this will be referenced by handlers)
global_auth_manager: Optional[AuthManager] = None


class TodoHTTPHandler(BaseHTTPRequestHandler):
    """HTTP Handler for Todo API endpoints"""
    
    def _extract_session_id(self) -> Optional[str]:
        """Extract session ID from request headers"""
        cookies_header = self.headers.get('Cookie')
        if not cookies_header:
            return None
        
        cookies: List[str] = [c.strip() for c in cookies_header.split(';')]
        for cookie in cookies:
            parts = cookie.split('=', 1)
            if len(parts) == 2 and parts[0].strip() == 'session_id':
                return parts[1].strip()
        
        return None
    
    def _send_json_response(self, status_code: int, response_data: Any) -> None:
        """Send JSON response with appropriate headers"""
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        
        response_json = json.dumps(response_data)
        self.wfile.write(response_json.encode())
    
    def _send_error_response(self, status_code: int, message: str) -> None:
        """Send error response with JSON body"""
        self._send_json_response(status_code, {'error': message})
    
    def _send_empty_response(self, status_code: int) -> None:
        """Send response with no body (for DELETE)"""
        self.send_response(status_code)
        if status_code == 204:
            # Don't send Content-Type header for 204 No Content
            self.end_headers()
        else:
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{}')
    
    def _get_auth_manager(self) -> AuthManager:
        """Get the global auth manager (must exist when method is called)"""
        global global_auth_manager
        if global_auth_manager is None:
            raise RuntimeError("Auth manager not initialized")
        return global_auth_manager

    def _require_auth(self) -> Optional[Dict[str, Any]]:
        """Check for valid authentication, return user data if valid, None otherwise."""
        session_id = self._extract_session_id()
        if not session_id:
            return None
        
        user: Optional[Dict[str, Any]] = self._get_auth_manager().get_user_from_session(session_id)
        return user
    
    def do_POST(self) -> None:
        """Handle POST requests"""
        # Parse the request body
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length).decode()
        
        try:
            request_json = json.loads(post_data) if post_data else {}
        except json.JSONDecodeError:
            self._send_error_response(400, 'Invalid JSON')
            return

        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/register':
            self._handle_register(request_json)
        elif parsed_path.path == '/login':
            self._handle_login(request_json)
        elif parsed_path.path == '/logout':
            # Check authentication for logout
            user = self._require_auth()
            if not user:
                self._send_error_response(401, 'Authentication required')
                return
            self._handle_logout()
        elif parsed_path.path == '/todos':
            # Check authentication for creating todos
            user = self._require_auth()
            if not user:
                self._send_error_response(401, 'Authentication required')
                return
            self._handle_create_todo(request_json, user['id'])
        elif parsed_path.path == '/password':
            # Check user is signed in for password change
            user = self._require_auth()
            if not user:
                self._send_error_response(401, 'Authentication required')
                return
            self._handle_change_password(request_json)
        else:
            self._send_error_response(404, 'Endpoint not found')
    
    def _handle_register(self, request_json: Dict[str, Any]) -> None:
        """Handle user registration"""
        if 'username' not in request_json or 'password' not in request_json:
            self._send_error_response(400, 'Username and password are required')
            return
        
        username = request_json['username']
        password = request_json['password']
        
        result = self._get_auth_manager().register_user(username, password)
        if result is None:
            if not re.match(r'^[a-zA-Z0-9_]+$', username) or len(username) < 3 or len(username) > 50:
                self._send_error_response(400, 'Invalid username')
            elif len(password) < 8:
                self._send_error_response(400, 'Password too short')
            else:
                self._send_error_response(409, 'Username already exists')
            return
        
        self.send_response(201)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(result).encode())
    
    def _handle_login(self, request_json: Dict[str, Any]) -> None:
        """Handle user login"""
        if 'username' not in request_json or 'password' not in request_json:
            self._send_error_response(400, 'Username and password are required')
            return
        
        username = request_json['username']
        password = request_json['password']
        
        user = self._get_auth_manager().authenticate_user(username, password)
        if not user:
            self._send_error_response(401, 'Invalid credentials')
            return
        
        session_id = self._get_auth_manager().create_session(user['id'])
        
        # Send response with Set-Cookie header
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')
        self.end_headers()
        self.wfile.write(json.dumps(user).encode())
    
    def _handle_logout(self) -> None:
        """Handle user logout"""
        session_id = self._extract_session_id()
        
        if session_id and self._get_auth_manager().logout(session_id):
            self._send_json_response(200, {})
        else:
            self._send_error_response(401, 'Authentication required')
    
    def _handle_change_password(self, request_json: Dict[str, Any]) -> None:
        """Handle password change request"""
        if 'old_password' not in request_json or 'new_password' not in request_json:
            self._send_error_response(400, 'Both old and new passwords are required')
            return
        
        old_password = request_json['old_password']
        new_password = request_json['new_password']
        
        if len(new_password) < 8:
            self._send_error_response(400, 'Password too short')
            return
        
        session_id = self._extract_session_id()
        if not session_id:
            self._send_error_response(401, 'Authentication required')
            return
        
        success = self._get_auth_manager().change_password(session_id, old_password, new_password)
        if success:
            self._send_empty_response(200)
        else:
            self._send_error_response(401, 'Invalid credentials')
    
    def _handle_create_todo(self, request_json: Dict[str, Any], user_id: int) -> None:
        """Handle creating a new todo"""
        if 'title' not in request_json:
            self._send_error_response(400, 'Title is required')
            return
        
        title = request_json['title']
        description = request_json.get('description', '')
        
        if not title.strip():
            self._send_error_response(400, 'Title is required')
            return
        
        # Create the todo using auth manager with current user
        new_todo_with_internal = self._get_auth_manager().create_todo(user_id, title.strip(), description)
        
        # Remove the internal user_id field before JSON serialization  
        public_todo = {k: v for k, v in new_todo_with_internal.items() if k != 'user_id'}
        
        self.send_response(201)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(public_todo).encode())
    
    def do_GET(self) -> None:
        """Handle GET requests"""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/me':
            user = self._require_auth()
            if not user:
                self._send_error_response(401, 'Authentication required')
                return
            self._send_json_response(200, {'id': user['id'], 'username': user['username']})
        
        elif parsed_path.path == '/todos':
            user = self._require_auth()
            if not user:
                self._send_error_response(401, 'Authentication required')
                return
            todos = self._get_auth_manager().get_todos_for_user(user['id'])
            self._send_json_response(200, todos)
        
        elif parsed_path.path.startswith('/todos/'):
            try:
                todo_id = int(parsed_path.path.split('/')[2])
            except (ValueError, IndexError):
                self._send_error_response(404, 'Todo not found')
                return
            
            user = self._require_auth()
            if not user:
                self._send_error_response(401, 'Authentication required')
                return
            
            todo = self._get_auth_manager().get_todo_by_id(user['id'], todo_id)
            if todo is None:
                self._send_error_response(404, 'Todo not found')
                return
            
            self._send_json_response(200, todo)
        
        else:
            self._send_error_response(404, 'Endpoint not found')
    
    def do_PUT(self) -> None:
        """Handle PUT requests"""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.split('/')
        
        if len(path_parts) >= 3 and path_parts[1] == 'todos':
            try:
                todo_id = int(path_parts[2])
            except (ValueError, IndexError):
                self._send_error_response(404, 'Todo not found')
                return
            
            # Verify user is authenticated
            user = self._require_auth()
            if not user:
                self._send_error_response(401, 'Authentication required')
                return
            
            # Read and parse the request body
            content_length = int(self.headers.get('Content-Length', 0))
            put_data = self.rfile.read(content_length).decode()
            
            try:
                request_json = json.loads(put_data) if put_data else {}
            except json.JSONDecodeError:
                self._send_error_response(400, 'Invalid JSON')
                return
            
            # Update the todo
            updated_todo = self._get_auth_manager().update_todo(user['id'], todo_id, request_json)
            if updated_todo is None:
                # Validation failed or todo doesn't belong to user
                if 'title' in request_json and not request_json['title'].strip():
                    self._send_error_response(400, 'Title is required')
                else:
                    self._send_error_response(404, 'Todo not found')
                return
            
            self._send_json_response(200, updated_todo)
        
        elif parsed_path.path == '/password':
            user = self._require_auth()
            if not user:
                self._send_error_response(401, 'Authentication required')
                return
                
            content_length = int(self.headers.get('Content-Length', 0))
            put_data = self.rfile.read(content_length).decode()
            
            try:
                request_json = json.loads(put_data) if put_data else {}
            except json.JSONDecodeError:
                self._send_error_response(400, 'Invalid JSON')
                return
                
            self._handle_change_password(request_json)
        
        else:
            self._send_error_response(404, 'Endpoint not found')
    
    def do_DELETE(self) -> None:
        """Handle DELETE requests"""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path.startswith('/todos/'):
            try:
                todo_id = int(parsed_path.path.split('/')[2])
            except (ValueError, IndexError):
                self._send_error_response(404, 'Todo not found')
                return
            
            user = self._require_auth()
            if not user:
                self._send_error_response(401, 'Authentication required')
                return
            
            success = self._get_auth_manager().delete_todo(user['id'], todo_id)
            if success:
                self.send_response(204)
                self.end_headers()
            else:
                self._send_error_response(404, 'Todo not found')


def main() -> None:
    import argparse
    
    global global_auth_manager
    global_auth_manager = AuthManager()
    
    parser = argparse.ArgumentParser(description='Todo API Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to listen on')
    args = parser.parse_args()
    
    server_address = ('0.0.0.0', args.port)
    httpd = HTTPServer(server_address, TodoHTTPHandler)
    
    print(f'Starting server on 0.0.0.0:{args.port}')
    httpd.serve_forever()


if __name__ == '__main__':
    main()