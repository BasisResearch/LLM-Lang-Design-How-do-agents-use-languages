#!/usr/bin/env python3
"""
Python Flask server that interfaces with Lean backend executables
"""

from flask import Flask, request, jsonify, make_response
import subprocess
import sys
import json
from datetime import datetime
import uuid
import bcrypt
import re

app = Flask(__name__)

# In-memory store for our simulation (will communicate with Lean processes)
users_data = {}
todos_data = {}
sessions_data = {}
next_user_id = 1
next_todo_id = 1

def get_current_timestamp():
    return datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')

def call_lean_logic(operation, *args):
    """Call the Lean executable with specified operation and arguments"""
    cmd = ['./.lake/build/bin/todo_app', '--operation', operation] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise Exception(f"Lean operation failed: {result.stderr}")
    return result.stdout

def validate_username(username):
    """Check username validity per spec"""
    if len(username) < 3 or len(username) > 50:
        return False
    # Only alphanumeric and underscore
    return bool(re.match(r'^[a-zA-Z0-9_]+$', username))

def validate_password(password):
    """Check password validity per spec"""
    return len(password) >= 8

def authenticate_by_session(request):
    """Extract session cookie and validate it"""
    session_id = request.cookies.get('session_id')
    if not session_id or session_id not in sessions_data:
        return None
    return sessions_data[session_id]

@app.route('/register', methods=['POST'])
def register():
    global next_user_id
    
    data = request.json
    username = data.get('username')
    password = data.get('password')
    
    # Validate username
    if not username:
        return jsonify({"error": "Invalid username"}), 400
    if not validate_username(username):
        return jsonify({"error": "Invalid username"}), 400
        
    # Validate password
    if not password:
        return jsonify({"error": "Password too short"}), 400
    if not validate_password(password):
        return jsonify({"error": "Password too short"}), 400
    
    # Check if username already exists
    if username in users_data:
        return jsonify({"error": "Username already exists"}), 409
    
    # Hash password
    hashed_pw = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    
    # Create user
    user_id = next_user_id
    next_user_id += 1
    
    user = {
        "id": user_id,
        "username": username,
        "password_hash": hashed_pw
    }
    users_data[username] = user
    
    return jsonify({"id": user_id, "username": username}), 201

@app.route('/login', methods=['POST'])
def login():
    data = request.json
    username = data.get('username')
    password = data.get('password')
    
    # Find user
    if username not in users_data:
        return jsonify({"error": "Invalid credentials"}), 401
    
    user = users_data[username]
    if not bcrypt.checkpw(password.encode(), user["password_hash"].encode()):
        return jsonify({"error": "Invalid credentials"}), 401
    
    # Generate session
    session_id = str(uuid.uuid4())
    sessions_data[session_id] = user["id"]
    
    resp = make_response(jsonify({"id": user["id"], "username": user["username"]}))
    resp.set_cookie('session_id', session_id, httponly=True, path='/')
    return resp

@app.route('/logout', methods=['POST'])
def logout():
    session_id = request.cookies.get('session_id')
    if not session_id or session_id not in sessions_data:
        return jsonify({"error": "Authentication required"}), 401
    
    del sessions_data[session_id]
    resp = make_response(jsonify({}))
    resp.set_cookie('session_id', '', expires=0)
    return resp

@app.route('/me', methods=['GET'])
def get_me():
    user_id = authenticate_by_session(request)
    if not user_id:
        return jsonify({"error": "Authentication required"}), 401
    
    # Find user with user_id
    user = None
    for u_data in users_data.values():
        if u_data["id"] == user_id:
            user = u_data
            break
            
    if not user:
        return jsonify({"error": "Authentication required"}), 401
        
    return jsonify({"id": user["id"], "username": user["username"]}), 200

@app.route('/password', methods=['PUT'])
def change_password():
    user_id = authenticate_by_session(request)
    if not user_id:
        return jsonify({"error": "Authentication required"}), 401
    
    # Find user with user_id
    target_user = None
    target_username = ''
    for uname, u_data in users_data.items():
        if u_data["id"] == user_id:
            target_user = u_data
            target_username = uname
            break
            
    if not target_user:
        return jsonify({"error": "Authentication required"}), 401
    
    data = request.json
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    
    # Validate new password
    if not validate_password(new_password):
        return jsonify({"error": "Password too short"}), 400
    
    # Verify old password
    if not bcrypt.checkpw(old_password.encode(), target_user["password_hash"].encode()):
        return jsonify({"error": "Invalid credentials"}), 401
    
    # Update password
    users_data[target_username]["password_hash"] = bcrypt.hashpw(new_password.encode(), bcrypt.gensalt()).decode()
    
    return jsonify({}), 200

