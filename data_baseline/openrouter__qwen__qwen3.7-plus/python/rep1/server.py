import json
import re
import uuid
import datetime
import argparse
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

USERS = {}
USER_IDS_BY_NAME = {}
NEXT_USER_ID = 1

SESSIONS = {}

TODOS = {}
NEXT_TODO_ID = 1

def get_timestamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

class TodoHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, format, *args):
        pass

    def send_json_response(self, status_code, data, include_content_type=True):
        self.send_response(status_code)
        if include_content_type:
            self.send_header('Content-Type', 'application/json')
        
        if data is not None:
            body = json.dumps(data).encode('utf-8')
            self.send_header('Content-Length', len(body))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.end_headers()

    def get_session_user(self):
        cookie = self.headers.get('Cookie', '')
        cookies = {}
        for item in cookie.split(';'):
            if '=' in item:
                k, v = item.strip().split('=', 1)
                cookies[k] = v
        token = cookies.get('session_id')
        if not token or token not in SESSIONS:
            return None
        return SESSIONS[token]

    def require_auth(self):
        user_id = self.get_session_user()
        if user_id is None:
            self.send_json_response(401, {"error": "Authentication required"})
            return None
        return user_id

    def read_json_body(self):
        content_length = int(self.headers.get('Content-Length', 0))
        if content_length == 0:
            return {}
        body = self.rfile.read(content_length)
        try:
            return json.loads(body.decode('utf-8'))
        except json.JSONDecodeError:
            return None

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == '/me':
            user_id = self.require_auth()
            if user_id is None:
                return
            user = USERS[user_id]
            self.send_json_response(200, {"id": user["id"], "username": user["username"]})

        elif path == '/todos':
            user_id = self.require_auth()
            if user_id is None:
                return
            user_todos = [
                {
                    "id": t["id"],
                    "title": t["title"],
                    "description": t["description"],
                    "completed": t["completed"],
                    "created_at": t["created_at"],
                    "updated_at": t["updated_at"]
                }
                for t in TODOS.values() if t["user_id"] == user_id
            ]
            user_todos.sort(key=lambda x: x["id"])
            self.send_json_response(200, user_todos)

        elif path.startswith('/todos/'):
            parts = path.split('/')
            if len(parts) == 3:
                try:
                    todo_id = int(parts[2])
                except ValueError:
                    self.send_json_response(404, {"error": "Todo not found"})
                    return
                
                user_id = self.require_auth()
                if user_id is None:
                    return
                
                todo = TODOS.get(todo_id)
                if not todo or todo["user_id"] != user_id:
                    self.send_json_response(404, {"error": "Todo not found"})
                    return
                
                self.send_json_response(200, {
                    "id": todo["id"],
                    "title": todo["title"],
                    "description": todo["description"],
                    "completed": todo["completed"],
                    "created_at": todo["created_at"],
                    "updated_at": todo["updated_at"]
                })
            else:
                self.send_json_response(404, {"error": "Not found"})

        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_POST(self):
        global NEXT_USER_ID, NEXT_TODO_ID
        parsed = urlparse(self.path)
        path = parsed.path

        if path == '/register':
            data = self.read_json_body()
            if not isinstance(data, dict):
                self.send_json_response(400, {"error": "Invalid request"})
                return
            
            username = data.get('username', '')
            password = data.get('password', '')
            
            if not isinstance(username, str) or not re.match(r'^[a-zA-Z0-9_]+$', username) or not (3 <= len(username) <= 50):
                self.send_json_response(400, {"error": "Invalid username"})
                return
            
            if not isinstance(password, str) or len(password) < 8:
                self.send_json_response(400, {"error": "Password too short"})
                return
            
            if username in USER_IDS_BY_NAME:
                self.send_json_response(409, {"error": "Username already exists"})
                return
            
            user_id = NEXT_USER_ID
            NEXT_USER_ID += 1
            
            USERS[user_id] = {"id": user_id, "username": username, "password": password}
            USER_IDS_BY_NAME[username] = user_id
            
            self.send_json_response(201, {"id": user_id, "username": username})

        elif path == '/login':
            data = self.read_json_body()
            if not isinstance(data, dict):
                self.send_json_response(401, {"error": "Invalid credentials"})
                return
            
            username = data.get('username', '')
            password = data.get('password', '')
            
            user_id = USER_IDS_BY_NAME.get(username)
            if not user_id or USERS[user_id]['password'] != password:
                self.send_json_response(401, {"error": "Invalid credentials"})
                return
            
            token = uuid.uuid4().hex
            SESSIONS[token] = user_id
            
            body = json.dumps({"id": user_id, "username": username}).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', len(body))
            self.send_header('Set-Cookie', f'session_id={token}; Path=/; HttpOnly')
            self.end_headers()
            self.wfile.write(body)

        elif path == '/logout':
            user_id = self.require_auth()
            if user_id is None:
                return
            
            cookie = self.headers.get('Cookie', '')
            cookies = {}
            for item in cookie.split(';'):
                if '=' in item:
                    k, v = item.strip().split('=', 1)
                    cookies[k] = v
            token = cookies.get('session_id')
            if token in SESSIONS:
                del SESSIONS[token]
                
            self.send_json_response(200, {})

        elif path == '/todos':
            user_id = self.require_auth()
            if user_id is None:
                return
            
            data = self.read_json_body()
            if not isinstance(data, dict):
                self.send_json_response(400, {"error": "Title is required"})
                return
                
            title = data.get('title')
            if not isinstance(title, str) or len(title) == 0:
                self.send_json_response(400, {"error": "Title is required"})
                return
                
            description = data.get('description', '')
            if not isinstance(description, str):
                description = ''
                
            timestamp = get_timestamp()
            
            todo_id = NEXT_TODO_ID
            NEXT_TODO_ID += 1
            
            todo = {
                "id": todo_id,
                "user_id": user_id,
                "title": title,
                "description": description,
                "completed": False,
                "created_at": timestamp,
                "updated_at": timestamp
            }
            TODOS[todo_id] = todo
            
            self.send_json_response(201, {
                "id": todo["id"],
                "title": todo["title"],
                "description": todo["description"],
                "completed": todo["completed"],
                "created_at": todo["created_at"],
                "updated_at": todo["updated_at"]
            })

        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == '/password':
            user_id = self.require_auth()
            if user_id is None:
                return
            
            data = self.read_json_body()
            if not isinstance(data, dict):
                self.send_json_response(401, {"error": "Invalid credentials"})
                return
                
            user = USERS[user_id]
            old_password = data.get('old_password', '')
            new_password = data.get('new_password', '')
            
            if user['password'] != old_password:
                self.send_json_response(401, {"error": "Invalid credentials"})
                return
                
            if not isinstance(new_password, str) or len(new_password) < 8:
                self.send_json_response(400, {"error": "Password too short"})
                return
                
            user['password'] = new_password
            self.send_json_response(200, {})

        elif path.startswith('/todos/'):
            parts = path.split('/')
            if len(parts) == 3:
                try:
                    todo_id = int(parts[2])
                except ValueError:
                    self.send_json_response(404, {"error": "Todo not found"})
                    return
                
                user_id = self.require_auth()
                if user_id is None:
                    return
                
                todo = TODOS.get(todo_id)
                if not todo or todo["user_id"] != user_id:
                    self.send_json_response(404, {"error": "Todo not found"})
                    return
                
                data = self.read_json_body()
                if not isinstance(data, dict):
                    data = {}
                
                if 'title' in data:
                    title = data['title']
                    if not isinstance(title, str) or len(title) == 0:
                        self.send_json_response(400, {"error": "Title is required"})
                        return
                    todo["title"] = title
                    
                if 'description' in data:
                    todo["description"] = data['description']
                    
                if 'completed' in data:
                    todo["completed"] = bool(data['completed'])
                    
                todo["updated_at"] = get_timestamp()
                
                self.send_json_response(200, {
                    "id": todo["id"],
                    "title": todo["title"],
                    "description": todo["description"],
                    "completed": todo["completed"],
                    "created_at": todo["created_at"],
                    "updated_at": todo["updated_at"]
                })
            else:
                self.send_json_response(404, {"error": "Not found"})

        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path.startswith('/todos/'):
            parts = path.split('/')
            if len(parts) == 3:
                try:
                    todo_id = int(parts[2])
                except ValueError:
                    self.send_json_response(404, {"error": "Todo not found"})
                    return
                
                user_id = self.require_auth()
                if user_id is None:
                    return
                
                todo = TODOS.get(todo_id)
                if not todo or todo["user_id"] != user_id:
                    self.send_json_response(404, {"error": "Todo not found"})
                    return
                
                del TODOS[todo_id]
                
                self.send_response(204)
                self.end_headers()
            else:
                self.send_json_response(404, {"error": "Not found"})
        else:
            self.send_json_response(404, {"error": "Not found"})

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8000)
    args = parser.parse_args()
    
    server = HTTPServer(('0.0.0.0', args.port), TodoHandler)
    print(f"Server running on 0.0.0.0:{args.port}")
    server.serve_forever()
