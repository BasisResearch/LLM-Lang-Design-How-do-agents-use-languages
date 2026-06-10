import argparse
import datetime
import hashlib
import http.cookies
import http.server
import json
import re
import secrets
import socketserver

# In-memory storage
users = {}  # username -> {"id": int, "username": str, "password_hash": str}
user_id_counter = 1
todos = {}  # id -> {"id": int, "user_id": int, "title": str, "description": str, "completed": bool, "created_at": str, "updated_at": str}
todo_id_counter = 1
sessions = {}  # token -> user_id

def get_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def hash_password(password):
    salt = secrets.token_hex(16)
    pwd_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), 100000).hex()
    return f"{salt}:{pwd_hash}"

def verify_password(password, stored):
    salt, pwd_hash = stored.split(':')
    new_hash = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), 100000).hex()
    return secrets.compare_digest(new_hash, pwd_hash)

class TodoHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass # Suppress logging for cleaner test output

    def get_current_user(self):
        cookie_header = self.headers.get('Cookie', '')
        cookies = http.cookies.SimpleCookie(cookie_header)
        if 'session_id' in cookies:
            token = cookies['session_id'].value
            if token in sessions:
                return sessions[token]
        return None

    def send_json_response(self, status, data, extra_headers=None):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def send_empty_response(self, status, extra_headers=None):
        self.send_response(status)
        if extra_headers:
            for key, value in extra_headers.items():
                self.send_header(key, value)
        self.end_headers()

    def do_GET(self):
        if self.path == '/me':
            user_id = self.get_current_user()
            if not user_id:
                self.send_json_response(401, {"error": "Authentication required"})
                return
            user = next((u for u in users.values() if u['id'] == user_id), None)
            if not user:
                self.send_json_response(401, {"error": "Authentication required"})
                return
            self.send_json_response(200, {"id": user['id'], "username": user['username']})

        elif self.path == '/todos':
            user_id = self.get_current_user()
            if not user_id:
                self.send_json_response(401, {"error": "Authentication required"})
                return
            user_todos = [t for t in todos.values() if t['user_id'] == user_id]
            user_todos.sort(key=lambda x: x['id'])
            response_todos = [{
                "id": t['id'],
                "title": t['title'],
                "description": t['description'],
                "completed": t['completed'],
                "created_at": t['created_at'],
                "updated_at": t['updated_at']
            } for t in user_todos]
            self.send_json_response(200, response_todos)

        elif self.path.startswith('/todos/'):
            user_id = self.get_current_user()
            if not user_id:
                self.send_json_response(401, {"error": "Authentication required"})
                return
            try:
                todo_id = int(self.path.split('/todos/')[1])
            except ValueError:
                self.send_json_response(404, {"error": "Todo not found"})
                return
            todo = todos.get(todo_id)
            if not todo or todo['user_id'] != user_id:
                self.send_json_response(404, {"error": "Todo not found"})
                return
            self.send_json_response(200, {
                "id": todo['id'],
                "title": todo['title'],
                "description": todo['description'],
                "completed": todo['completed'],
                "created_at": todo['created_at'],
                "updated_at": todo['updated_at']
            })
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_POST(self):
        global user_id_counter, todo_id_counter

        if self.path == '/register':
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8')
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self.send_json_response(400, {"error": "Invalid JSON"})
                return

            username = data.get('username')
            password = data.get('password')

            if not isinstance(username, str) or not re.match(r'^[a-zA-Z0-9_]+$', username) or not (3 <= len(username) <= 50):
                self.send_json_response(400, {"error": "Invalid username"})
                return

            if not isinstance(password, str) or len(password) < 8:
                self.send_json_response(400, {"error": "Password too short"})
                return

            if username in users:
                self.send_json_response(409, {"error": "Username already exists"})
                return

            user_id = user_id_counter
            user_id_counter += 1

            users[username] = {
                "id": user_id,
                "username": username,
                "password_hash": hash_password(password)
            }

            self.send_json_response(201, {"id": user_id, "username": username})

        elif self.path == '/login':
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8')
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self.send_json_response(400, {"error": "Invalid JSON"})
                return

            username = data.get('username')
            password = data.get('password')

            user = users.get(username)
            if not user or not verify_password(password, user['password_hash']):
                self.send_json_response(401, {"error": "Invalid credentials"})
                return

            token = secrets.token_hex(32)
            sessions[token] = user['id']

            self.send_json_response(200, {"id": user['id'], "username": user['username']}, 
                {"Set-Cookie": f"session_id={token}; Path=/; HttpOnly"})

        elif self.path == '/logout':
            user_id = self.get_current_user()
            if not user_id:
                self.send_json_response(401, {"error": "Authentication required"})
                return

            cookie_header = self.headers.get('Cookie', '')
            cookies = http.cookies.SimpleCookie(cookie_header)
            token = cookies['session_id'].value
            if token in sessions:
                del sessions[token]

            self.send_json_response(200, {})

        elif self.path == '/todos':
            user_id = self.get_current_user()
            if not user_id:
                self.send_json_response(401, {"error": "Authentication required"})
                return

            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8')
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self.send_json_response(400, {"error": "Invalid JSON"})
                return

            title = data.get('title')
            if not isinstance(title, str) or not title:
                self.send_json_response(400, {"error": "Title is required"})
                return

            description = data.get('description', '')
            if not isinstance(description, str):
                description = ''

            todo_id = todo_id_counter
            todo_id_counter += 1

            now = get_now()
            new_todo = {
                "id": todo_id,
                "user_id": user_id,
                "title": title,
                "description": description,
                "completed": False,
                "created_at": now,
                "updated_at": now
            }
            todos[todo_id] = new_todo

            self.send_json_response(201, {
                "id": new_todo['id'],
                "title": new_todo['title'],
                "description": new_todo['description'],
                "completed": new_todo['completed'],
                "created_at": new_todo['created_at'],
                "updated_at": new_todo['updated_at']
            })

        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_PUT(self):
        if self.path == '/password':
            user_id = self.get_current_user()
            if not user_id:
                self.send_json_response(401, {"error": "Authentication required"})
                return

            user = next((u for u in users.values() if u['id'] == user_id), None)
            if not user:
                self.send_json_response(401, {"error": "Authentication required"})
                return

            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8')
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self.send_json_response(400, {"error": "Invalid JSON"})
                return

            old_password = data.get('old_password')
            new_password = data.get('new_password')

            if not verify_password(old_password, user['password_hash']):
                self.send_json_response(401, {"error": "Invalid credentials"})
                return

            if not isinstance(new_password, str) or len(new_password) < 8:
                self.send_json_response(400, {"error": "Password too short"})
                return

            user['password_hash'] = hash_password(new_password)
            self.send_json_response(200, {})

        elif self.path.startswith('/todos/'):
            user_id = self.get_current_user()
            if not user_id:
                self.send_json_response(401, {"error": "Authentication required"})
                return

            try:
                todo_id = int(self.path.split('/todos/')[1])
            except ValueError:
                self.send_json_response(404, {"error": "Todo not found"})
                return

            todo = todos.get(todo_id)
            if not todo or todo['user_id'] != user_id:
                self.send_json_response(404, {"error": "Todo not found"})
                return

            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length).decode('utf-8')
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self.send_json_response(400, {"error": "Invalid JSON"})
                return

            if 'title' in data:
                if not isinstance(data['title'], str) or not data['title']:
                    self.send_json_response(400, {"error": "Title is required"})
                    return
                todo['title'] = data['title']

            if 'description' in data:
                todo['description'] = str(data['description']) if data['description'] is not None else ""

            if 'completed' in data:
                todo['completed'] = bool(data['completed'])

            todo['updated_at'] = get_now()

            self.send_json_response(200, {
                "id": todo['id'],
                "title": todo['title'],
                "description": todo['description'],
                "completed": todo['completed'],
                "created_at": todo['created_at'],
                "updated_at": todo['updated_at']
            })
        else:
            self.send_json_response(404, {"error": "Not found"})

    def do_DELETE(self):
        if self.path.startswith('/todos/'):
            user_id = self.get_current_user()
            if not user_id:
                self.send_json_response(401, {"error": "Authentication required"})
                return

            try:
                todo_id = int(self.path.split('/todos/')[1])
            except ValueError:
                self.send_json_response(404, {"error": "Todo not found"})
                return

            todo = todos.get(todo_id)
            if not todo or todo['user_id'] != user_id:
                self.send_json_response(404, {"error": "Todo not found"})
                return

            del todos[todo_id]
            self.send_empty_response(204)
        else:
            self.send_json_response(404, {"error": "Not found"})

class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8080)
    args = parser.parse_args()

    server = ThreadedHTTPServer(('0.0.0.0', args.port), TodoHandler)
    print(f"Server running on 0.0.0.0:{args.port}")
    server.serve_forever()

if __name__ == '__main__':
    main()