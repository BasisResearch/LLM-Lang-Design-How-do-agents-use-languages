from datetime import datetime, timezone 
from typing import Any, Dict, Optional, List, Union
import uuid
import hashlib
import re
from flask import Flask, request, jsonify, make_response
from flask.wrappers import Response
from werkzeug.http import parse_cookie
from functools import wraps

class TodoModel:
    def __init__(self, id: int, user_id: int, title: str, description: str, completed: bool) -> None:
        self.id = id
        self.user_id = user_id  # Added field to track ownership
        self.title = title
        self.description = description
        self.completed = completed
        now_str = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        self.created_at = now_str
        self.updated_at = now_str
        
    def to_dict(self) -> Dict[str, Any]:
        return {
            'id': self.id,
            'title': self.title,
            'description': self.description,
            'completed': self.completed,
            'created_at': self.created_at,
            'updated_at': self.updated_at
        }
        
    def update(self, updates: Dict[str, Any]) -> Dict[str, Any]:
        """Update existing todo with partial changes."""
        if 'title' in updates:
            new_title = updates['title']
            if not new_title.strip():
                raise ValueError("Title is required")
            self.title = new_title
        if 'description' in updates:
            self.description = updates['description']
        if 'completed' in updates:
            self.completed = updates['completed']
        self.updated_at = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        return self.to_dict()

class UserModel:
    def __init__(self, id: int, username: str, password_hash: str) -> None:
        self.id = id
        self.username = username
        self.password_hash = password_hash  # Store the hash as is

class Storage:
    def __init__(self) -> None:
        self.users: Dict[int, UserModel] = {}
        self.todos: Dict[int, TodoModel] = {}
        self.sessions: Dict[str, int] = {}  # session_id -> user_id mapping
        self._next_user_id = 1
        self._next_todo_id = 1
        self._usernames_index: Dict[str, int] = {}  # username -> user_id
    
    def create_user(self, username: str, password: str) -> Optional[UserModel]:
        if username in self._usernames_index:
            return None
            
        user_id = self._next_user_id
        hashed_password = hashlib.sha256(password.encode()).hexdigest()
        user = UserModel(user_id, username, hashed_password)
        
        self.users[user_id] = user
        self._usernames_index[username] = user_id
        self._next_user_id += 1
        
        return user
        
    def get_user_by_username(self, username: str) -> Optional[UserModel]:
        user_id = self._usernames_index.get(username)
        if user_id is None:
            return None
        return self.users.get(user_id)
    
    def authenticate_user(self, username: str, password: str) -> Optional[UserModel]:
        user = self.get_user_by_username(username)
        if not user:
            return None
        password_hash = hashlib.sha256(password.encode()).hexdigest()
        if user.password_hash != password_hash:
            return None
        return user
    
    def add_session(self, session_id: str, user_id: int) -> None:
        self.sessions[session_id] = user_id
    
    def get_user_by_session(self, session_id: str) -> Optional[UserModel]:
        user_id = self.sessions.get(session_id)
        if user_id is None:
            return None
        return self.users.get(user_id)
    
    def delete_session(self, session_id: str) -> None:
        if session_id in self.sessions:
            del self.sessions[session_id]
    
    def create_todo(self, user_id: int, title: str, description: str) -> TodoModel:
        todo_id = self._next_todo_id
        todo = TodoModel(todo_id, user_id, title, description, False)
        self.todos[todo_id] = todo
        self._next_todo_id += 1
        return todo
    
    def get_todos_for_user(self, user_id: int) -> List[TodoModel]:
        return [todo for todo in self.todos.values() if todo.user_id == user_id]
    
    def get_todo_by_id(self, todo_id: int) -> Optional[TodoModel]:
        return self.todos.get(todo_id)
    
    def update_todo(self, todo_id: int, updates: Dict[str, Any]) -> Optional[TodoModel]:
        todo = self.todos.get(todo_id)
        if todo and 'title' in updates:
            title = updates['title']
            if title == "" or (isinstance(title, str) and not title.strip()):
                return None
        if todo:
            todo.update(updates)
            return todo
        return None
    
    def delete_todo(self, todo_id: int) -> bool:
        if todo_id in self.todos:
            del self.todos[todo_id]
            return True
        return False

