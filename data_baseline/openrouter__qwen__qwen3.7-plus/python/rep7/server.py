import sys
import argparse
import json
import uuid
import re
from datetime import datetime, timezone
from http.server import HTTPServer, BaseHTTPRequestHandler

# In-memory storage
users = {}  # username -> {"id": int, "username": str, "password": str}
user_id_counter = 1
todos = {}  # id -> {"id": int, "user_id": int, "title": str, "description": str, "completed": bool, "created_at": str, "updated_at": str}
todo_id_counter = 1
sessions = {}  # token -> user_id

USERNAME_REGEX = re.compile(r'^[a-zA-Z0-9_]+$')

def get_current_time():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

class TodoHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, format, *args):
        pass  # Suppress logging

    def get_path(self):
        return self.path.split('?')[0]

    def send_json_response(self, status_code, data):
        body = json.dumps(data).encode('utf-8')
        self.send_response(status_code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_no_content(self):
        self.send_response(204)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def get_session_user(self):
        cookies = self.headers.get('Cookie', '')
        for cookie in cookies.split(';'):
            name, _, value = cookie.strip().partition('=')
            if name == 'session_id':
                user_id = sessions.get(value)
                if user_id:
                    for uname, udata in users.items():
                        if udata['id'] == user_id:
                            return udata
        return None

    def read_json_body(self):
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        body = self.rfile.read(content_length)
        try:
            data = json.loads(body.decode('utf-8'))
            if not isinstance(data, dict):
                raise ValueError("Not a dict")
            return data
        except (json.JSONDecodeError, ValueError):
            raise ValueError("Invalid JSON")

    def do_GET(self):
        path = self.get_path()
        if path == '/me':
            user = self.get_session_user()
            if not user:
                return self.send_json_response(401, {"error": "Authentication required"})
            return self.send_json_response(200, {"id": user['id'], "username": user['username']})
        
        elif path == '/todos':
            user = self.get_session_user()
            if not user:
                return self.send_json_response(401, {"error": "Authentication required"})
            
            user_todos = [t for t in todos.values() if t['user_id'] == user['id']]
            user_todos.sort(key=lambda x: x['id'])
            resp = [{k: v for k, v in t.items() if k != 'user_id'} for t in user_todos]
            return self.send_json_response(200, resp)
            
        elif path.startswith('/todos/'):
            user = self.get_session_user()
            if not user:
                return self.send_json_response(401, {"error": "Authentication required"})
            
            todo_id_str = path[7:]
            try:
                todo_id = int(todo_id_str)
            except ValueError:
                return self.send_json_response(404, {"error": "Todo not found"})
            
            todo = todos.get(todo_id)
            if not todo or todo['user_id'] != user['id']:
                return self.send_json_response(404, {"error": "Todo not found"})
            
            resp = {k: v for k, v in todo.items() if k != 'user_id'}
            return self.send_json_response(200, resp)
            
        else:
            return self.send_json_response(404, {"error": "Not found"})

    def do_POST(self):
        global user_id_counter, todo_id_counter
        
        path = self.get_path()
        if path == '/register':
            try:
                data = self.read_json_body()
            except ValueError:
                return self.send_json_response(400, {"error": "Invalid JSON"})
            
            username = data.get('username')
            password = data.get('password')
            
            if not isinstance(username, str) or not USERNAME_REGEX.match(username) or len(username) < 3 or len(username) > 50:
                return self.send_json_response(400, {"error": "Invalid username"})
            
            if not isinstance(password, str) or len(password) < 8:
                return self.send_json_response(400, {"error": "Password too short"})
            
            if username in users:
                return self.send_json_response(409, {"error": "Username already exists"})
            
            user_id = user_id_counter
            user_id_counter += 1
            
            users[username] = {
                "id": user_id,
                "username": username,
                "password": password
            }
            
            return self.send_json_response(201, {"id": user_id, "username": username})
            
        elif path == '/login':
            try:
                data = self.read_json_body()
            except ValueError:
                return self.send_json_response(400, {"error": "Invalid JSON"})
            
            username = data.get('username')
            password = data.get('password')
            
            user = users.get(username)
            if not user or user['password'] != password:
                return self.send_json_response(401, {"error": "Invalid credentials"})
            
            token = uuid.uuid4().hex
            sessions[token] = user['id']
            
            body = json.dumps({"id": user['id'], "username": user['username']}).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Set-Cookie', f'session_id={token}; Path=/; HttpOnly')
            self.end_headers()
            self.wfile.write(body)
            return
            
        elif path == '/logout':
            user = self.get_session_user()
            if not user:
                return self.send_json_response(401, {"error": "Authentication required"})
            
            cookies = self.headers.get('Cookie', '')
            for cookie in cookies.split(';'):
                name, _, value = cookie.strip().partition('=')
                if name == 'session_id':
                    if value in sessions:
                        del sessions[value]
            
            return self.send_json_response(200, {})
            
        elif path == '/todos':
            user = self.get_session_user()
            if not user:
                return self.send_json_response(401, {"error": "Authentication required"})
            
            try:
                data = self.read_json_body()
            except ValueError:
                return self.send_json_response(400, {"error": "Invalid JSON"})
            
            title = data.get('title')
            if not isinstance(title, str) or len(title) == 0:
                return self.send_json_response(400, {"error": "Title is required"})
            
            description = data.get('description', '')
            if not isinstance(description, str):
                description = ''
                
            now = get_current_time()
            todo_id = todo_id_counter
            todo_id_counter += 1
            
            new_todo = {
                "id": todo_id,
                "title": title,
                "description": description,
                "completed": False,
                "created_at": now,
                "updated_at": now,
                "user_id": user['id']
            }
            
            todos[todo_id] = new_todo
            
            resp = {k: v for k, v in new_todo.items() if k != 'user_id'}
            return self.send_json_response(201, resp)
            
        else:
            return self.send_json_response(404, {"error": "Not found"})

    def do_PUT(self):
        path = self.get_path()
        if path == '/password':
            user = self.get_session_user()
            if not user:
                return self.send_json_response(401, {"error": "Authentication required"})
            
            try:
                data = self.read_json_body()
            except ValueError:
                return self.send_json_response(400, {"error": "Invalid JSON"})
            
            old_password = data.get('old_password')
            new_password = data.get('new_password')
            
            if user['password'] != old_password:
                return self.send_json_response(401, {"error": "Invalid credentials"})
            
            if not isinstance(new_password, str) or len(new_password) < 8:
                return self.send_json_response(400, {"error": "Password too short"})
            
            user['password'] = new_password
            return self.send_json_response(200, {})
            
        elif path.startswith('/todos/'):
            user = self.get_session_user()
            if not user:
                return self.send_json_response(401, {"error": "Authentication required"})
            
            todo_id_str = path[7:]
            try:
                todo_id = int(todo_id_str)
            except ValueError:
                return self.send_json_response(404, {"error": "Todo not found"})
            
            todo = todos.get(todo_id)
            if not todo or todo['user_id'] != user['id']:
                return self.send_json_response(404, {"error": "Todo not found"})
            
            try:
                data = self.read_json_body()
            except ValueError:
                return self.send_json_response(400, {"error": "Invalid JSON"})
            
            if 'title' in data:
                if not isinstance(data['title'], str) or len(data['title']) == 0:
                    return self.send_json_response(400, {"error": "Title is required"})
                todo['title'] = data['title']
                
            if 'description' in data:
                todo['description'] = data['description'] if isinstance(data['description'], str) else ''
                
            if 'completed' in data:
                todo['completed'] = bool(data['completed'])
                
            todo['updated_at'] = get_current_time()
            
            resp = {k: v for k, v in todo.items() if k != 'user_id'}
            return self.send_json_response(200, resp)
            
        else:
            return self.send_json_response(404, {"error": "Not found"})

    def do_DELETE(self):
        path = self.get_path()
        if path.startswith('/todos/'):
            user = self.get_session_user()
            if not user:
                return self.send_json_response(401, {"error": "Authentication required"})
            
            todo_id_str = path[7:]
            try:
                todo_id = int(todo_id_str)
            except ValueError:
                return self.send_json_response(404, {"error": "Todo not found"})
            
            todo = todos.get(todo_id)
            if not todo or todo['user_id'] != user['id']:
                return self.send_json_response(404, {"error": "Todo not found"})
            
            del todos[todo_id]
            return self.send_no_content()
            
        else:
            return self.send_json_response(404, {"error": "Not found"})

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    
    server = HTTPServer(('0.0.0.0', args.port), TodoHandler)
    print(f"Server running on 0.0.0.0:{args.port}")
    server.serve_forever()
