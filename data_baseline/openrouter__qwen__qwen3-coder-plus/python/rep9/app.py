import json
import uuid
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import re
import hashlib
import argparse


class TodoAppServer:
    # Class-level storage for all instances
    users = {}
    sessions = {}  # session_id -> user_id
    todos = {}  # user_id -> [todos]
    next_user_id = 1
    next_todo_id = 1
    
    def __init__(self):
        # Initialize data structures once at class level
        pass


class RequestHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.handle_request('GET')
        
    def do_POST(self):
        self.handle_request('POST')
        
    def do_PUT(self):
        self.handle_request('PUT')
        
    def do_DELETE(self):
        self.handle_request('DELETE')
        
    def handle_request(self, method):
        try:
            parsed_path = urlparse(self.path)
            path_parts = parsed_path.path.strip('/').split('/')
            
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else ''
            
            # Handle different endpoints
            response_data = self.route_request(method, path_parts, body)
            
            # Prepare response
            status_code = response_data.get('status', 200)
            response_body = response_data.get('body', '')
            headers = response_data.get('headers', {})
            
            self.send_response(status_code)
            
            # Set Content-Type for all responses except DELETE
            if method != 'DELETE' or status_code != 204:
                self.send_header('Content-Type', 'application/json')
                
            # Add custom headers
            for key, value in headers.items():
                self.send_header(key, value)
            self.end_headers()
            
            if response_body and response_body is not None:
                self.wfile.write(json.dumps(response_body).encode('utf-8'))
                
        except Exception as e:
            print(f"Error handling request: {e}")
            self.send_error(500, str(e))
    
    def route_request(self, method, path_parts, body):
        # Extract session_id from cookies
        session_id = None
        cookie_header = self.headers.get('Cookie')
        if cookie_header:
            cookies = parse_cookies(cookie_header)
            session_id = cookies.get('session_id')
        
        # Check if path matches specific routes
        if path_parts[0] == 'register' and method == 'POST':
            return self.handle_register(body)
        elif path_parts[0] == 'login' and method == 'POST':
            return self.handle_login(body)
        elif path_parts[0] == 'logout' and method == 'POST':
            return self.handle_logout(session_id)
        elif path_parts[0] == 'me' and method == 'GET':
            user_id = self.verify_session(session_id)
            if user_id is None:
                return unauthorized_response()
            return self.handle_get_me(user_id)
        elif path_parts[0] == 'password' and method == 'PUT':
            user_id = self.verify_session(session_id)
            if user_id is None:
                return unauthorized_response()
            return self.handle_update_password(user_id, body)
        elif path_parts[0] == 'todos':
            # Determine if it's related to todos
            if len(path_parts) == 1:  # /todos
                if method == 'GET':
                    user_id = self.verify_session(session_id)
                    if user_id is None:
                        return unauthorized_response()
                    return self.handle_get_todos(user_id)
                elif method == 'POST':
                    user_id = self.verify_session(session_id)
                    if user_id is None:
                        return unauthorized_response()
                    return self.handle_create_todo(user_id, body)
            elif len(path_parts) == 2:  # /todos/:id
                try:
                    todo_id = int(path_parts[1])
                    user_id = self.verify_session(session_id)
                    if user_id is None:
                        return unauthorized_response()
                    
                    if method == 'GET':
                        return self.handle_get_todo(user_id, todo_id)
                    elif method == 'PUT':
                        return self.handle_update_todo(user_id, todo_id, body)
                    elif method == 'DELETE':
                        return self.handle_delete_todo(user_id, todo_id)
                except ValueError:
                    return {'status': 400, 'body': {'error': 'Invalid todo ID'}}
        
        # Route not found
        return {'status': 404, 'body': {'error': 'Not found'}}
    
    def _get_timestamp(self):
        """Generate an ISO 8601 UTC timestamp"""
        return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    
    def _hash_password(self, password):
        """Hash a password using SHA-256"""
        return hashlib.sha256(password.encode()).hexdigest()
    
    def verify_session(self, session_id):
        """Verify session token and return associated user_id, or None if invalid/expired"""
        if session_id and session_id in TodoAppServer.sessions:
            return TodoAppServer.sessions[session_id]
        return None
    
    def handle_register(self, body):
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return {'status': 400, 'body': {'error': 'Invalid JSON'}}
        
        username = data.get('username')
        password = data.get('password')
        
        # Validate input
        if not username:
            return {'status': 400, 'body': {'error': 'Invalid username'}}
        
        if not isinstance(username, str) or len(username) < 3 or len(username) > 50:
            return {'status': 400, 'body': {'error': 'Invalid username'}}
        
        if not re.match(r'^[a-zA-Z0-9_]+$', username):
            return {'status': 400, 'body': {'error': 'Invalid username'}}
        
        if not password:
            return {'status': 400, 'body': {'error': 'Password too short'}}
        
        if len(password) < 8:
            return {'status': 400, 'body': {'error': 'Password too short'}}
        
        # Check if username already exists
        existing_user = next((user for user in TodoAppServer.users.values() if user['username'] == username), None)
        if existing_user:
            return {'status': 409, 'body': {'error': 'Username already exists'}}
        
        # Create new user
        user_id = TodoAppServer.next_user_id
        TodoAppServer.next_user_id += 1
        
        hashed_password = self._hash_password(password)
        user = {
            'id': user_id,
            'username': username,
            'password': hashed_password
        }
        
        TodoAppServer.users[user_id] = user
        TodoAppServer.todos[user_id] = []  # Initialize user's todo list
        
        return {
            'status': 201,
            'body': {
                'id': user_id,
                'username': username
            }
        }
    
    def handle_login(self, body):
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return {'status': 400, 'body': {'error': 'Invalid JSON'}}
        
        username = data.get('username')
        password = data.get('password')
        
        # Find user
        user = None
        for u in TodoAppServer.users.values():
            if u['username'] == username:
                user = u
                break
        
        if not user:
            return {'status': 401, 'body': {'error': 'Invalid credentials'}}
        
        # Verify password
        hashed_password = self._hash_password(password)
        if user['password'] != hashed_password:
            return {'status': 401, 'body': {'error': 'Invalid credentials'}}
        
        # Create a new session
        session_id = uuid.uuid4().hex
        TodoAppServer.sessions[session_id] = user['id']
        
        return {
            'status': 200,
            'body': {
                'id': user['id'],
                'username': user['username']
            },
            'headers': {
                'Set-Cookie': f'session_id={session_id}; Path=/; HttpOnly'
            }
        }
    
    def handle_logout(self, session_id):
        if session_id in TodoAppServer.sessions:
            del TodoAppServer.sessions[session_id]
        
        return {
            'status': 200,
            'body': {}
        }
    
    def handle_get_me(self, user_id):
        user = TodoAppServer.users.get(user_id)
        if not user:
            return {'status': 401, 'body': {'error': 'User not found'}}
        
        return {
            'status': 200,
            'body': {
                'id': user['id'],
                'username': user['username']
            }
        }
    
    def handle_update_password(self, user_id, body):
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return {'status': 400, 'body': {'error': 'Invalid JSON'}}
        
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        
        user = TodoAppServer.users.get(user_id)
        if not user:
            return {'status': 401, 'body': {'error': 'User not found'}}
        
        # Verify old password
        old_hashed = self._hash_password(old_password)
        if user['password'] != old_hashed:
            return {'status': 401, 'body': {'error': 'Invalid credentials'}}
        
        # Validate new password
        if not new_password or len(new_password) < 8:
            return {'status': 400, 'body': {'error': 'Password too short'}}
        
        # Update password
        user['password'] = self._hash_password(new_password)
        
        return {
            'status': 200,
            'body': {}
        }
    
    def handle_get_todos(self, user_id):
        user_todos = TodoAppServer.todos.get(user_id, [])
        
        return {
            'status': 200,
            'body': user_todos
        }
    
    def handle_create_todo(self, user_id, body):
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return {'status': 400, 'body': {'error': 'Invalid JSON'}}
        
        title = data.get('title')
        
        if not title or len(title.strip()) == 0:
            return {'status': 400, 'body': {'error': 'Title is required'}}
        
        description = data.get('description', '')
        
        # Create new todo
        todo_id = TodoAppServer.next_todo_id
        TodoAppServer.next_todo_id += 1
        
        now = self._get_timestamp()
        todo = {
            'id': todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now,
            'updated_at': now
        }
        
        TodoAppServer.todos[user_id].append(todo)
        
        return {
            'status': 201,
            'body': todo
        }
    
    def handle_get_todo(self, user_id, todo_id):
        # Find the todo in user's list
        user_todos = TodoAppServer.todos.get(user_id, [])
        todo = next((t for t in user_todos if t['id'] == todo_id), None)
        
        if not todo:
            return {'status': 404, 'body': {'error': 'Todo not found'}}
        
        return {
            'status': 200,
            'body': todo
        }
    
    def handle_update_todo(self, user_id, todo_id, body):
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return {'status': 400, 'body': {'error': 'Invalid JSON'}}
        
        # Find the todo in user's list
        user_todos = TodoAppServer.todos.get(user_id, [])
        todo_index = -1
        for i, t in enumerate(user_todos):
            if t['id'] == todo_id:
                todo_index = i
                break
        
        if todo_index == -1:
            return {'status': 404, 'body': {'error': 'Todo not found'}}
        
        todo = user_todos[todo_index]
        
        # Validate title if provided
        if 'title' in data:
            new_title = data['title']
            if not new_title or len(new_title.strip()) == 0:
                return {'status': 400, 'body': {'error': 'Title is required'}}
        
        # Apply updates (only fields present in the request body)
        if 'title' in data:
            todo['title'] = data['title']
        if 'description' in data:
            todo['description'] = data['description']
        if 'completed' in data:
            todo['completed'] = data['completed']
        
        # Update the timestamp
        todo['updated_at'] = self._get_timestamp()
        
        # Update the todo in place
        user_todos[todo_index] = todo
        
        return {
            'status': 200,
            'body': todo
        }
    
    def handle_delete_todo(self, user_id, todo_id):
        # Find the todo in user's list
        user_todos = TodoAppServer.todos.get(user_id, [])
        original_len = len(user_todos)
        filtered_todos = [t for t in user_todos if t['id'] != todo_id]
        
        # If the length didn't change, the todo wasn't there
        if len(filtered_todos) == original_len:
            return {'status': 404, 'body': {'error': 'Todo not found'}}
        
        # Update the user's todo list
        TodoAppServer.todos[user_id] = filtered_todos
        
        return {
            'status': 204,
            'body': None  # no body for 204 (No Content)
        }


def unauthorized_response():
    return {
        'status': 401,
        'body': {'error': 'Authentication required'}
    }


def parse_cookies(cookie_str):
    """Parse cookie string into a dictionary"""
    cookies = {}
    if cookie_str:
        pairs = cookie_str.split(';')
        for pair in pairs:
            pair = pair.strip()
            if '=' in pair:
                k, v = pair.split('=', 1)
                cookies[k] = v
    return cookies


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8000)
    args = parser.parse_args()
    
    server = HTTPServer(('0.0.0.0', args.port), RequestHandler)
    print(f'Server starting on 0.0.0.0:{args.port}')
    server.serve_forever()