@app.route('/todos', methods=['GET'])
def get_todos():
    user_id = authenticate_by_session(request)
    if not user_id:
        return jsonify({"error": "Authentication required"}), 401
    
    # Get todos for this user
    user_todos = []
    for t_id, todo in sorted(todos_data.items()):
        if todo['userId'] == user_id:
            user_todos.append({
                "id": todo['id'],
                "title": todo['title'],
                "description": todo['description'],
                "completed": todo['completed'],
                "created_at": todo['createdAt'],
                "updated_at": todo['updatedAt']
            })
    
    return jsonify(user_todos), 200

@app.route('/todos', methods=['POST'])
def create_todo():
    user_id = authenticate_by_session(request)
    if not user_id:
        return jsonify({"error": "Authentication required"}), 401
    
    data = request.json
    title = data.get('title')
    if not title or title.strip() == "":
        return jsonify({"error": "Title is required"}), 400
        
    description = data.get('description', "")
    
    global next_todo_id
    timestamp = get_current_timestamp()
    
    todo = {
        "id": next_todo_id,
        "title": title,
        "description": description,
        "completed": False,
        "createdAt": timestamp,
        "updatedAt": timestamp,
        "userId": user_id
    }
    
    todos_data[next_todo_id] = todo
    next_todo_id += 1
    
    response_data = {
        "id": todo['id'],
        "title": todo['title'],
        "description": todo['description'],
        "completed": todo['completed'],
        "created_at": todo['createdAt'],
        "updated_at": todo['updatedAt']
    }
    
    return jsonify(response_data), 201

@app.route('/todos/<int:todo_id>', methods=['GET'])
def get_todo(todo_id):
    user_id = authenticate_by_session(request)
    if not user_id:
        return jsonify({"error": "Authentication required"}), 401
    
    if todo_id not in todos_data:
        return jsonify({"error": "Todo not found"}), 404
    
    todo = todos_data[todo_id]
    if todo['userId'] != user_id:
        return jsonify({"error": "Todo not found"}), 404
    
    response_data = {
        "id": todo['id'],
        "title": todo['title'],
        "description": todo['description'],
        "completed": todo['completed'],
        "created_at": todo['createdAt'],
        "updated_at": todo['updatedAt']
    }
    
    return jsonify(response_data), 200

@app.route('/todos/<int:todo_id>', methods=['PUT'])
def update_todo(todo_id):
    user_id = authenticate_by_session(request)
    if not user_id:
        return jsonify({"error": "Authentication required"}), 401
    
    if todo_id not in todos_data:
        return jsonify({"error": "Todo not found"}), 404
    
    todo = todos_data[todo_id]
    if todo['userId'] != user_id:
        return jsonify({"error": "Todo not found"}), 404
    
    data = request.json
    
    # Handle updates - only update fields that exist
    if 'title' in data:
        if len(str(data['title']).strip()) == 0:
            return jsonify({"error": "Title is required"}), 400
        todo['title'] = data['title']
        
    if 'description' in data:
        todo['description'] = data['description']
        
    if 'completed' in data:
        todo['completed'] = data['completed']
    
    todo['updatedAt'] = get_current_timestamp()
    
    response_data = {
        "id": todo['id'],
        "title": todo['title'],
        "description": todo['description'],
        "completed": todo['completed'],
        "created_at": todo['createdAt'],
        "updated_at": todo['updatedAt']
    }
    
    return jsonify(response_data), 200

@app.route('/todos/<int:todo_id>', methods=['DELETE'])
def delete_todo(todo_id):
    user_id = authenticate_by_session(request)
    if not user_id:
        return jsonify({"error": "Authentication required"}), 401
    
    if todo_id not in todos_data:
        return jsonify({"error": "Todo not found"}), 404
    
    todo = todos_data[todo_id]
    if todo['userId'] != user_id:
        return jsonify({"error": "Todo not found"}), 404
    
    del todos_data[todo_id]
    return "", 204

if __name__ == '__main__':
    port = int(sys.argv[sys.argv.index('--port') + 1]) if '--port' in sys.argv else 8080
    app.run(host='0.0.0.0', port=port, debug=False)