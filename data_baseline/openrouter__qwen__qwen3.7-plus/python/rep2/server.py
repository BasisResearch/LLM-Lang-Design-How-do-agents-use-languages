import sys
import argparse
import uuid
import re
import hashlib
from datetime import datetime, timezone
from flask import Flask, request, jsonify, make_response

app = Flask(__name__)

# In-memory storage
users = {}  # username -> {"id": int, "password_hash": str}
user_id_counter = 1

todos = {}  # todo_id -> {"id": int, "user_id": int, "title": str, "description": str, "completed": bool, "created_at": str, "updated_at": str}
todo_id_counter = 1

sessions = {}  # session_token -> user_id

def require_auth(f):
    def wrapper(*args, **kwargs):
        session_id = request.cookies.get('session_id')
        if not session_id or session_id not in sessions:
            return jsonify({"error": "Authentication required"}), 401
        request.user_id = sessions[session_id]
        return f(*args, **kwargs)
    wrapper.__name__ = f.__name__
    return wrapper

@app.route('/register', methods=['POST'])
def register():
    global user_id_counter
    data = request.get_json(silent=True) or {}
    username = data.get('username')
    password = data.get('password')
    
    if not isinstance(username, str) or not re.match(r'^[a-zA-Z0-9_]{3,50}$', username):
        return jsonify({"error": "Invalid username"}), 400
    
    if not isinstance(password, str) or len(password) < 8:
        return jsonify({"error": "Password too short"}), 400
        
    if username in users:
        return jsonify({"error": "Username already exists"}), 409
        
    user_id = user_id_counter
    user_id_counter += 1
    
    password_hash = hashlib.sha256(password.encode('utf-8')).hexdigest()
    users[username] = {"id": user_id, "password_hash": password_hash}
    
    return jsonify({"id": user_id, "username": username}), 201

@app.route('/login', methods=['POST'])
def login():
    data = request.get_json(silent=True) or {}
    username = data.get('username')
    password = data.get('password')
    
    user = users.get(username)
    password_hash = hashlib.sha256(password.encode('utf-8')).hexdigest() if isinstance(password, str) else ""
    
    if not user or user['password_hash'] != password_hash:
        return jsonify({"error": "Invalid credentials"}), 401
        
    session_token = uuid.uuid4().hex
    sessions[session_token] = user['id']
    
    response = make_response(jsonify({"id": user['id'], "username": username}))
    response.set_cookie('session_id', session_token, httponly=True, path='/')
    return response

@app.route('/logout', methods=['POST'])
@require_auth
def logout():
    session_id = request.cookies.get('session_id')
    if session_id in sessions:
        del sessions[session_id]
    return jsonify({}), 200

@app.route('/me', methods=['GET'])
@require_auth
def me():
    user_id = request.user_id
    for username, user in users.items():
        if user['id'] == user_id:
            return jsonify({"id": user['id'], "username": username}), 200
    return jsonify({"error": "User not found"}), 404

@app.route('/password', methods=['PUT'])
@require_auth
def change_password():
    data = request.get_json(silent=True) or {}
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    
    if not isinstance(new_password, str) or len(new_password) < 8:
        return jsonify({"error": "Password too short"}), 400
        
    current_username = None
    for username, user in users.items():
        if user['id'] == request.user_id:
            current_username = username
            break
            
    if not current_username:
        return jsonify({"error": "Invalid credentials"}), 401
        
    old_password_hash = hashlib.sha256(old_password.encode('utf-8')).hexdigest() if isinstance(old_password, str) else ""
    if old_password_hash != users[current_username]['password_hash']:
        return jsonify({"error": "Invalid credentials"}), 401
        
    users[current_username]['password_hash'] = hashlib.sha256(new_password.encode('utf-8')).hexdigest()
    return jsonify({}), 200

@app.route('/todos', methods=['GET'])
@require_auth
def get_todos():
    user_todos = [todo for todo in todos.values() if todo['user_id'] == request.user_id]
    user_todos.sort(key=lambda x: x['id'])
    response_todos = []
    for todo in user_todos:
        response_todos.append({
            "id": todo["id"],
            "title": todo["title"],
            "description": todo["description"],
            "completed": todo["completed"],
            "created_at": todo["created_at"],
            "updated_at": todo["updated_at"]
        })
    return jsonify(response_todos), 200

@app.route('/todos', methods=['POST'])
@require_auth
def create_todo():
    global todo_id_counter
    data = request.get_json(silent=True) or {}
    title = data.get('title')
    description = data.get('description')
    
    if not isinstance(title, str) or title.strip() == '':
        return jsonify({"error": "Title is required"}), 400
        
    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    
    new_todo = {
        "id": todo_id_counter,
        "user_id": request.user_id,
        "title": title,
        "description": description if isinstance(description, str) else '',
        "completed": False,
        "created_at": now,
        "updated_at": now
    }
    todos[todo_id_counter] = new_todo
    todo_id_counter += 1
    
    response_todo = {
        "id": new_todo["id"],
        "title": new_todo["title"],
        "description": new_todo["description"],
        "completed": new_todo["completed"],
        "created_at": new_todo["created_at"],
        "updated_at": new_todo["updated_at"]
    }
    return jsonify(response_todo), 201

@app.route('/todos/<int:todo_id>', methods=['GET'])
@require_auth
def get_todo(todo_id):
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != request.user_id:
        return jsonify({"error": "Todo not found"}), 404
        
    response_todo = {
        "id": todo["id"],
        "title": todo["title"],
        "description": todo["description"],
        "completed": todo["completed"],
        "created_at": todo["created_at"],
        "updated_at": todo["updated_at"]
    }
    return jsonify(response_todo), 200

@app.route('/todos/<int:todo_id>', methods=['PUT'])
@require_auth
def update_todo(todo_id):
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != request.user_id:
        return jsonify({"error": "Todo not found"}), 404
        
    data = request.get_json(silent=True) or {}
    
    if 'title' in data:
        if not isinstance(data['title'], str) or data['title'].strip() == '':
            return jsonify({"error": "Title is required"}), 400
        todo['title'] = data['title']
        
    if 'description' in data:
        if not isinstance(data['description'], str):
            return jsonify({"error": "Invalid description value"}), 400
        todo['description'] = data['description']
        
    if 'completed' in data:
        if not isinstance(data['completed'], bool):
            return jsonify({"error": "Invalid completed value"}), 400
        todo['completed'] = data['completed']
        
    todo['updated_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    
    response_todo = {
        "id": todo["id"],
        "title": todo["title"],
        "description": todo["description"],
        "completed": todo["completed"],
        "created_at": todo["created_at"],
        "updated_at": todo["updated_at"]
    }
    return jsonify(response_todo), 200

@app.route('/todos/<int:todo_id>', methods=['DELETE'])
@require_auth
def delete_todo(todo_id):
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != request.user_id:
        return jsonify({"error": "Todo not found"}), 404
        
    del todos[todo_id]
    response = make_response('', 204)
    return response

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    
    app.run(host='0.0.0.0', port=args.port)
