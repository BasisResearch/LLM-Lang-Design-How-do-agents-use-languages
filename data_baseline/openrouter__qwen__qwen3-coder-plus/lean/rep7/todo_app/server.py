#!/usr/bin/env python3
import sys
import subprocess
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse
import threading
import hashlib

class LeanExecutor:
    def __init__(self):
        self.state = {"users": {}, "todos": {}, "sessions": {}, "nextUserId": 1, "nextTodoId": 1}
    
    def exec_command(self, command, args):
        # Placeholder command executor - would connect to Lean in production
        # For demo - implementing in Python instead
        if command == "register":
            return self.register(args)
        elif command == "login":
            return self.login(args)
        elif command == "logout":
            return self.logout(args)
        elif command == "get_me":
            return self.get_me(args)
        elif command == "update_password":
            return self.update_password(args)
        elif command == "get_todos":
            return self.get_todos(args)
        elif command == "create_todo":
            return self.create_todo(args)
        elif command == "get_todo":
            return self.get_todo(args)
        elif command == "update_todo":
            return self.update_todo(args)
        elif command == "delete_todo":
            return self.delete_todo(args)
        else:
            return {"error": "Unknown command"}, 404
    
    def register(self, args):
        username = args.get("username", "")
        password = args.get("password", "")
        
        if len(username) < 3 or len(username) > 50 or not username.replace('_', '').replace('.', '').isalnum():
            return {"error": "Invalid username"}, 400
        
        if len(password) < 8:
            return {"error": "Password too short"}, 400
        
        if self.user_exists(username):
            return {"error": "Username already exists"}, 409
        
        user_id = self.state["nextUserId"]
        self.state["users"][user_id] = {
            "id": user_id,
            "username": username,
            "password_hash": hashlib.sha256(password.encode()).hexdigest()
        }
        self.state["nextUserId"] += 1
        
        return {"id": user_id, "username": username}, 201
    
    def login(self, args):
        username = args.get("username", "")
        password = args.get("password", "")
        
        user = None
        for uid, udata in self.state["users"].items():
            if udata["username"] == username:
                user = udata
                break
        
        if not user or user["password_hash"] != hashlib.sha256(password.encode()).hexdigest():
            return {"error": "Invalid credentials"}, 401
        
        # Generate simple session ID
        session_id = f"sess_{hash(user['username'])}{len(self.state['sessions'])}"
        self.state["sessions"][session_id] = user["id"]
        
        return {"id": user["id"], "username": user["username"]}, 200
    
    def logout(self, args):
        session_id = args.get("session_id")
        if session_id and session_id in self.state["sessions"]:
            del self.state["sessions"][session_id]
        return {}, 200
    
    def get_me(self, args):
        session_id = args.get("session_id")
        user_id = self.state["sessions"].get(session_id)
        if not user_id or user_id not in self.state["users"]:
            return {"error": "Authentication required"}, 401
        
        user = self.state["users"][user_id]
        return {"id": user["id"], "username": user["username"]}, 200
    
    def user_exists(self, username):
        for udata in self.state["users"].values():
            if udata["username"] == username:
                return True
        return False
    
    def get_user_by_session(self, session_id):
        user_id = self.state["sessions"].get(session_id)
        if user_id:
            return self.state["users"].get(user_id)
        return None

    # Additional command handlers
    def get_todos(self, args):
        session_id = args.get("session_id")
        user = self.get_user_by_session(session_id)
        if not user:
            return {"error": "Authentication required"}, 401
            
        user_id = user["id"]
        user_todos = [todo for todo in self.state["todos"].values() if todo["userId"] == user_id]
        
        # Sort by ID ascending
        user_todos.sort(key=lambda x: x["id"])
        return user_todos, 200

    def create_todo(self, args):
        session_id = args.get("session_id")
        user = self.get_user_by_session(session_id)
        if not user:
            return {"error": "Authentication required"}, 401
            
        title = args.get("title", "").strip()
        if not title:
            return {"error": "Title is required"}, 400
            
        description = args.get("description", "")
        
        todo_id = self.state["nextTodoId"]
        
        # Generate current timestamp in YYYY-MM-DDTHH:MM:SSZ format
        import datetime
        timestamp = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        
        self.state["todos"][todo_id] = {
            "id": todo_id,
            "title": title,
            "description": description,
            "completed": False,
            "createdAt": timestamp,
            "updatedAt": timestamp,
            "userId": user["id"]
        }
        self.state["nextTodoId"] += 1
        
        return self.state["todos"][todo_id], 201
    
    def get_todo(self, args):
        session_id = args.get("session_id")
        user = self.get_user_by_session(session_id)
        if not user:
            return {"error": "Authentication required"}, 401
            
        todo_id = args.get("id")
        if not todo_id or str(todo_id) not in [str(k) for k in self.state["todos"].keys()]:
            return {"error": "Todo not found"}, 404
            
        todo = self.state["todos"].get(int(todo_id))
        if not todo or todo["userId"] != user["id"]:
            return {"error": "Todo not found"}, 404
        
        return todo, 200

    def delete_todo(self, args):
        session_id = args.get("session_id")
        user = self.get_user_by_session(session_id)
        if not user:
            return {"error": "Authentication required"}, 401
            
        todo_id = args.get("id")
        if not todo_id:
            return {"error": "Todo not found"}, 404
            
        todo = self.state["todos"].get(int(todo_id))
        if not todo or todo["userId"] != user["id"]:
            return {"error": "Todo not found"}, 404
        
        del self.state["todos"][int(todo_id)]
        return "", 204

    def update_todo(self, args):
        session_id = args.get("session_id")
        user = self.get_user_by_session(session_id)
        if not user:
            return {"error": "Authentication required"}, 401
            
        todo_id_str = args.get("id")
        if not todo_id_str:
            return {"error": "Todo not found"}, 404
        
        todo_id = int(todo_id_str)
        todo = self.state["todos"].get(todo_id)
        if not todo or todo["userId"] != user["id"]:
            return {"error": "Todo not found"}, 404
        
        # Update fields if provided
        if "title" in args:
            new_title = args["title"]
            if new_title == "":
                return {"error": "Title is required"}, 400
            todo["title"] = new_title
            
        if "description" in args:
            todo["description"] = args["description"]
            
        if "completed" in args:
            todo["completed"] = args["completed"]
        
        import datetime
        todo["updatedAt"] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        
        return todo, 200

    def update_password(self, args):
        session_id = args.get("session_id")
        user = self.get_user_by_session(session_id)
        if not user:
            return {"error": "Authentication required"}, 401
        
        old_password = args.get("old_password", "")
        new_password = args.get("new_password", "")
        
        expected_hash = hashlib.sha256(old_password.encode()).hexdigest()
        if user["password_hash"] != expected_hash:
            return {"error": "Invalid credentials"}, 401
        
        if len(new_password) < 8:
            return {"error": "Password too short"}, 400
            
        user["password_hash"] = hashlib.sha256(new_password.encode()).hexdigest()
        return {}, 200


