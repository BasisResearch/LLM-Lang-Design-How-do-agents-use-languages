#!/usr/bin/env python3
"""
Todo REST API Server with Cookie-based Authentication
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import json
import uuid
import re
from datetime import datetime
from typing import Dict, List, Any, Optional, Tuple, Union, Callable


class TodoApp:
    """Core application logic for the Todo app."""
    
    def __init__(self) -> None:
        # Storage for users, todos, and sessions
        self.users: Dict[int, Dict[str, Any]] = {}
        self.todos: Dict[int, Dict[str, Any]] = {}
        self.sessions: Dict[str, int] = {}  # Maps session_id to user_id
        self.next_user_id = 1
        self.next_todo_id = 1
        
        # Compile regex patterns
        self.username_pattern = re.compile(r'^[a-zA-Z0-9_]+$')
        
    def validate_username(self, username: str) -> bool:
        """Validate username according to requirements: 3-50 chars, alphanumeric and underscore only."""
        if not isinstance(username, str) or len(username) < 3 or len(username) > 50:
            return False
        return bool(self.username_pattern.match(username))
    
    def register_user(self, username: str, password: str) -> Tuple[int, Dict[str, Any]]:
        """Register a new user."""
        if not self.validate_username(username):
            raise ValueError("Invalid username")
            
        if len(password) < 8:
            raise ValueError("Password too short")
            
        for user_data in self.users.values():
            if user_data['username'] == username:
                raise ValueError("Username already exists")
                
        # Create the user
        user_id = self.next_user_id
        self.next_user_id += 1
        
        user_data = {
            'id': user_id,
            'username': username,
            'password_hash': hash(password)  # Simple hash for comparison
        }
        self.users[user_id] = user_data
        
        return user_id, {'id': int(user_data['id']), 'username': str(user_data['username'])}  # Fix line 57 type issue
    
    def authenticate_user(self, username: str, password: str) -> Optional[int]:
        """Authenticate a user and return user_id if successful."""
        for user_data in self.users.values():
            if user_data['username'] == username and user_data['password_hash'] == hash(password):
                return int(user_data['id'])  # Fix line 63 type issue with explicit cast
        return None
        
    def create_session(self) -> str:
        """Create a new session token."""
        session_id = str(uuid.uuid4())
        while session_id in self.sessions:  # In case of collision though unlikely
            session_id = str(uuid.uuid4())
        return session_id
    
    def get_user_from_session(self, session_id: str) -> Optional[Dict[str, Any]]:
        """Get user data by session ID."""
        if not session_id or session_id not in self.sessions:
            return None
        user_id = self.sessions[session_id]
        user_data = self.users.get(user_id)
        if user_data is not None:
            # Only return public parts of user data
            return {
                'id': int(user_data['id']),
                'username': str(user_data['username'])
            }  # Fix line 224 type issue with explicit cast
        return None
        
    def logout_user(self, session_id: str) -> bool:
        """Log out user by removing session."""
        if session_id in self.sessions:
            del self.sessions[session_id]
            return True
        return False
        
    def change_password(self, session_id: str, old_password: str, new_password: str) -> bool:
        """Change user password."""
        user = self.get_user_from_session(session_id)
        if not user:
            return False
        user_id = self.sessions[session_id]  # Get user id from session
        stored_user = self.users.get(user_id)
        if not stored_user or stored_user['password_hash'] != hash(old_password):
            return False
        if len(new_password) < 8:
            raise ValueError("Password too short")
        
        stored_user['password_hash'] = hash(new_password)
        return True
        
    def create_todo(self, session_id: str, title: str, description: str = "") -> Dict[str, Any]:
        """Create a new todo for the authenticated user."""
        user = self.get_user_from_session(session_id)
        if not user:
            raise PermissionError("Authentication required")
        
        if not title or not isinstance(title, str) or len(title.strip()) == 0:
            raise ValueError("Title is required")
        
        timestamp = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        
        todo_id = self.next_todo_id
        self.next_todo_id += 1
        
        todo_data = {
            'id': todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': timestamp,
            'updated_at': timestamp,
            'user_id': user['id']  # Store user_id to associate todo with user
        }
        
        self.todos[todo_id] = todo_data
        # Return the public facing version (without user_id)
        return {k: v for k, v in todo_data.items() if k != 'user_id'}
    
    def get_todos_by_user(self, session_id: str) -> List[Dict[str, Any]]:
        """Get all todos for authenticated user."""
        user = self.get_user_from_session(session_id)
        if not user:
            raise PermissionError("Authentication required")
        
        user_todos: List[Dict[str, Any]] = []
        for todo_data in self.todos.values():
            if int(todo_data['user_id']) == user['id']:  # Explicit cast to be safe
                user_todos.append({k: v for k, v in todo_data.items() if k != 'user_id'})
        
        # Sort by ID ascending
        user_todos.sort(key=lambda x: x['id'])
        return user_todos
    
    def get_todo_by_user_and_id(self, session_id: str, todo_id: int) -> Optional[Dict[str, Any]]:
        """Get a single todo that belongs to authenticated user."""
        user = self.get_user_from_session(session_id)
        if not user:
            raise PermissionError("Authentication required")
        
        if todo_id not in self.todos:
            return None
            
        todo_data = self.todos[todo_id]
        if int(todo_data['user_id']) != user['id']:  # Explicit cast to be safe
            return None  # Important: also return none if other user's todo
        
        # Return without internal user_id field
        return {k: v for k, v in todo_data.items() if k != 'user_id'}
    
    def update_todo_by_id(self, session_id: str, todo_id: int, updates: Dict[str, Any]) -> Dict[str, Any]:
        """Update a todo that belongs to authenticated user."""
        user = self.get_user_from_session(session_id)
        if not user:
            raise PermissionError("Authentication required")
        
        if todo_id not in self.todos:
            raise KeyError("Todo not found")
        
        todo_data = self.todos[todo_id]
        if int(todo_data['user_id']) != user['id']:   # Explicit cast to be safe
            raise KeyError("Todo not found")  # Important: same error for non-existent and wrong user
        
        # Validate title if present
        if 'title' in updates and updates['title'] == '':
            raise ValueError("Title is required")
        
        # Update fields that were provided
        for field in ['title', 'description', 'completed']:
            if field in updates:
                todo_data[field] = updates[field]
        
        # Always update the timestamp
        todo_data['updated_at'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        
        # Return updated data without internal user_id
        return {k: v for k, v in todo_data.items() if k != 'user_id'}
    
    def delete_todo_by_id(self, session_id: str, todo_id: int) -> bool:
        """Delete a todo that belongs to authenticated user."""
        user = self.get_user_from_session(session_id)
        if not user:
            raise PermissionError("Authentication required")
        
        if todo_id not in self.todos:
            raise KeyError("Todo not found")
        
        todo_data = self.todos[todo_id]
        if int(todo_data['user_id']) != user['id']:  # Explicit cast to be safe 
            raise KeyError("Todo not found")  # Important: same error as above
        
        del self.todos[todo_id]
        return True


def create_request_handler(app: TodoApp) -> type:
    """Factory to create request handlers with access to a specific todo app instance"""
    class TodoHandler(BaseHTTPRequestHandler):
        """HTTP Request Handler for the Todo app."""
        
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            self.app = app
            super().__init__(*args, **kwargs)  # Actually call BaseHTTPRequestHandler.__init__
        
        def _parse_json_body(self) -> Any:  # Fixed: Accept any JSON type (dict, list, etc)
            """Parse JSON from request body."""
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                return {}
            request_body = self.rfile.read(content_length).decode('utf-8')
            try:
                return json.loads(request_body)
            except json.JSONDecodeError:
                raise ValueError("Invalid JSON in request body")
        
        def _get_path_parts(self) -> List[str]:
            """Get parts of URL path as a list."""
            parsed_url = urlparse(self.path)
            path = parsed_url.path.strip('/')
            if path:
                return path.split('/')
            return []
        
        def _get_query_params(self) -> Dict[str, List[str]]:
            """Get query parameters."""
            parsed_url = urlparse(self.path)
            return parse_qs(parsed_url.query)
            
        def _get_session_id(self) -> str:
            """Extract session_id from cookies."""
            cookie_header = self.headers.get('Cookie')
            if not cookie_header:
                return ""
            
            cookies = [c.strip() for c in cookie_header.split(';')]
            for cookie in cookies:
                if cookie.startswith('session_id='):
                    return cookie[len('session_id='):]
            return ""
            
        def _set_session_cookie(self, session_id: str) -> None:
            """Set session cookie in response headers."""
            self.send_header('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')
        
        def _send_json_response(self, status_code: int, data: Any) -> None:
            """Send JSON response with proper headers."""
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            
            if data is not None:
                response_content = json.dumps(data, separators=(',', ':')).encode('utf-8')
                self.wfile.write(response_content)
        
        def _send_empty_response(self, status_code: int) -> None:
            """Send response with no body."""
            self.send_response(status_code)
            self.end_headers()
        
        def handle_error(self, message: str, status_code: int = 400) -> bool:
            """Send error response and return whether this was an error."""
            self._send_json_response(status_code, {'error': message})
            return True
            
        def do_GET(self) -> None:
            """Handle GET requests."""
            path_parts = self._get_path_parts()
            session_id = self._get_session_id()
            
            if len(path_parts) >= 2 and path_parts[0] == 'todos' and path_parts[1].isdigit():
                # GET /todos/:id
                todo_id = int(path_parts[1])
                try:
                    todo_result = self.app.get_todo_by_user_and_id(session_id, todo_id)  # Change variable name to avoid clash
                    if todo_result is None:
                        self._send_json_response(404, {'error': 'Todo not found'})
                    else:
                        self._send_json_response(200, todo_result)
                except PermissionError:
                    self._send_json_response(401, {'error': 'Authentication required'})
            elif len(path_parts) == 1 and path_parts[0] == 'todos':
                # GET /todos
                try:
                    todos_list = self.app.get_todos_by_user(session_id)
                    self._send_json_response(200, todos_list)
                except PermissionError:
                    self._send_json_response(401, {'error': 'Authentication required'})
            elif len(path_parts) == 1 and path_parts[0] == 'me':
                # GET /me
                user = self.app.get_user_from_session(session_id)
                if user:
                    self._send_json_response(200, {'id': user['id'], 'username': user['username']})
                else:
                    self._send_json_response(401, {'error': 'Authentication required'})
            else:
                self._send_json_response(404, {'error': 'Not Found'})
        
        def do_POST(self) -> None:
            """Handle POST requests."""
            path_parts = self._get_path_parts()
            
            try:
                if len(path_parts) == 1 and path_parts[0] == 'register':
                    # POST /register
                    try:
                        data = self._parse_json_body()  # Note: data could be dict or list
                        if not isinstance(data, dict):
                            self._send_json_response(400, {'error': 'Expected JSON object'})
                            return
                        username = data.get('username', '')
                        password = data.get('password', '')
                        
                        user_id, user_data = self.app.register_user(username, password)
                        self._send_json_response(201, user_data)
                    except ValueError as e:
                        if str(e) == "Invalid username":
                            self._send_json_response(400, {'error': 'Invalid username'})
                        elif str(e) == "Password too short":
                            self._send_json_response(400, {'error': 'Password too short'})
                        elif str(e) == "Username already exists":
                            self._send_json_response(409, {'error': 'Username already exists'})
                        else:
                            self._send_json_response(400, {'error': str(e)})
            
                elif len(path_parts) == 1 and path_parts[0] == 'login':
                    # POST /login
                    try:
                        data = self._parse_json_body()
                        if not isinstance(data, dict):
                            self._send_json_response(400, {'error': 'Expected JSON object'})
                            return
                        username = data.get('username', '')
                        password = data.get('password', '')
                        
                        user_id_opt = self.app.authenticate_user(username, password)
                        if user_id_opt is None:
                            self._send_json_response(401, {'error': 'Invalid credentials'})
                        else:
                            session_id = self.app.create_session()
                            self.app.sessions[session_id] = user_id_opt
                            
                            user_data = self.app.users[user_id_opt]
                            
                            self.send_response(200)
                            self._set_session_cookie(session_id)
                            self.send_header('Content-Type', 'application/json')
                            self.end_headers()
                            
                            response_content = json.dumps({
                                'id': user_data['id'], 
                                'username': user_data['username']
                            }, separators=(',', ':')).encode('utf-8')
                            self.wfile.write(response_content)
                    except ValueError:
                        self._send_json_response(400, {'error': 'Invalid request body'})
            
                elif len(path_parts) == 1 and path_parts[0] == 'logout':
                    # POST /logout
                    session_id = self._get_session_id()
                    if not session_id or session_id not in self.app.sessions:
                        self._send_json_response(401, {'error': 'Authentication required'})
                    else:
                        self.app.logout_user(session_id)
                        self._send_json_response(200, {})
            
                elif len(path_parts) == 1 and path_parts[0] == 'todos':
                    # POST /todos
                    session_id = self._get_session_id()
                    try:
                        data = self._parse_json_body()
                        if not isinstance(data, dict):
                            self._send_json_response(400, {'error': 'Expected JSON object'})
                            return
                        title = data.get('title', '')
                        description = data.get('description', '')
                        
                        new_todo = self.app.create_todo(session_id, title, description)
                        self._send_json_response(201, new_todo)
                    except ValueError as e:
                        if str(e) == "Title is required":
                            self._send_json_response(400, {'error': 'Title is required'})
                        else:
                            self.handle_error(str(e), 400)
                    except PermissionError:
                        self._send_json_response(401, {'error': 'Authentication required'})
            
                else:
                    self._send_json_response(404, {'error': 'Not Found'})
            except Exception:
                self._send_json_response(500, {'error': 'Internal server error'})
        
        def do_PUT(self) -> None:
            """Handle PUT requests."""
            path_parts = self._get_path_parts()
            session_id = self._get_session_id()
            
            if len(path_parts) >= 2 and path_parts[0] == 'todos' and path_parts[1].isdigit():
                # PUT /todos/:id
                todo_id = int(path_parts[1])
                try:
                    updates = self._parse_json_body()
                    if not isinstance(updates, dict):
                        self._send_json_response(400, {'error': 'Expected JSON object'})
                        return
                    updated_todo = self.app.update_todo_by_id(session_id, todo_id, updates)
                    self._send_json_response(200, updated_todo)
                except KeyError:
                    self._send_json_response(404, {'error': 'Todo not found'})
                except ValueError as e:
                    if str(e) == "Title is required":
                        self._send_json_response(400, {'error': 'Title is required'})
                    else:
                        self.handle_error(str(e), 400)
                    return
                except PermissionError:
                    self._send_json_response(401, {'error': 'Authentication required'})
                    return
            elif len(path_parts) == 1 and path_parts[0] == 'password':
                # PUT /password
                try:
                    data = self._parse_json_body()
                    if not isinstance(data, dict):
                        self._send_json_response(400, {'error': 'Expected JSON object'})
                        return
                    old_password = data.get('old_password', '')
                    new_password = data.get('new_password', '')
                    
                    try:
                        if not self.app.change_password(session_id, old_password, new_password):
                            user = self.app.get_user_from_session(session_id)
                            if not user or session_id not in self.app.sessions:
                                self._send_json_response(401, {'error': 'Authentication required'})
                            else:
                                # Since change_password raised nothing, the old password was wrong
                                self._send_json_response(401, {'error': 'Invalid credentials'})
                        elif len(new_password) < 8:
                            self._send_json_response(400, {'error': 'Password too short'})
                        else:
                            self._send_json_response(200, {})
                    except ValueError:
                        self._send_json_response(400, {'error': 'Password too short'})
                except ValueError:
                    self._send_json_response(400, {'error': 'Invalid request body'})
                except PermissionError:
                    self._send_json_response(401, {'error': 'Authentication required'})
                    return
            else:
                self._send_json_response(404, {'error': 'Not Found'})
        
        def do_DELETE(self) -> None:
            """Handle DELETE requests."""
            path_parts = self._get_path_parts()
            session_id = self._get_session_id()
            
            if len(path_parts) >= 2 and path_parts[0] == 'todos' and path_parts[1].isdigit():
                # DELETE /todos/:id
                todo_id = int(path_parts[1])
                try:
                    success = self.app.delete_todo_by_id(session_id, todo_id)
                    if success:
                        self._send_empty_response(204)
                    else:
                        # This shouldn't happen due to exception handling but let's be safe
                        self._send_json_response(404, {'error': 'Todo not found'})
                except KeyError:
                    self._send_json_response(404, {'error': 'Todo not found'})
                except PermissionError:
                    self._send_json_response(401, {'error': 'Authentication required'})
            else:
                self._send_json_response(404, {'error': 'Not Found'})

    return TodoHandler


if __name__ == '__main__':
    import argparse
    
    app = TodoApp()
    TodoHandler = create_request_handler(app)
    
    parser = argparse.ArgumentParser(description='Todo API Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to run the server on')
    args = parser.parse_args()
    
    server_address = ('0.0.0.0', args.port)
    httpd = HTTPServer(server_address, TodoHandler)
    
    print(f'Todo app server running on {server_address[0]}:{server_address[1]}')
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down...')
        httpd.shutdown()