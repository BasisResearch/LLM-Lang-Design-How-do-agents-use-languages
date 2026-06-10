#!/usr/bin/env python3
import json
import uuid
import hashlib
from datetime import datetime, timezone
import re
import sys
import argparse
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs


class TodoAppServer(BaseHTTPRequestHandler):
    # Class-level storage (shared across all instances)
    _initialized = False
    
    @classmethod
    def initialize_storage(cls):
        if not cls._initialized:
            cls.users = {}
            cls.todos = {}
            cls.passwords = {}  # Store password hashes {user_id: hashed_password}
            cls.sessions = {}   # Store valid session tokens {session_id: user_id}
            cls.next_user_id = 1
            cls.next_todo_id = 1
            cls._initialized = True
    
    def setup(self):
        self.initialize_storage()  # Ensure storage is initialized
        super().setup()
    
    def do_POST(self):
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/register':
            self.register()
        elif parsed_path.path == '/login':
            self.login()
        elif parsed_path.path == '/logout':
            self.logout()
        elif parsed_path.path == '/password':
            self.change_password()
        elif parsed_path.path == '/todos':
            self.create_todo()
        else:
            self.send_error(404, 'Not Found')
    
    def do_GET(self):
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/me':
            self.get_current_user()
        elif parsed_path.path == '/todos':
            self.get_todos()
        elif parsed_path.path.startswith('/todos/'):
            todo_id = parsed_path.path.split('/')[-1]
            if todo_id.isdigit():
                self.get_todo(int(todo_id))
            else:
                self.send_error(404, 'Not Found')
        else:
            self.send_error(404, 'Not Found')
    
    def do_PUT(self):
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/password':
            self.change_password()
        elif parsed_path.path.startswith('/todos/'):
            todo_id = parsed_path.path.split('/')[-1]
            if todo_id.isdigit():
                self.update_todo(int(todo_id))
            else:
                self.send_error(404, 'Not Found')
        else:
            self.send_error(404, 'Not Found')
    
    def do_DELETE(self):
        parsed_path = urlparse(self.path)
        
        if parsed_path.path.startswith('/todos/'):
            todo_id = parsed_path.path.split('/')[-1]
            if todo_id.isdigit():
                self.delete_todo(int(todo_id))
            else:
                self.send_error(404, 'Not Found')
        else:
            self.send_error(404, 'Not Found')
    
    def send_json_response(self, status_code, data, headers=None):
        """Send a JSON response"""
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        if headers:
            for key, value in headers.items():
                self.send_header(key, value)
        self.end_headers()
        if data is not None:
            self.wfile.write(json.dumps(data).encode())
    
    def send_error_response(self, status_code, message):
        """Send an error response"""
        self.send_json_response(status_code, {'error': message})
    
    def get_body(self):
        """Get request body as JSON"""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length > 0:
            body = self.rfile.read(content_length).decode('utf-8')
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                return None
        return None
    
    def get_session_user_id(self):
        """Extract session user ID from cookie"""
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return None
        
        cookies = {}
        for cookie in cookie_header.split(';'):
            cookie = cookie.strip()
            if '=' in cookie:
                name, value = cookie.split('=', 1)
                cookies[name] = value
        
        session_id = cookies.get('session_id')
        if not session_id or session_id not in self.__class__.sessions:
            return None
        
        return self.__class__.sessions[session_id]
    
    def require_auth(self):
        """Check if request has valid authentication"""
        user_id = self.get_session_user_id()
        if user_id is None:
            self.send_error_response(401, 'Authentication required')
            return None
        return user_id
    
    def validate_username(self, username):
        """Validate username format"""
        if not username or len(username) < 3 or len(username) > 50:
            return False
        # Only allow alphanumeric and underscore characters
        if not re.match(r'^[a-zA-Z0-9_]+$', username):
            return False
        return True
    
    def hash_password(self, password):
        """Simple hashing for password (for demonstration)"""
        return hashlib.sha256(password.encode()).hexdigest()
    
    def register(self):
        """Register a new user"""
        data = self.get_body()
        if not data:
            self.send_error_response(400, 'Invalid JSON')
            return
        
        username = data.get('username')
        password = data.get('password')
        
        if not username:
            self.send_error_response(400, 'Invalid username')
            return
            
        if not self.validate_username(username):
            self.send_error_response(400, 'Invalid username')
            return
        
        if not password or len(password) < 8:
            self.send_error_response(400, 'Password too short')
            return
        
        # Check if username already exists
        for existing_user_id, existing_username in self.__class__.users.items():
            if existing_username == username:
                self.send_error_response(409, 'Username already exists')
                return
        
        # Create new user
        user_id = self.__class__.next_user_id
        self.__class__.users[user_id] = username
        self.__class__.passwords[user_id] = self.hash_password(password)
        self.__class__.next_user_id += 1
        
        new_user = {
            'id': user_id,
            'username': username
        }
        
        self.send_json_response(201, new_user)
    
    def login(self):
        """Login user and generate session"""
        data = self.get_body()
        if not data:
            self.send_error_response(400, 'Invalid JSON')
            return
        
        username = data.get('username')
        password = data.get('password')
        
        # Find user by username
        user_id = None
        for uid, uname in self.__class__.users.items():
            if uname == username:
                user_id = uid
                break
        
        # Validate user exists and password matches
        if user_id is None or self.__class__.passwords.get(user_id) != self.hash_password(password):
            self.send_error_response(401, 'Invalid credentials')
            return
        
        # Generate session token
        session_token = str(uuid.uuid4())
        self.__class__.sessions[session_token] = user_id
        
        # Prepare response
        user_info = {
            'id': user_id,
            'username': username
        }
        
        # Set cookie and respond
        headers = {
            'Set-Cookie': f'session_id={session_token}; Path=/; HttpOnly'
        }
        self.send_json_response(200, user_info, headers)
    
    def logout(self):
        """Logout user by invalidating session"""
        user_id = self.require_auth()
        if user_id is None:
            return  # Response already sent by require_auth
        
        # Extract the session_id from the request cookies
        session_cookie = None
        cookie_header = self.headers.get('Cookie')
        if cookie_header:
            cookies = {}
            for cookie in cookie_header.split(';'):
                cookie = cookie.strip()
                if '=' in cookie:
                    name, value = cookie.split('=', 1)
                    cookies[name] = value
            session_cookie = cookies.get('session_id')
        
        if session_cookie and session_cookie in self.__class__.sessions:
            del self.__class__.sessions[session_cookie]
        
        self.send_json_response(200, {})
    
    def change_password(self):
        """Change user password if correct old password provided"""
        user_id = self.require_auth()
        if user_id is None:
            return
        
        data = self.get_body()
        if not data:
            self.send_error_response(400, 'Invalid JSON')
            return
        
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        
        if not old_password or not new_password or len(new_password) < 8:
            if not new_password or len(new_password) < 8:
                self.send_error_response(400, 'Password too short')
                return
            # Old password validation will happen below
        
        # Check if old password is correct
        if self.__class__.passwords.get(user_id) != self.hash_password(old_password):
            self.send_error_response(401, 'Invalid credentials')
            return
        
        # Update password
        self.__class__.passwords[user_id] = self.hash_password(new_password)
        self.send_json_response(200, {})
    
    def get_current_user(self):
        """Get information about currently authenticated user"""
        user_id = self.require_auth()
        if user_id is None:
            return
        
        username = self.__class__.users.get(user_id)
        if not username:
            self.send_error_response(401, 'Authentication required')
            return
        
        res = {
            'id': user_id,
            'username': username
        }
        self.send_json_response(200, res)
    
    def create_todo(self):
        """Create a new todo item for the logged in user"""
        user_id = self.require_auth()
        if user_id is None:
            return
        
        data = self.get_body()
        if not data:
            self.send_error_response(400, 'Invalid JSON')
            return
        
        title = data.get('title')
        description = data.get('description', '')
        
        if not title:
            self.send_error_response(400, 'Title is required')
            return
        
        now_str = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        
        todo = {
            'id': self.__class__.next_todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now_str,
            'updated_at': now_str
        }
        
        # Store the todo with user reference
        todo_id = self.__class__.next_todo_id
        self.__class__.todos[todo_id] = {
            'owner': user_id,
            'data': todo
        }
        self.__class__.next_todo_id += 1
        
        self.send_json_response(201, todo)
    
    def get_todos(self):
        """Get all todos for currently authenticated user"""
        user_id = self.require_auth()
        if user_id is None:
            return
        
        user_todos = []
        for todo_id, todo_data in self.__class__.todos.items():
            if todo_data['owner'] == user_id:
                user_todos.append(todo_data['data'])
        
        # Sort by ID (ascending)
        user_todos.sort(key=lambda x: x['id'])
        
        self.send_json_response(200, user_todos)
    
    def get_todo(self, todo_id):
        """Get a specific todo by ID if it belongs to the authenticated user"""
        user_id = self.require_auth()
        if user_id is None:
            return
        
        if todo_id not in self.__class__.todos:
            self.send_error_response(404, 'Todo not found')
            return
        
        todo_data = self.__class__.todos[todo_id]
        todo_owner = todo_data['owner']
        if todo_owner != user_id:
            self.send_error_response(404, 'Todo not found')
            return
        
        self.send_json_response(200, todo_data['data'])
    
    def update_todo(self, todo_id):
        """Update a specific todo if it belongs to the authenticated user"""
        user_id = self.require_auth()
        if user_id is None:
            return
        
        if todo_id not in self.__class__.todos:
            self.send_error_response(404, 'Todo not found')
            return
        
        todo_data = self.__class__.todos[todo_id]
        todo_owner = todo_data['owner']
        if todo_owner != user_id:
            self.send_error_response(404, 'Todo not found')
            return
        
        data = self.get_body()
        if not data:
            self.send_error_response(400, 'Invalid JSON')
            return
        
        # Get existing todo to modify
        current_todo = todo_data['data']
        
        # Apply updates for fields that are present in the request
        for field in ['title', 'description', 'completed']:
            if field in data:
                current_todo[field] = data[field]
        
        # Check if title is present and empty
        if 'title' in data and not current_todo['title']:
            self.send_error_response(400, 'Title is required')
            return
        
        # Update timestamps
        now_str = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        current_todo['updated_at'] = now_str
        
        self.send_json_response(200, current_todo)
    
    def delete_todo(self, todo_id):
        """Delete a specific todo if it belongs to the authenticated user"""
        user_id = self.require_auth()
        if user_id is None:
            return
        
        if todo_id not in self.__class__.todos:
            self.send_error_response(404, 'Todo not found')
            return
        
        todo_data = self.__class__.todos[todo_id]
        todo_owner = todo_data['owner']
        if todo_owner != user_id:
            self.send_error_response(404, 'Todo not found')
            return
        
        del self.__class__.todos[todo_id]
        self.send_response(204)
        self.end_headers()


def run_server(port=8080):
    TodoAppServer.initialize_storage()  # Initialize storage when server starts
    print(f"Starting server on 0.0.0.0:{port}")
    server = HTTPServer(('0.0.0.0', port), TodoAppServer)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Server stopped")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, default=8080, help='Port to listen on')
    
    args = parser.parse_args()
    
    run_server(args.port)