#!/usr/bin/env python3
"""
Todo REST API Server with Cookie-based Authentication
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import json
import bcrypt
import re
import uuid
from datetime import datetime
from typing import Dict, List, Any, Optional, Union, cast


class AuthManager:
    def __init__(self) -> None:
        # Map session_id -> user_id
        self.sessions: Dict[str, int] = {}
        # Map user_id -> {username, hashed_password}
        self.users: Dict[int, Dict[str, Union[str, bytes]]] = {}
        # Auto-increment counter for user IDs
        self.next_user_id: int = 1
    
    def register_user(self, username: str, password: str) -> Optional[Dict[str, Any]]:
        # Validate username format (alphanumeric + underscore only, 3-50 chars)
        if not re.match(r'^[a-zA-Z0-9_]{3,50}$', username):
            return {"error": "Invalid username"}
        
        # Check if this username already exists
        for user_data in self.users.values():
            if cast(str, user_data["username"]) == username:
                return {"error": "Username already exists"}
        
        # Validate password length
        if len(password) < 8:
            return {"error": "Password too short"}
        
        # Hash password
        hashed = bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt())
        
        # Create new user
        user_id = self.next_user_id
        self.next_user_id += 1
        self.users[user_id] = {
            "username": username,
            "hashed_password": hashed
        }
        
        return {
            "id": user_id,
            "username": username
        }
    
    def authenticate_user(self, username: str, password: str) -> Optional[Dict[str, Any]]:
        # Find user by username
        user_id: Optional[int] = None
        for u_id, user_data in self.users.items():
            if cast(str, user_data["username"]) == username:
                user_id = u_id
                break
        
        if user_id is None:
            return None
        
        # Verify password
        user_data = self.users[user_id]
        if not bcrypt.checkpw(password.encode('utf-8'), cast(bytes, user_data["hashed_password"])):
            return None
        
        # Create session
        session_id = str(uuid.uuid4())
        self.sessions[session_id] = user_id
        
        return {
            "id": user_id,
            "username": cast(str, user_data["username"]),
            "session_id": session_id
        }
    
    def get_user_from_session(self, session_id: str) -> Optional[Dict[str, Any]]:
        if session_id not in self.sessions:
            return None
        
        user_id = self.sessions[session_id]
        if user_id not in self.users:
            return None
        
        user_data = self.users[user_id]
        return {
            "id": user_id,
            "username": cast(str, user_data["username"])
        }
    
    def logout(self, session_id: str) -> bool:
        if session_id in self.sessions:
            del self.sessions[session_id]
            return True
        return False
    
    def change_password(self, session_id: str, old_password: str, new_password: str) -> Optional[Dict[str, str]]:
        if session_id not in self.sessions:
            return None
        
        user_id = self.sessions[session_id]
        user_data = self.users[user_id]
        
        # Check old password
        if not bcrypt.checkpw(old_password.encode('utf-8'), cast(bytes, user_data["hashed_password"])):
            return {"error": "Invalid credentials"}
        
        # Validate new password length
        if len(new_password) < 8:
            return {"error": "Password too short"}
        
        # Update password
        hashed_new = bcrypt.hashpw(new_password.encode('utf-8'), bcrypt.gensalt())
        self.users[user_id]["hashed_password"] = hashed_new
        
        return {}


class TodoManager:
    def __init__(self) -> None:
        # Map todo_id -> {title, description, completed, created_at, updated_at, user_id}
        self.todos: Dict[int, Dict[str, Union[str, bool, int]]] = {}
        # Auto-increment counter for todo IDs
        self.next_todo_id: int = 1
        
    def create_todo(self, user_id: int, title: str, description: str) -> Dict[str, Any]:
        created_at = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        todo_id = self.next_todo_id
        self.next_todo_id += 1
        
        self.todos[todo_id] = {
            "id": todo_id,
            "title": title,
            "description": description,
            "completed": False,
            "created_at": created_at,
            "updated_at": created_at,
            "user_id": user_id
        }
        
        return self.todos[todo_id]
    
    def get_todos_for_user(self, user_id: int) -> List[Dict[str, Any]]:
        user_todos = []
        for todo_data in sorted(self.todos.values(), key=lambda x: cast(int, x['id'])):  # Sort by id ascending
            if cast(int, todo_data["user_id"]) == user_id:
                user_todos.append(todo_data)
        return user_todos
    
    def get_todo(self, todo_id: int, user_id: int) -> Optional[Dict[str, Any]]:
        if todo_id not in self.todos:
            return None
        
        todo_data = self.todos[todo_id]
        if cast(int, todo_data["user_id"]) != user_id:
            return None  # Don't expose other users' todos, return None instead of 403
        
        return todo_data
    
    def update_todo(self, todo_id: int, user_id: int, updates: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        if todo_id not in self.todos:
            return None
        
        todo_data = self.todos[todo_id]
        if cast(int, todo_data["user_id"]) != user_id:
            return None
        
        # Apply updates if they exist
        if 'title' in updates:
            title = cast(str, updates['title'])
            if not title.strip():  # Title cannot be empty
                return {"error": "Title is required"}
            self.todos[todo_id]['title'] = title
        
        if 'description' in updates:
            self.todos[todo_id]['description'] = updates['description']
        
        if 'completed' in updates:
            self.todos[todo_id]['completed'] = updates['completed']
        
        # Update the updated_at field
        self.todos[todo_id]['updated_at'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        
        return self.todos[todo_id]
    
    def delete_todo(self, todo_id: int, user_id: int) -> bool:
        if todo_id not in self.todos:
            return False
        
        todo_data = self.todos[todo_id]
        if cast(int, todo_data["user_id"]) != user_id:
            return False
        
        del self.todos[todo_id]
        return True


class TodoServer(BaseHTTPRequestHandler):
    # Class variables to share auth and todo managers
    auth_manager: AuthManager
    todo_manager: TodoManager
    
    def _get_session_id(self) -> Optional[str]:
        """Extract session_id from cookies"""
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return None
        
        cookies = {}
        for cookie in cookie_header.split(';'):
            if '=' in cookie:
                name, value = cookie.strip().split('=', 1)
                cookies[name] = value
        
        return cookies.get('session_id')
    
    def _send_response(self, status_code: int, data: Any, set_cookie: Optional[str] = None) -> None:
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        
        if set_cookie:
            self.send_header('Set-Cookie', f'{set_cookie}; Path=/; HttpOnly')
        
        self.end_headers()
        
        if status_code != 204:  # No body for 204
            response_data = json.dumps(data, ensure_ascii=True)
            self.wfile.write(response_data.encode('utf-8'))
    
    def _parse_json_body(self) -> Any:
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return None
        
        post_data = self.rfile.read(content_length)
        try:
            return json.loads(post_data.decode('utf-8'))
        except json.JSONDecodeError:
            return None
    
    def do_POST(self) -> None:
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/register':
            self._handle_register()
        
        elif parsed_path.path == '/login':
            self._handle_login()
        
        elif parsed_path.path == '/logout':
            self._handle_logout()
        
        elif parsed_path.path == '/password':
            self._handle_change_password()
        
        elif parsed_path.path == '/todos':
            self._handle_create_todo()
        
        else:
            self._send_response(404, {"error": "Not found"})
    
    def _handle_register(self) -> None:
        body = self._parse_json_body()
        if not body:
            self._send_response(400, {"error": "Invalid JSON"})
            return
        
        username = body.get('username')
        password = body.get('password')
        
        if not username or not password:
            self._send_response(400, {"error": "Missing username or password"})
            return
        
        result = TodoServer.auth_manager.register_user(username, password)
        
        if isinstance(result, dict) and 'error' in result:
            if result["error"] == "Username already exists":
                self._send_response(409, result)
            else:
                self._send_response(400, result)
        else:
            self._send_response(201, result)  # Success with user object
    
    def _handle_login(self) -> None:
        body = self._parse_json_body()
        if not body:
            self._send_response(400, {"error": "Invalid JSON"})
            return
        
        username = body.get('username')
        password = body.get('password')
        
        if not username or not password:
            self._send_response(400, {"error": "Missing username or password"})
            return
        
        result = TodoServer.auth_manager.authenticate_user(username, password)
        
        if result is None:
            self._send_response(401, {"error": "Invalid credentials"})
        else:
            session_id = result.pop('session_id')  # Don't send session_id to client directly
            self._send_response(200, result, f'session_id={session_id}')
    
    def _handle_logout(self) -> None:
        session_id = self._get_session_id()
        if not session_id:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        success = TodoServer.auth_manager.logout(session_id)
        if not success:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        self._send_response(200, {})
    
    def _handle_change_password(self) -> None:
        session_id = self._get_session_id()
        if not session_id:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        user_info = TodoServer.auth_manager.get_user_from_session(session_id)
        if not user_info:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        body = self._parse_json_body()
        if not body:
            self._send_response(400, {"error": "Invalid JSON"})
            return
        
        old_password = body.get('old_password')
        new_password = body.get('new_password')
        
        if not old_password or not new_password:
            self._send_response(400, {"error": "Missing old_password or new_password"})
            return
        
        result = TodoServer.auth_manager.change_password(session_id, old_password, new_password)
        
        if result and 'error' in result:
            if result["error"] == "Password too short":
                self._send_response(400, result)
            else:  # Invalid credentials
                self._send_response(401, result)
        else:
            self._send_response(200, {})
    
    def _handle_create_todo(self) -> None:
        session_id = self._get_session_id()
        if not session_id:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        user_info = TodoServer.auth_manager.get_user_from_session(session_id)
        if not user_info:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        body = self._parse_json_body()
        if not body:
            self._send_response(400, {"error": "Invalid JSON"})
            return
        
        title = body.get('title')
        if not title or title.strip() == '':
            self._send_response(400, {"error": "Title is required"})
            return
        
        description = body.get('description', '')
        
        todo = TodoServer.todo_manager.create_todo(user_info['id'], title, description)
        self._send_response(201, todo)
    
    def do_GET(self) -> None:
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/me':
            self._handle_get_me()
        
        elif parsed_path.path == '/todos':
            self._handle_get_todos()
        
        elif parsed_path.path.startswith('/todos/'):
            todo_id_str = parsed_path.path[len('/todos/'):]
            try:
                # Handle trailing slashes (e.g., /todos/123/)
                if todo_id_str.endswith('/'):
                    todo_id_str = todo_id_str[:-1]
                
                todo_id = int(todo_id_str)
                self._handle_get_todo(todo_id)
            except ValueError:
                self._send_response(404, {"error": "Not found"})
        
        else:
            self._send_response(404, {"error": "Not found"})
    
    def _handle_get_me(self) -> None:
        session_id = self._get_session_id()
        if not session_id:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        user_info = TodoServer.auth_manager.get_user_from_session(session_id)
        if not user_info:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        self._send_response(200, user_info)
    
    def _handle_get_todos(self) -> None:
        session_id = self._get_session_id()
        if not session_id:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        user_info = TodoServer.auth_manager.get_user_from_session(session_id)
        if not user_info:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        todos = TodoServer.todo_manager.get_todos_for_user(user_info['id'])
        self._send_response(200, todos)
    
    def _handle_get_todo(self, todo_id: int) -> None:
        session_id = self._get_session_id()
        if not session_id:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        user_info = TodoServer.auth_manager.get_user_from_session(session_id)
        if not user_info:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        todo = TodoServer.todo_manager.get_todo(todo_id, user_info['id'])
        if not todo:
            self._send_response(404, {"error": "Todo not found"})
            return
        
        self._send_response(200, todo)
    
    def do_PUT(self) -> None:
        parsed_path = urlparse(self.path)
        
        if parsed_path.path.startswith('/todos/'):
            todo_id_str = parsed_path.path[len('/todos/'):]
            try:
                # Handle trailing slashes (e.g., /todos/123/)
                if todo_id_str.endswith('/'):
                    todo_id_str = todo_id_str[:-1]
                
                todo_id = int(todo_id_str)
                self._handle_update_todo(todo_id)
            except ValueError:
                self._send_response(404, {"error": "Not found"})
        
        elif parsed_path.path == '/password':
            self._handle_change_password()
        
        else:
            self._send_response(404, {"error": "Not found"})
    
    def _handle_update_todo(self, todo_id: int) -> None:
        session_id = self._get_session_id()
        if not session_id:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        user_info = TodoServer.auth_manager.get_user_from_session(session_id)
        if not user_info:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        body = self._parse_json_body()
        if not body:
            self._send_response(400, {"error": "Invalid JSON"})
            return
        
        result = TodoServer.todo_manager.update_todo(todo_id, user_info['id'], body)
        
        if not result:
            self._send_response(404, {"error": "Todo not found"})
        elif isinstance(result, dict) and 'error' in result:
            self._send_response(400, result)
        else:
            self._send_response(200, result)
    
    def do_DELETE(self) -> None:
        parsed_path = urlparse(self.path)
        
        if parsed_path.path.startswith('/todos/'):
            todo_id_str = parsed_path.path[len('/todos/'):]
            try:
                # Handle trailing slashes (e.g., /todos/123/)
                if todo_id_str.endswith('/'):
                    todo_id_str = todo_id_str[:-1]
                
                todo_id = int(todo_id_str)
                self._handle_delete_todo(todo_id)
            except ValueError:
                self._send_response(404, {"error": "Not found"})
        
        else:
            self._send_response(404, {"error": "Not found"})
    
    def _handle_delete_todo(self, todo_id: int) -> None:
        session_id = self._get_session_id()
        if not session_id:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        user_info = TodoServer.auth_manager.get_user_from_session(session_id)
        if not user_info:
            self._send_response(401, {"error": "Authentication required"})
            return
        
        success = TodoServer.todo_manager.delete_todo(todo_id, user_info['id'])
        
        if success:
            self._send_response(204, "")  # No content for successful deletion
        else:
            self._send_response(404, {"error": "Todo not found"})


def run_server(port: int) -> None:
    # Initialize managers
    auth_manager = AuthManager()
    todo_manager = TodoManager()
    
    # Assign to class attributes so instance methods can access them
    TodoServer.auth_manager = auth_manager
    TodoServer.todo_manager = todo_manager
    
    server_address = ('0.0.0.0', port)
    httpd = HTTPServer(server_address, TodoServer)
    print(f"Starting server on {server_address[0]}:{server_address[1]}")
    httpd.serve_forever()


if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='Todo API Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to listen on')
    args = parser.parse_args()
    
    run_server(args.port)