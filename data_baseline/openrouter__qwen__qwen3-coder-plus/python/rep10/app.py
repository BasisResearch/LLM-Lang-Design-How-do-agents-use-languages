import json
import uuid
import re
import hashlib
from datetime import datetime
from http.cookies import SimpleCookie
from urllib.parse import urlparse, parse_qs
from http.server import HTTPServer, BaseHTTPRequestHandler


class TodoAppHandler(BaseHTTPRequestHandler):
    # In-memory storage
    users = {}
    sessions = {}  # session_id -> user_id mapping
    todos = {}     # user_id -> {todo_id -> todo_object}

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

    def get_session_user(self):
        """Extract user information from session cookie"""
        if 'Cookie' not in self.headers:
            return None
        
        cookie_header = self.headers['Cookie']
        cookie = SimpleCookie()
        cookie.load(cookie_header)
        
        if 'session_id' not in cookie:
            return None
        
        session_token = cookie['session_id'].value
        if session_token not in self.sessions:
            return None
        
        return self.sessions[session_token]

    def send_json_response(self, status_code, response_data, has_body=True):
        """Send JSON response with appropriate headers"""
        self.send_response(status_code)
        if has_body:
            self.send_header('Content-Type', 'application/json')
        self.end_headers()
        
        if has_body and response_data:
            response_json = json.dumps(response_data)
            self.wfile.write(response_json.encode('utf-8'))

    def read_json_request(self):
        """Read JSON data from request body"""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        else:
            body = self.rfile.read(content_length).decode('utf-8')
            try:
                return json.loads(body)
            except json.JSONDecodeError:
                return None

    def ensure_user_todos_storage(self, user_id):
        """Ensure that a user has a todos dictionary in storage"""
        if user_id not in self.todos:
            self.todos[user_id] = {}

    def generate_timestamp(self):
        """Generate ISO 8601 timestamp with second precision"""
        return datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')

    def create_session(self, user_id):
        """Create a new session for a user"""
        session_token = str(uuid.uuid4())
        self.sessions[session_token] = user_id
        return session_token

    def validate_username(self, username):
        """Validate username according to rules"""
        if not username:
            return False
        if len(username) < 3 or len(username) > 50:
            return False
        if not re.match(r'^[a-zA-Z0-9_]+$', username):
            return False
        return True

    def validate_password(self, password):
        """Validate password is at least 8 chars"""
        return len(password) >= 8

    def authenticate_user(self, data):
        """Check if login credentials are valid"""
        if 'username' not in data or 'password' not in data:
            return None

        username = data['username']
        password = data['password']

        for user_id, user_info in self.users.items():
            if user_info['username'] == username:
                # Hash the provided password and compare with stored hash
                password_hash = hashlib.sha256(password.encode()).hexdigest()
                if user_info['password_hash'] == password_hash:
                    return user_info
        return None

    def handle_register(self):
        """Handle user registration"""
        data = self.read_json_request()
        if not data:
            self.send_json_response(400, {'error': 'Invalid JSON'})
            return

        # Validate fields exist
        if 'username' not in data or 'password' not in data:
            self.send_json_response(400, {'error': 'Missing username or password'})
            return

        username = data['username']
        password = data['password']

        # Validate username
        if not self.validate_username(username):
            self.send_json_response(400, {'error': 'Invalid username'})
            return

        # Validate password length
        if not self.validate_password(password):
            self.send_json_response(400, {'error': 'Password too short'})
            return

        # Check if username already exists
        for user in self.users.values():
            if user['username'] == username:
                self.send_json_response(409, {'error': 'Username already exists'})
                return

        # Generate new user ID (auto-increment starting at 1)
        user_id = max([int(id) for id in self.users.keys()] or [0]) + 1

        # Store the user (with hashed password)
        hashed_password = hashlib.sha256(password.encode()).hexdigest()
        self.users[user_id] = {
            'id': user_id,
            'username': username,
            'password_hash': hashed_password
        }
        
        # Create a dict to hold this user's todos
        self.ensure_user_todos_storage(user_id)

        self.send_json_response(201, {
            'id': user_id,
            'username': username
        })

    def handle_login(self):
        """Handle user login"""
        data = self.read_json_request()
        if not data:
            self.send_json_response(400, {'error': 'Invalid JSON'})
            return

        user_info = self.authenticate_user(data)
        
        if not user_info:
            self.send_json_response(401, {'error': 'Invalid credentials'})
            return
        
        session_token = self.create_session(user_info['id'])
        
        # Set cookie in response
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Set-Cookie', f'session_id={session_token}; Path=/; HttpOnly')
        self.end_headers()
        
        response_data = {
            'id': user_info['id'],
            'username': user_info['username']
        }
        self.wfile.write(json.dumps(response_data).encode('utf-8'))

    def handle_logout(self):
        """Handle user logout"""
        user_info = self.get_session_user()
        if not user_info:
            self.send_json_response(401, {'error': 'Authentication required'})
            return

        # Find and remove the session
        session_token = None
        for token, stored_user_id in self.sessions.items():
            if stored_user_id == user_info:
                session_token = token
                break

        if session_token:
            del self.sessions[session_token]

        self.send_json_response(200, {})

    def handle_get_me(self):
        """Get current user info"""
        user_info = self.get_session_user()
        if not user_info:
            self.send_json_response(401, {'error': 'Authentication required'})
            return

        # Find the actual user object based on user ID
        user_obj = self.users.get(user_info)
        if not user_obj:
            self.send_json_response(401, {'error': 'Authentication required'})
            return
            
        self.send_json_response(200, {
            'id': user_obj['id'],
            'username': user_obj['username']
        })

    def handle_change_password(self):
        """Change password"""
        user_id = self.get_session_user()
        if not user_id:
            self.send_json_response(401, {'error': 'Authentication required'})
            return

        data = self.read_json_request()
        if not data:
            self.send_json_response(400, {'error': 'Invalid JSON'})
            return

        if 'old_password' not in data or 'new_password' not in data:
            self.send_json_response(400, {'error': 'Missing old_password or new_password'})
            return

        old_password = data['old_password']
        new_password = data['new_password']

        # Verify old password
        user_obj = self.users.get(user_id)
        old_password_hash = hashlib.sha256(old_password.encode()).hexdigest()
        if user_obj['password_hash'] != old_password_hash:
            self.send_json_response(401, {'error': 'Invalid credentials'})
            return

        # Validate new password length
        if not self.validate_password(new_password):
            self.send_json_response(400, {'error': 'Password too short'})
            return

        # Update password
        new_password_hash = hashlib.sha256(new_password.encode()).hexdigest()
        user_obj['password_hash'] = new_password_hash

        self.send_json_response(200, {})

    def handle_get_todos(self):
        """Get all todos for the current user"""
        user_id = self.get_session_user()
        if not user_id:
            self.send_json_response(401, {'error': 'Authentication required'})
            return

        # Get user's todos
        user_todos = self.todos.get(user_id, {})
        
        # Sort by ID
        sorted_todos = [user_todos[todo_id] for todo_id in sorted(user_todos.keys(), key=int)]
        
        self.send_json_response(200, sorted_todos)

    def handle_create_todo(self):
        """Create a new todo"""
        user_id = self.get_session_user()
        if not user_id:
            self.send_json_response(401, {'error': 'Authentication required'})
            return

        data = self.read_json_request()
        if not data:
            self.send_json_response(400, {'error': 'Invalid JSON'})
            return

        if 'title' not in data:
            self.send_json_response(400, {'error': 'Title is required'})
            return

        title = data['title']
        description = data.get('description', '')

        if not title:
            self.send_json_response(400, {'error': 'Title is required'})
            return

        # Ensure user's todo storage exists
        self.ensure_user_todos_storage(user_id)

        # Generate new todo ID (auto-increment starting at 1)
        user_todos = self.todos[user_id]
        new_todo_id = max([int(id) for id in user_todos.keys()] or [0]) + 1

        now_ts = self.generate_timestamp()
        new_todo = {
            'id': new_todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now_ts,
            'updated_at': now_ts
        }

        # Key MUST be a string to match with the route parsing result
        user_todos[str(new_todo_id)] = new_todo

        self.send_json_response(201, new_todo)

    def handle_get_todo(self, todo_id):
        """Get a specific todo"""
        user_id = self.get_session_user()
        if not user_id:
            self.send_json_response(401, {'error': 'Authentication required'})
            return

        user_todos = self.todos.get(user_id, {})

        if todo_id not in user_todos:  # keep it as a string, since URL gives us a string
            self.send_json_response(404, {'error': 'Todo not found'})
            return

        todo = user_todos[todo_id]  # todo_id is string from URL parsing
        self.send_json_response(200, todo)

    def handle_update_todo(self, todo_id):
        """Update a specific todo (partial update)"""
        user_id = self.get_session_user()
        if not user_id:
            self.send_json_response(401, {'error': 'Authentication required'})
            return

        user_todos = self.todos.get(user_id, {})

        if todo_id not in user_todos:  # keep it as a string, since URL gives us a string
            self.send_json_response(404, {'error': 'Todo not found'})
            return

        data = self.read_json_request()
        if not data:
            self.send_json_response(400, {'error': 'Invalid JSON'})
            return

        # Get current todo
        todo = user_todos[todo_id]  # todo_id is string from URL parsing

        # Update fields if they exist in request
        if 'title' in data:
            title = data['title']
            if not title.strip():  # Empty after stripping whitespace
                self.send_json_response(400, {'error': 'Title is required'})
                return
            todo['title'] = title

        if 'description' in data:
            todo['description'] = data['description']

        if 'completed' in data:
            completed = data['completed']
            if not isinstance(completed, bool):
                self.send_json_response(400, {'error': 'Completed must be boolean'})
                return
            todo['completed'] = completed

        # Update updated_at
        todo['updated_at'] = self.generate_timestamp()

        self.send_json_response(200, todo)

    def handle_delete_todo(self, todo_id):
        """Delete a specific todo"""
        user_id = self.get_session_user()
        if not user_id:
            self.send_json_response(401, {'error': 'Authentication required'})
            return

        user_todos = self.todos.get(user_id, {})

        if todo_id not in user_todos:  # keep it as a string, since URL gives us a string
            self.send_json_response(404, {'error': 'Todo not found'})
            return

        del user_todos[todo_id]  # todo_id is string from URL parsing
        self.send_response(204)  # No content
        self.end_headers()

    def route_request(self):
        """Route the incoming request to the appropriate handler"""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        query_params = parse_qs(parsed_path.query)

        method = self.command
        resource = path_parts[0] if path_parts[0] else 'root'

        # Extract ID if present (from paths like /todos/ID)
        todo_id = path_parts[1] if len(path_parts) > 1 else None

        try:
            if method == 'POST':
                if resource == 'register':
                    return self.handle_register()
                elif resource == 'login':
                    return self.handle_login()
                elif resource == 'logout':
                    return self.handle_logout()
                elif resource == 'todos':
                    return self.handle_create_todo()
                # No POST password endpoint, it's PUT
            elif method == 'GET':
                if resource == 'me':
                    return self.handle_get_me()
                elif resource == 'todos':
                    if todo_id:
                        return self.handle_get_todo(todo_id)
                    else:
                        return self.handle_get_todos()
            elif method == 'PUT':
                if resource == 'password':
                    return self.handle_change_password()
                elif resource == 'todos' and todo_id:
                    return self.handle_update_todo(todo_id)
            elif method == 'DELETE':
                if resource == 'todos' and todo_id:
                    return self.handle_delete_todo(todo_id)
        except Exception as e:
            # Log the error for debugging
            print(f"Error handling request: {str(e)}")
            self.send_json_response(500, {'error': 'Internal server error'})

        # If we reach here, the path/command combination was not matched
        self.send_json_response(404, {'error': 'Not found'})

    def do_POST(self):
        self.route_request()

    def do_GET(self):
        self.route_request()

    def do_PUT(self):
        self.route_request()

    def do_DELETE(self):
        self.route_request()


def run_server(port):
    server_address = ('0.0.0.0', port)
    httpd = HTTPServer(server_address, TodoAppHandler)
    print(f"Starting Todo App server on 0.0.0.0:{port}")
    httpd.serve_forever()


if __name__ == '__main__':
    import sys
    import argparse

    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to listen on (default: 8000)')
    args = parser.parse_args()

    run_server(args.port)