import sys
import argparse
import uuid
import re
from datetime import datetime, timezone
from flask import Flask, request, jsonify, make_response

app = Flask(__name__)

# In-memory storage
users = {}  # id -> {"id": int, "username": str, "password": str}
usernames = {}  # username -> id
todos = {}  # id -> {"id": int, "user_id": int, "title": str, "description": str, "completed": bool, "created_at": str, "updated_at": str}
sessions = {}  # session_id -> user_id

next_user_id = 1
next_todo_id = 1

def get_timestamp():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def require_auth(f):
    def wrapper(*args, **kwargs):
        session_id = request.cookies.get('session_id')
        if not session_id or session_id not in sessions:
            return jsonify({"error": "Authentication required"}), 401
        return f(*args, **kwargs)
    wrapper.__name__ = f.__name__
    return wrapper

@app.route('/register', methods=['POST'])
def register():
    global next_user_id
    data = request.get_json(silent=True) or {}
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not re.fullmatch(r'[a-zA-Z0-9_]{3,50}', username):
        return jsonify({"error": "Invalid username"}), 400
    
    if not isinstance(password, str) or len(password) < 8:
        return jsonify({"error": "Password too short"}), 400
        
    if username in usernames:
        return jsonify({"error": "Username already exists"}), 409
        
    user_id = next_user_id
    next_user_id += 1
    
    users[user_id] = {
        "id": user_id,
        "username": username,
        "password": password
    }
    usernames[username] = user_id
    
    return jsonify({"id": user_id, "username": username}), 201

@app.route('/login', methods=['POST'])
def login():
    data = request.get_json(silent=True) or {}
    username = data.get('username')
    password = data.get('password')
    
    user_id = usernames.get(username)
    if user_id is None or users[user_id]['password'] != password:
        return jsonify({"error": "Invalid credentials"}), 401
        
    token = uuid.uuid4().hex
    sessions[token] = user_id
    
    response = make_response(jsonify({"id": user_id, "username": username}))
    response.set_cookie('session_id', token, path='/', httponly=True)
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
    session_id = request.cookies.get('session_id')
    user_id = sessions[session_id]
    user = users[user_id]
    return jsonify({"id": user["id"], "username": user["username"]})

@app.route('/password', methods=['PUT'])
@require_auth
def change_password():
    session_id = request.cookies.get('session_id')
    user_id = sessions[session_id]
    user = users[user_id]
    
    data = request.get_json(silent=True) or {}
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    
    if old_password != user['password']:
        return jsonify({"error": "Invalid credentials"}), 401
        
    if not isinstance(new_password, str) or len(new_password) < 8:
        return jsonify({"error": "Password too short"}), 400
        
    user['password'] = new_password
    return jsonify({}), 200

@app.route('/todos', methods=['GET'])
@require_auth
def get_todos():
    session_id = request.cookies.get('session_id')
    user_id = sessions[session_id]
    
    user_todos = [todo for todo in todos.values() if todo['user_id'] == user_id]
    user_todos.sort(key=lambda x: x['id'])
    
    response_todos = []
    for t in user_todos:
        response_todos.append({
            "id": t["id"],
            "title": t["title"],
            "description": t["description"],
            "completed": t["completed"],
            "created_at": t["created_at"],
            "updated_at": t["updated_at"]
        })
    return jsonify(response_todos)

@app.route('/todos', methods=['POST'])
@require_auth
def create_todo():
    global next_todo_id
    session_id = request.cookies.get('session_id')
    user_id = sessions[session_id]
    
    data = request.get_json(silent=True) or {}
    title = data.get('title')
    description = data.get('description')
    if description is None:
        description = ''
    
    if not isinstance(title, str) or not title:
        return jsonify({"error": "Title is required"}), 400
        
    todo_id = next_todo_id
    next_todo_id += 1
    
    now = get_timestamp()
    todo = {
        "id": todo_id,
        "user_id": user_id,
        "title": title,
        "description": description,
        "completed": False,
        "created_at": now,
        "updated_at": now
    }
    todos[todo_id] = todo
    
    response_todo = {
        "id": todo["id"],
        "title": todo["title"],
        "description": todo["description"],
        "completed": todo["completed"],
        "created_at": todo["created_at"],
        "updated_at": todo["updated_at"]
    }
    
    return jsonify(response_todo), 201

@app.route('/todos/<int:todo_id>', methods=['GET'])
@require_auth
def get_todo(todo_id):
    session_id = request.cookies.get('session_id')
    user_id = sessions[session_id]
    
    if todo_id not in todos or todos[todo_id]['user_id'] != user_id:
        return jsonify({"error": "Todo not found"}), 404
        
    todo = todos[todo_id]
    return jsonify({
        "id": todo["id"],
        "title": todo["title"],
        "description": todo["description"],
        "completed": todo["completed"],
        "created_at": todo["created_at"],
        "updated_at": todo["updated_at"]
    })

@app.route('/todos/<int:todo_id>', methods=['PUT'])
@require_auth
def update_todo(todo_id):
    session_id = request.cookies.get('session_id')
    user_id = sessions[session_id]
    
    if todo_id not in todos or todos[todo_id]['user_id'] != user_id:
        return jsonify({"error": "Todo not found"}), 404
        
    data = request.get_json(silent=True) or {}
    todo = todos[todo_id]
    
    if 'title' in data:
        if not isinstance(data['title'], str) or not data['title']:
            return jsonify({"error": "Title is required"}), 400
        todo['title'] = data['title']
        
    if 'description' in data:
        todo['description'] = data['description'] if data['description'] is not None else ''
        
    if 'completed' in data:
        todo['completed'] = bool(data['completed'])
        
    todo['updated_at'] = get_timestamp()
    
    return jsonify({
        "id": todo["id"],
        "title": todo["title"],
        "description": todo["description"],
        "completed": todo["completed"],
        "created_at": todo["created_at"],
        "updated_at": todo["updated_at"]
    })

@app.route('/todos/<int:todo_id>', methods=['DELETE'])
@require_auth
def delete_todo(todo_id):
    session_id = request.cookies.get('session_id')
    user_id = sessions[session_id]
    
    if todo_id not in todos or todos[todo_id]['user_id'] != user_id:
        return jsonify({"error": "Todo not found"}), 404
        
    del todos[todo_id]
    return '', 204

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8080)
    args = parser.parse_args()
    app.run(host='0.0.0.0', port=args.port)
