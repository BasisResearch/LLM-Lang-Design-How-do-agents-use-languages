import json
import re
import uuid
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import argparse


def generate_timestamp():
    """Generate an ISO 8601 UTC timestamp with second precision."""
    return datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')


class TodoAppServer(BaseHTTPRequestHandler):
    # Class-level storage to persist data across requests
    users = {}  # user_id -> user_data
    todos = {}  # todo_id -> todo_data
    user_ids_counter = 1  # auto-increment ID counter for users
    todo_ids_counter = 1  # auto-increment ID counter for todos
    sessions = {}  # session_id -> user_id mapping

    def get_request_body(self):
        """Parse and return JSON request body."""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        body = self.rfile.read(content_length).decode('utf-8')
        return json.loads(body)

    def authenticate_user(self):
        """Extract and validate session ID from cookies, returning user_id or None."""
        cookie_header = self.headers.get('Cookie')
        if not cookie_header:
            return None
        
        cookies = {}
        for cookie in cookie_header.split(';'):
            if '=' in cookie:
                k, v = cookie.strip().split('=', 1)
                cookies[k] = v
        
        session_id = cookies.get('session_id')
        if not session_id or session_id not in TodoAppServer.sessions:
            return None
        
        return TodoAppServer.sessions[session_id]

    def send_json_response(self, status_code, data):
        """Send JSON response with appropriate headers."""
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        
        if data is not None:
            self.wfile.write(json.dumps(data).encode('utf-8'))

    def send_error_response(self, status_code, message):
        """Send error response in standard format."""
        self.send_json_response(status_code, {'error': message})

    def set_session_cookie(self, session_id):
        """Set session cookie in response headers."""
        self.send_header('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')

    def do_POST(self):
        """Handle POST requests."""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/register':
            self.handle_register()
        elif parsed_path.path == '/login':
            self.handle_login()
        elif parsed_path.path == '/logout':
            self.handle_logout()
        elif parsed_path.path == '/password':
            self.handle_change_password()
        elif parsed_path.path == '/todos':
            self.handle_create_todo()
        else:
            self.send_error_response(404, 'Not found')

    def do_GET(self):
        """Handle GET requests."""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/me':
            self.handle_get_me()
        elif parsed_path.path == '/todos':
            self.handle_get_todos()
        elif parsed_path.path.startswith('/todos/'):
            # Extract ID from path like /todos/123
            try:
                todo_id = int(parsed_path.path.split('/')[2])
                self.handle_get_todo(todo_id)
            except (ValueError, IndexError):
                self.send_error_response(404, 'Not found')
        else:
            self.send_error_response(404, 'Not found')

    def do_PUT(self):
        """Handle PUT requests."""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/password':
            self.handle_change_password()
        elif parsed_path.path.startswith('/todos/'):
            # Extract ID from path like /todos/123
            try:
                todo_id = int(parsed_path.path.split('/')[2])
                self.handle_update_todo(todo_id)
            except (ValueError, IndexError):
                self.send_error_response(404, 'Not found')
        else:
            self.send_error_response(404, 'Not found')

    def do_DELETE(self):
        """Handle DELETE requests."""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path.startswith('/todos/'):
            # Extract ID from path like /todos/123
            try:
                todo_id = int(parsed_path.path.split('/')[2])
                self.handle_delete_todo(todo_id)
            except (ValueError, IndexError):
                self.send_error_response(404, 'Not found')
        else:
            self.send_error_response(404, 'Not found')

    def handle_register(self):
        """Handle user registration."""
        try:
            req_data = self.get_request_body()
        except json.JSONDecodeError:
            return self.send_error_response(400, 'Invalid JSON')
        
        username = req_data.get('username')
        password = req_data.get('password')
        
        # Validate username
        if not username or len(username) < 3 or len(username) > 50 or not re.match(r'^[a-zA-Z0-9_]+$', username):
            return self.send_error_response(400, 'Invalid username')
        
        # Validate password
        if not password or len(password) < 8:
            return self.send_error_response(400, 'Password too short')
        
        # Check if username already exists
        for user in TodoAppServer.users.values():
            if user['username'] == username:
                return self.send_error_response(409, 'Username already exists')
        
        # Create new user
        user_id = TodoAppServer.user_ids_counter
        TodoAppServer.user_ids_counter += 1
        
        TodoAppServer.users[user_id] = {
            'id': user_id,
            'username': username,
            'password': password  # In a real app, hash passwords!
        }
        
        response = {'id': user_id, 'username': username}
        self.send_json_response(201, response)

    def handle_login(self):
        """Handle user login."""
        try:
            req_data = self.get_request_body()
        except json.JSONDecodeError:
            return self.send_error_response(400, 'Invalid JSON')
        
        username = req_data.get('username')
        password = req_data.get('password')
        
        if not username or not password:
            return self.send_error_response(401, 'Invalid credentials')
        
        # Find the user
        user_id = None
        for uid, user in TodoAppServer.users.items():
            if user['username'] == username and user['password'] == password:
                user_id = uid
                break
        
        if user_id is None:
            return self.send_error_response(401, 'Invalid credentials')
        
        # Generate session
        session_id = str(uuid.uuid4())
        TodoAppServer.sessions[session_id] = user_id
        
        # Prepare response
        response = {'id': user_id, 'username': username}
        self.send_response(200)
        self.set_session_cookie(session_id)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(response).encode('utf-8'))

    def handle_logout(self):
        """Handle user logout."""
        user_id = self.authenticate_user()
        if not user_id:
            return self.send_error_response(401, 'Authentication required')
        
        # Remove session
        cookie_header = self.headers.get('Cookie')
        if cookie_header:
            cookies = {}
            for cookie in cookie_header.split(';'):
                if '=' in cookie:
                    k, v = cookie.strip().split('=', 1)
                    cookies[k] = v
            
            session_id = cookies.get('session_id')
            if session_id in TodoAppServer.sessions:
                del TodoAppServer.sessions[session_id]
        
        self.send_json_response(200, {})

    def handle_get_me(self):
        """Get current user information."""
        user_id = self.authenticate_user()
        if not user_id:
            return self.send_error_response(401, 'Authentication required')
        
        user = TodoAppServer.users.get(user_id)
        if not user:
            return self.send_error_response(401, 'Authentication required')
        
        response = {'id': user['id'], 'username': user['username']}
        self.send_json_response(200, response)

    def handle_change_password(self):
        """Change user password."""
        user_id = self.authenticate_user()
        if not user_id:
            return self.send_error_response(401, 'Authentication required')
        
        try:
            req_data = self.get_request_body()
        except json.JSONDecodeError:
            return self.send_error_response(400, 'Invalid JSON')
        
        old_password = req_data.get('old_password')
        new_password = req_data.get('new_password')
        
        if not old_password or not new_password:
            return self.send_error_response(400, 'Missing required fields')
        
        user = TodoAppServer.users.get(user_id)
        if not user:
            return self.send_error_response(401, 'Authentication required')
        
        if user['password'] != old_password:
            return self.send_error_response(401, 'Invalid credentials')
        
        if len(new_password) < 8:
            return self.send_error_response(400, 'Password too short')
        
        # Update password
        user['password'] = new_password
        self.send_json_response(200, {})

    def handle_get_todos(self):
        """Get user's todos."""
        user_id = self.authenticate_user()
        if not user_id:
            return self.send_error_response(401, 'Authentication required')
        
        # Filter todos for the current user
        user_todos = []
        for todo in TodoAppServer.todos.values():
            if todo['user_id'] == user_id:
                user_todos.append(todo)
        
        # Sort by ID (ascending)
        user_todos.sort(key=lambda x: x['id'])
        
        self.send_json_response(200, user_todos)

    def handle_create_todo(self):
        """Create a new todo item."""
        user_id = self.authenticate_user()
        if not user_id:
            return self.send_error_response(401, 'Authentication required')
        
        try:
            req_data = self.get_request_body()
        except json.JSONDecodeError:
            return self.send_error_response(400, 'Invalid JSON')
        
        title = req_data.get('title', '').strip() or req_data.get('title')  # Don't strip if None
        description = req_data.get('description', '')
        
        # Verify title
        if not title:  # Also catches None and empty strings
            return self.send_error_response(400, 'Title is required')
        
        # Create new todo
        todo_id = TodoAppServer.todo_ids_counter
        TodoAppServer.todo_ids_counter += 1
        
        created_at = generate_timestamp()
        updated_at = created_at
        
        new_todo = {
            'id': todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': created_at,
            'updated_at': updated_at,
            'user_id': user_id  # Store the owner
        }
        
        TodoAppServer.todos[todo_id] = new_todo
        
        self.send_json_response(201, new_todo)

    def handle_get_todo(self, todo_id):
        """Get a specific todo item."""
        user_id = self.authenticate_user()
        if not user_id:
            return self.send_error_response(401, 'Authentication required')
        
        todo = TodoAppServer.todos.get(todo_id)
        
        # Verify the todo exists AND belongs to the user requesting it
        if not todo or todo['user_id'] != user_id:
            return self.send_error_response(404, 'Todo not found')
        
        self.send_json_response(200, todo)

    def handle_update_todo(self, todo_id):
        """Update a specific todo item (partial update)."""
        user_id = self.authenticate_user()
        if not user_id:
            return self.send_error_response(401, 'Authentication required')
        
        todo = TodoAppServer.todos.get(todo_id)
        
        # Verify the todo exists AND belongs to the user requesting it
        if not todo or todo['user_id'] != user_id:
            return self.send_error_response(404, 'Todo not found')
        
        try:
            req_data = self.get_request_body()
        except json.JSONDecodeError:
            return self.send_error_response(400, 'Invalid JSON')
        
        # Update fields if provided
        title = req_data.get('title')
        if title is not None:  # Allow empty string, but not None
            if isinstance(title, str) and title.strip() == '':
                return self.send_error_response(400, 'Title is required')
            todo['title'] = title
        
        description = req_data.get('description')
        if description is not None:
            todo['description'] = description
        
        completed = req_data.get('completed')
        if completed is not None:
            if not isinstance(completed, bool):
                return self.send_error_response(400, 'Completed must be boolean')
            todo['completed'] = completed
        
        # Update timestamp
        todo['updated_at'] = generate_timestamp()
        
        self.send_json_response(200, todo)

    def handle_delete_todo(self, todo_id):
        """Delete a specific todo item."""
        user_id = self.authenticate_user()
        if not user_id:
            return self.send_error_response(401, 'Authentication required')
        
        todo = TodoAppServer.todos.get(todo_id)
        
        # Verify the todo exists AND belongs to the user requesting it
        if not todo or todo['user_id'] != user_id:
            return self.send_error_response(404, 'Todo not found')
        
        del TodoAppServer.todos[todo_id]
        
        self.send_response(204)  # No content
        self.end_headers()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    
    server_address = ('0.0.0.0', args.port)
    httpd = HTTPServer(server_address, TodoAppServer)
    
    print(f'Server running on 0.0.0.0:{args.port}')
    httpd.serve_forever()