class TodoServerHandler(BaseHTTPRequestHandler):
    executor = LeanExecutor()
    
    def _send_response(self, data, status_code=200, additional_headers=None):
        self.send_response(status_code)
        self.send_header('Content-type', 'application/json')
        if additional_headers:
            for header, value in additional_headers.items():
                self.send_header(header, value)
        # Always allow CORS for now
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        
        if status_code == 204:
            # 204 No Content should not have body
            return
        
        if isinstance(data, str):
            self.wfile.write(data.encode())
        else:
            json_str = json.dumps(data)
            self.wfile.write(json_str.encode())
    
    def _extract_auth_cookie(self):
        cookie_str = self.headers.get('Cookie', '')
        if not cookie_str:
            return None
            
        cookies = [c.strip().split('=', 1) for c in cookie_str.split(';')]
        session_id = None
        for cookie in cookies:
            if len(cookie) == 2 and cookie[0].strip() == 'session_id':
                session_id = cookie[1]
                break
        
        return session_id
    
    def do_POST(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length).decode('utf-8')
        
        try:
            request_json = json.loads(post_data) if post_data.strip() else {}
        except:
            request_json = {}
        
        command_map = {
            'register': ('register', {}),
            'login': ('login', {}),
            'logout': ('logout', {'session_id': self._extract_auth_cookie()}),
            'password': ('update_password', {'session_id': self._extract_auth_cookie()})
        }
        
        if len(path_parts) >= 1 and path_parts[0] in command_map:
            cmd_name, extra_args = command_map[path_parts[0]]
            
            if path_parts[0] == 'password':
                # Need old and new passwords for this request
                combined = {**extra_args, **request_json}
            else:
                combined = {**extra_args, **request_json}
                
            result, status = self.executor.exec_command(cmd_name, combined)
            
            if path_parts[0] == 'login' and status == 200:
                # For login, we need to set a cookie
                session_id = None
                for sid, uid in self.executor.state["sessions"].items():
                    if uid == result["id"]:
                        session_id = sid
                        break
                
                if session_id:
                    headers = {"Set-Cookie": f"session_id={session_id}; Path=/; HttpOnly"}
                    self._send_response(result, status, headers)
                else:
                    self._send_response(result, status)
            else:
                self._send_response(result, status)
        elif len(path_parts) >= 1 and path_parts[0] == 'todos': # CREATE TODO
            if len(path_parts) == 1:  # /todos (CREATE)
                args = {'session_id': self._extract_auth_cookie(), **request_json}
                result, status = self.executor.exec_command("create_todo", args)
                self._send_response(result, status)
            else:  # Should be handled by PUT/GET/DELETE but let's keep it
                self._send_response({"error": "Method not allowed"}, 405)
        else:
            self._send_response({"error": "Not found"}, 404)
    
    def do_GET(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        session_id = self._extract_auth_cookie()
        
        if len(path_parts) >= 1:
            if path_parts[0] == 'me':
                result, status = self.executor.exec_command("get_me", {"session_id": session_id})
                self._send_response(result, status)
            elif path_parts[0] == 'todos':
                if len(path_parts) == 1:  # /todos (GET ALL)
                    result, status = self.executor.exec_command("get_todos", {"session_id": session_id})
                    self._send_response(result, status)
                elif len(path_parts) == 2: # /todos/{id}
                    todo_id = path_parts[1]
                    result, status = self.executor.exec_command("get_todo", {
                        "session_id": session_id,
                        "id": todo_id
                    })
                    self._send_response(result, status)
                else:
                    self._send_response({"error": "Not found"}, 404)
            else:
                self._send_response({"error": "Not found"}, 404)
        else:
            self._send_response({"error": "Not found"}, 404)
    
    def do_PUT(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        content_length = int(self.headers.get('Content-Length', 0))
        put_data = self.rfile.read(content_length).decode('utf-8')
        
        try:
            request_json = json.loads(put_data) if put_data.strip() else {}
        except:
            request_json = {}
        
        session_id = self._extract_auth_cookie()
        
        if len(path_parts) >= 2 and path_parts[0] == 'todos':
            # UPDATE TODO: /todos/{id}
            todo_id = path_parts[1]
            args = {"session_id": session_id, "id": todo_id, **request_json}
            result, status = self.executor.exec_command("update_todo", args)
            self._send_response(result, status)
        elif len(path_parts) >= 1 and path_parts[0] == 'password':
            # UPDATE PASSWORD: /password
            args = {"session_id": session_id, **request_json}
            result, status = self.executor.exec_command("update_password", args)
            self._send_response(result, status)
        else:
            self._send_response({"error": "Method not allowed"}, 405)

    def do_DELETE(self):
        parsed_path = urlparse(self.path)
        path_parts = parsed_path.path.strip('/').split('/')
        
        session_id = self._extract_auth_cookie()
        
        if len(path_parts) >= 2 and path_parts[0] == 'todos':
            # DELETE TODO: /todos/{id}
            todo_id = path_parts[1]
            result, status = self.executor.exec_command("delete_todo", {
                "session_id": session_id,
                "id": todo_id
            })
            # Send the appropriate status code - if the status is 204, don't send body
            if status == 204:
                self.send_response(204)
                self.send_header('Content-type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
            else:
                self._send_response(result, status)
        else:
            self._send_response({"error": "Not found"}, 404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 3000
    server_address = ('0.0.0.0', port)
    
    httpd = HTTPServer(server_address, TodoServerHandler)
    
    print(f'Todo API server starting on 0.0.0.0:{port}')
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        httpd.shutdown()