def validate_username(username: str) -> bool:
    if not isinstance(username, str) or len(username) < 3 or len(username) > 50:
        return False
    # Check if matches alphanumeric and underscore pattern
    pattern = re.compile(r'^[a-zA-Z0-9_]+$')
    return bool(pattern.match(username))

def validate_password(password: str) -> bool:
    return isinstance(password, str) and len(password) >= 8

def create_app() -> Flask:
    app = Flask(__name__)
    app.secret_key = str(uuid.uuid4())  # Needed for security
    
    storage = Storage()
    
    def auth_required(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            cookies = parse_cookie(request.headers.get('Cookie', ''))
            session_id = cookies.get('session_id')
            
            if not session_id:
                response = make_response(jsonify({"error": "Authentication required"}))
                response.status_code = 401
                return response
                
            user = storage.get_user_by_session(session_id)
            if not user:
                response = make_response(jsonify({"error": "Authentication required"}))
                response.status_code = 401
                return response
                
            return f(user, *args, **kwargs)
        return decorated
    
    @app.route('/register', methods=['POST'])
    def register():
        try:
            data = request.get_json()
            if not data:
                response = make_response(jsonify({"error": "Invalid input"}))
                response.status_code = 400
                return response
                
            username = data.get('username')
            password = data.get('password')
            
            if not username or not validate_username(username):
                response = make_response(jsonify({"error": "Invalid username"}))
                response.status_code = 400
                return response
                
            if not password or not validate_password(password):
                response = make_response(jsonify({"error": "Password too short"}))
                response.status_code = 400
                return response
                
            user = storage.create_user(username, password)
            if not user:
                response = make_response(jsonify({"error": "Username already exists"}))
                response.status_code = 409
                return response
                
            response = make_response(jsonify({'id': user.id, 'username': user.username}))
            response.status_code = 201
            return response
        except Exception:
            response = make_response(jsonify({"error": "Invalid input"}))
            response.status_code = 400
            return response

    @app.route('/login', methods=['POST'])
    def login():
        try:
            data = request.get_json()
            if not data:
                response = make_response(jsonify({"error": "Invalid input"}))
                response.status_code = 400
                return response
                
            username = data.get('username')
            password = data.get('password')
            
            if not username or not password:
                response = make_response(jsonify({"error": "Missing username or password"}))
                response.status_code = 400
                return response
            
            user = storage.authenticate_user(username, password)
            if not user:
                response = make_response(jsonify({"error": "Invalid credentials"}))
                response.status_code = 401
                return response
                
            session_id = str(uuid.uuid4())
            storage.add_session(session_id, user.id)
            
            response = make_response(jsonify({'id': user.id, 'username': user.username}))
            response.status_code = 200
            # Set cookie with HttpOnly flag
            response.set_cookie(
                'session_id',
                session_id,
                path='/',
                httponly=True
            )
            return response
        except Exception:
            response = make_response(jsonify({"error": "Invalid input"}))
            response.status_code = 400
            return response

    @app.route('/logout', methods=['POST'])
    @auth_required
    def logout(_):
        cookies = parse_cookie(request.headers.get('Cookie', ''))
        session_id = cookies.get('session_id')
        
        if session_id:
            storage.delete_session(session_id)
        
        response = make_response(jsonify({}))
        return response

    @app.route('/me', methods=['GET'])
    @auth_required
    def get_me(current_user):
        response = make_response(jsonify({'id': current_user.id, 'username': current_user.username}))
        return response

    @app.route('/password', methods=['PUT'])
    @auth_required
    def change_password(current_user):
        try:
            data = request.get_json()
            if not data:
                response = make_response(jsonify({"error": "Invalid input"}))
                response.status_code = 400
                return response
                
            old_password = data.get('old_password')
            new_password = data.get('new_password')
            
            if not old_password or not new_password:
                response = make_response(jsonify({"error": "Both old and new passwords required"}))
                response.status_code = 400
                return response
            
            # Verify the old password
            old_password_hash = hashlib.sha256(old_password.encode()).hexdigest()
            if old_password_hash != current_user.password_hash:
                response = make_response(jsonify({"error": "Invalid credentials"}))
                response.status_code = 401
                return response
            
            # Validate the new password
            if not validate_password(new_password):
                response = make_response(jsonify({"error": "Password too short"}))
                response.status_code = 400
                return response
            
            new_password_hash = hashlib.sha256(new_password.encode()).hexdigest()
            current_user.password_hash = new_password_hash
            
            response = make_response(jsonify({}))
            return response
        except Exception:
            response = make_response(jsonify({"error": "Invalid input"}))
            response.status_code = 400
            return response

    @app.route('/todos', methods=['GET'])
    @auth_required
    def get_todos(current_user):
        todos = storage.get_todos_for_user(current_user.id)
        # Sort by ID ascending
        sorted_todos = sorted(todos, key=lambda x: x.id)
        response = make_response(jsonify([todo.to_dict() for todo in sorted_todos]))
        return response

    @app.route('/todos', methods=['POST'])
    @auth_required
    def create_todo(current_user):
        try:
            data = request.get_json()
            if not data:
                response = make_response(jsonify({"error": "Invalid input"}))
                response.status_code = 400
                return response
            
            title = data.get('title', '').strip()
            description = data.get('description', '')
            
            if not title:
                response = make_response(jsonify({"error": "Title is required"}))
                response.status_code = 400
                return response
            
            todo = storage.create_todo(current_user.id, title, description)
            response = make_response(jsonify(todo.to_dict()))
            response.status_code = 201
            return response
        except Exception:
            response = make_response(jsonify({"error": "Invalid input"}))
            response.status_code = 400
            return response

    @app.route('/todos/<int:id>', methods=['GET'])
    @auth_required
    def get_todo_by_id_route(current_user, id):  # Renamed to avoid conflict with method name
        todo = storage.get_todo_by_id(id)
        if not todo or todo.user_id != current_user.id:
            response = make_response(jsonify({"error": "Todo not found"}))
            response.status_code = 404
            return response
        
        return make_response(jsonify(todo.to_dict()))

    @app.route('/todos/<int:id>', methods=['PUT'])
    @auth_required
    def update_todo_by_id(current_user, id):  # Renamed to avoid conflict with method name
        todo = storage.get_todo_by_id(id)
        if not todo or todo.user_id != current_user.id:
            response = make_response(jsonify({"error": "Todo not found"}))
            response.status_code = 404
            return response
            
        try:
            data = request.get_json()
            if not data:
                response = make_response(jsonify({"error": "Invalid input"}))
                response.status_code = 400
                return response
                
            # Allow partial updates - pass the received fields to update method
            updated_todo_data = todo.update(data)
            return make_response(jsonify(updated_todo_data))
        except ValueError as e:
            # This catches ValueError raised by update when title is empty
            response = make_response(jsonify({"error": str(e)}))
            response.status_code = 400
            return response
        except Exception:
            response = make_response(jsonify({"error": "Invalid input"}))
            response.status_code = 400
            return response

    @app.route('/todos/<int:id>', methods=['DELETE'])
    @auth_required
    def delete_todo_by_id(current_user, id):  # Renamed to avoid conflict with method name
        todo = storage.get_todo_by_id(id)
        if not todo or todo.user_id != current_user.id:
            response = make_response(jsonify({"error": "Todo not found"}))
            response.status_code = 404
            return response
        
        success = storage.delete_todo(id)
        if not success:
            response = make_response(jsonify({"error": "Todo not found"}))
            response.status_code = 404
            return response
            
        response = make_response("")
        response.status_code = 204
        return response

    # Add a catch-all to ensure all endpoints return proper content-type  
    @app.after_request
    def after_request(response: Response) -> Response:
        # Always ensure JSON content-type for non-204 responses 
        if response.status_code != 204 and response.content_type and not response.content_type.startswith('application/json'):
            response.headers['Content-Type'] = 'application/json'
        elif response.status_code != 204 and not response.content_type:
            response.headers['Content-Type'] = 'application/json'
        return response

    return app


if __name__ == '__main__':
    import sys
    import argparse
    
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, default=8080, help='Port to listen on')
    args = parser.parse_args()
    
    app = create_app()
    app.run(host='0.0.0.0', port=args.port, debug=False)