#!/usr/bin/env python3
"""
REST API server for managing personal todo items with cookie-based authentication
"""
import json
import hashlib
import re
import uuid
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs


class TodoAppServer(BaseHTTPRequestHandler):
    """
    HTTP Request Handler for Todo App API
    """
    
    # Class-level storage to persist data between requests
    users = {}  # {id: {'id': int, 'username': str, 'password_hash': str}}
    usernames = {}  # {username: id}
    sessions = {}  # {session_id: user_id}
    todos = {}  # {id: {'id': int, 'user_id': int, 'title': str, 'description': str, 'completed': bool, 'created_at': str, 'updated_at': str}}
    next_user_id = 1
    next_todo_id = 1
    
    def _hash_password(self, password):
        """Hash a password using SHA-256"""
        return hashlib.sha256(password.encode('utf-8')).hexdigest()
    
    def _set_headers(self, content_type='application/json', status=200):
        """Set response headers"""
        self.send_response(status)
        if status != 204:  # Don't send Content-Type header for 204
            self.send_header('Content-Type', content_type)
        self.end_headers()
    
    def _send_json_response(self, data, status=200):
        """Send JSON response"""
        if status == 204:
            # Handle 204 No Content - must not send body
            self._set_headers(status=204)  # Omit Content-Type for 204
        else:
            self._set_headers(status=status)
            self.wfile.write(json.dumps(data).encode('utf-8'))
        
    def _send_error(self, message, status=400):
        """Send error response"""
        self._set_headers(status=status)
        self.wfile.write(json.dumps({'error': message}).encode('utf-8'))
    
    def _get_session_user_id(self):
        """Extract user_id from session cookie, return None if unauthorized"""
        cookies_header = self.headers.get('Cookie')
        if not cookies_header:
            return None
        
        session_match = re.search(r'session_id=([^;]+)', cookies_header)
        if not session_match:
            return None
            
        session_id = session_match.group(1)
        return self.__class__.sessions.get(session_id)
    
    def _require_auth(self):
        """Check auth and return user_id, or send 401 if unauthorized"""
        user_id = self._get_session_user_id()
        if not user_id:
            self._send_error('Authentication required', 401)
            return None
        
        if user_id not in self.__class__.users:
            self._send_error('Authentication required', 401)
            return None
        
        return user_id
    
    def _generate_session_id(self):
        """Generate a random session ID"""
        return str(uuid.uuid4())
    
    def _get_request_body(self):
        """Parse request body as JSON"""
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        body = self.rfile.read(content_length).decode('utf-8')
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {}

    def do_POST(self):
        """Handle POST requests"""
        
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if self.path == '/register':
            self.handle_register()
        elif self.path == '/login':
            self.handle_login()
        elif self.path == '/logout':
            self.handle_logout()
        elif self.path == '/password':
            self.handle_change_password()
        elif self.path == '/todos':
            self.handle_create_todo()
        else:
            self._send_error('Not Found', 404)
    
    def do_GET(self):
        """Handle GET requests"""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if self.path == '/me':
            self.handle_get_me()
        elif self.path == '/todos':
            self.handle_list_todos()
        elif len(path_parts) == 2 and path_parts[0] == 'todos':
            todo_id_str = path_parts[1]
            try:
                todo_id = int(todo_id_str)
                self.handle_get_todo(todo_id)
            except ValueError:
                self._send_error('Not Found', 404)
        else:
            self._send_error('Not Found', 404)
    
    def do_PUT(self):
        """Handle PUT requests"""
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if self.path == '/password':
            self.handle_change_password()
        elif len(path_parts) == 2 and path_parts[0] == 'todos':
            todo_id_str = path_parts[1]
            try:
                todo_id = int(todo_id_str)
                self.handle_update_todo(todo_id)
            except ValueError:
                self._send_error('Not Found', 404)
        else:
            self._send_error('Not Found', 404)
    
    def do_DELETE(self):
        """Handle DELETE requests"""
        
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        if len(path_parts) == 2 and path_parts[0] == 'todos':
            todo_id_str = path_parts[1]
            try:
                todo_id = int(todo_id_str)
                self.handle_delete_todo(todo_id)
            except ValueError:
                self._send_error('Not Found', 404)
        else:
            self._send_error('Not Found', 404)
    
    def handle_register(self):
        """Handle user registration"""
        
        data = self._get_request_body()
        
        username = data.get('username')
        password = data.get('password')
        
        if not username:
            self._send_error('Invalid username', 400)
            return
        
        if not isinstance(username, str) or len(username) < 3 or len(username) > 50 or not re.match(r'^[a-zA-Z0-9_]+$', username):
            self._send_error('Invalid username', 400)
            return
        
        if not password:
            self._send_error('Password too short', 400)
            return
        
        if len(password) < 8:
            self._send_error('Password too short', 400)
            return
        
        if username in self.__class__.usernames:
            self._send_error('Username already exists', 409)
            return
        
        user_id = self.__class__.next_user_id
        self.__class__.next_user_id += 1
        
        self.__class__.users[user_id] = {
            'id': user_id,
            'username': username,
            'password_hash': self._hash_password(password)
        }
        
        self.__class__.usernames[username] = user_id
        
        response_data = {'id': user_id, 'username': username}
        self._send_json_response(response_data, 201)
    
    def handle_login(self):
        """Handle user login"""
        data = self._get_request_body()
        
        username = data.get('username')
        password = data.get('password')
        
        if not username or not password:
            self._send_error('Invalid credentials', 401)
            return
        
        user_id = self.__class__.usernames.get(username)
        if not user_id:
            self._send_error('Invalid credentials', 401)
            return
        
        user = self.__class__.users.get(user_id)
        if not user or user['password_hash'] != self._hash_password(password):
            self._send_error('Invalid credentials', 401)
            return
        
        session_id = self._generate_session_id()
        self.__class__.sessions[session_id] = user_id
        
        response_data = {'id': user_id, 'username': username}
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')
        self.end_headers()
        self.wfile.write(json.dumps(response_data).encode('utf-8'))
    
    def handle_logout(self):
        """Handle user logout"""
        user_id = self._require_auth()
        if not user_id:
            return
        
        cookies_header = self.headers.get('Cookie')
        if cookies_header:
            session_match = re.search(r'session_id=([^;]+)', cookies_header)
            if session_match:
                session_id = session_match.group(1)
                if session_id in self.__class__.sessions:
                    del self.__class__.sessions[session_id]
        
        self._send_json_response({})
    
    def handle_get_me(self):
        """Handle getting current user information"""
        user_id = self._require_auth()
        if not user_id:
            return
        
        user = self.__class__.users.get(user_id)
        if not user:
            self._send_error('Authentication required', 401)
            return
        
        self._send_json_response({'id': user['id'], 'username': user['username']})
    
    def handle_change_password(self):
        """Handle changing user password"""
        user_id = self._require_auth()
        if not user_id:
            return
        
        data = self._get_request_body()
        
        old_password = data.get('old_password')
        new_password = data.get('new_password')
        
        if not old_password:
            self._send_error('Invalid credentials', 401)
            return
        
        user = self.__class__.users.get(user_id)
        if not user or user['password_hash'] != self._hash_password(old_password):
            self._send_error('Invalid credentials', 401)
            return
        
        if not new_password or len(new_password) < 8:
            self._send_error('Password too short', 400)
            return
        
        user['password_hash'] = self._hash_password(new_password)
        self._send_json_response({})
    
    def handle_list_todos(self):
        """Handle listing user's todos"""
        user_id = self._require_auth()
        if not user_id:
            return
        
        user_todos = []
        for todo in self.__class__.todos.values():
            if todo['user_id'] == user_id:
                user_todos.append(todo)
        
        # Sort by id ascending
        user_todos.sort(key=lambda x: x['id'])
        
        self._send_json_response(user_todos)
    
    def handle_create_todo(self):
        """Handle creating a new todo"""
        
        user_id = self._require_auth()
        if not user_id:
            return
        
        data = self._get_request_body()
        
        title = data.get('title', '')
        description = data.get('description', '')
        
        if not title:
            self._send_error('Title is required', 400)
            return
        
        now_str = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        
        todo_id = self.__class__.next_todo_id
        self.__class__.next_todo_id += 1
        
        todo = {
            'id': todo_id,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now_str,
            'updated_at': now_str,
            'user_id': user_id
        }
        
        self.__class__.todos[todo_id] = todo
        
        self._send_json_response(todo, 201)
    
    def handle_get_todo(self, todo_id):
        """Handle getting a specific todo"""
        user_id = self._require_auth()
        if not user_id:
            return
        
        todo = self.__class__.todos.get(todo_id)
        if not todo or todo['user_id'] != user_id:
            self._send_error('Todo not found', 404)
            return
        
        self._send_json_response(todo)
    
    def handle_update_todo(self, todo_id):
        """Handle updating a specific todo (partial update)"""
        user_id = self._require_auth()
        if not user_id:
            return
        
        todo = self.__class__.todos.get(todo_id)
        if not todo or todo['user_id'] != user_id:
            self._send_error('Todo not found', 404)
            return
        
        data = self._get_request_body()
        
        title = data.get('title')
        if title is not None:
            if not title:
                self._send_error('Title is required', 400)
                return
            todo['title'] = title
        
        description = data.get('description')
        if description is not None:
            todo['description'] = description
        
        completed = data.get('completed')
        if completed is not None:
            todo['completed'] = bool(completed)
        
        todo['updated_at'] = datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        
        self._send_json_response(todo)
    
    def handle_delete_todo(self, todo_id):
        """Handle deleting a specific todo"""
        user_id = self._require_auth()
        if not user_id:
            return
        
        todo = self.__class__.todos.get(todo_id)
        if not todo or todo['user_id'] != user_id:
            self._send_error('Todo not found', 404)
            return
        
        del self.__class__.todos[todo_id]
        
        # Send 204 No Content with no body
        self._set_headers(status=204)
    
    def log_message(self, format, *args):
        # Silence the default logging for cleaner output
        pass


def run_server(port):
    """Run the HTTP server"""
    server_address = ('0.0.0.0', port)
    httpd = HTTPServer(server_address, TodoAppServer)
    
    print(f'Starting server on 0.0.0.0:{port}')
    httpd.serve_forever()


if __name__ == '__main__':
    import argparse
    
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, default=8000, help='Port to listen on')
    
    args = parser.parse_args()
    run_server(args.port)