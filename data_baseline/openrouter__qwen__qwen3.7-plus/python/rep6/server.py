import argparse
import secrets
import re
from datetime import datetime, timezone
from flask import Flask, request, jsonify, make_response

app = Flask(__name__)

# In-memory storage
users = {}  # id -> {"id": int, "username": str, "password": str}
username_to_id = {}
user_counter = 0

todos = {}  # id -> {"id": int, "user_id": int, "title": str, "description": str, "completed": bool, "created_at": str, "updated_at": str}
todo_counter = 0

sessions = {}  # token -> user_id


def get_current_user():
    session_id = request.cookies.get('session_id')
    if not session_id or session_id not in sessions:
        return None
    user_id = sessions[session_id]
    return users.get(user_id)


@app.route('/register', methods=['POST'])
def register():
    global user_counter
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid request"}), 400
    
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not re.match(r'^[a-zA-Z0-9_]+$', username) or not (3 <= len(username) <= 50):
        return jsonify({"error": "Invalid username"}), 400
    
    if not isinstance(password, str) or len(password) < 8:
        return jsonify({"error": "Password too short"}), 400
    
    if username in username_to_id:
        return jsonify({"error": "Username already exists"}), 409
    
    user_counter += 1
    users[user_counter] = {
        "id": user_counter,
        "username": username,
        "password": password
    }
    username_to_id[username] = user_counter
    
    return jsonify({"id": user_counter, "username": username}), 201


@app.route('/login', methods=['POST'])
def login():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid credentials"}), 401
    
    username = data.get('username')
    password = data.get('password')
    
    user_id = username_to_id.get(username)
    if not user_id:
        return jsonify({"error": "Invalid credentials"}), 401
        
    user = users.get(user_id)
    if not user or user['password'] != password:
        return jsonify({"error": "Invalid credentials"}), 401
    
    token = secrets.token_hex(32)
    sessions[token] = user['id']
    
    resp = make_response(jsonify({"id": user['id'], "username": user['username']}))
    resp.set_cookie('session_id', token, httponly=True, path='/')
    return resp, 200


@app.route('/logout', methods=['POST'])
def logout():
    user = get_current_user()
    if not user:
        return jsonify({"error": "Authentication required"}), 401
    
    session_id = request.cookies.get('session_id')
    if session_id in sessions:
        del sessions[session_id]
    
    return jsonify({}), 200


@app.route('/me', methods=['GET'])
def me():
    user = get_current_user()
    if not user:
        return jsonify({"error": "Authentication required"}), 401
    return jsonify({"id": user['id'], "username": user['username']}), 200


@app.route('/password', methods=['PUT'])
def change_password():
    user = get_current_user()
    if not user:
        return jsonify({"error": "Authentication required"}), 401
    
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid request"}), 400
    
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    
    if old_password != user['password']:
        return jsonify({"error": "Invalid credentials"}), 401
    
    if not isinstance(new_password, str) or len(new_password) < 8:
        return jsonify({"error": "Password too short"}), 400
    
    user['password'] = new_password
    return jsonify({}), 200


@app.route('/todos', methods=['GET'])
def get_todos():
    user = get_current_user()
    if not user:
        return jsonify({"error": "Authentication required"}), 401
    
    user_todos = [t for t in todos.values() if t['user_id'] == user['id']]
    user_todos.sort(key=lambda x: x['id'])
    
    res = [{k: v for k, v in t.items() if k != 'user_id'} for t in user_todos]
    return jsonify(res), 200


@app.route('/todos', methods=['POST'])
def create_todo():
    global todo_counter
    user = get_current_user()
    if not user:
        return jsonify({"error": "Authentication required"}), 401
    
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Title is required"}), 400
    
    title = data.get('title')
    if not isinstance(title, str) or title.strip() == '':
        return jsonify({"error": "Title is required"}), 400
    
    description = data.get('description', '')
    if not isinstance(description, str):
        description = ''
        
    todo_counter += 1
    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    
    todo = {
        "id": todo_counter,
        "user_id": user['id'],
        "title": title,
        "description": description,
        "completed": False,
        "created_at": now,
        "updated_at": now
    }
    todos[todo_counter] = todo
    
    resp_todo = {k: v for k, v in todo.items() if k != 'user_id'}
    return jsonify(resp_todo), 201


@app.route('/todos/<int:todo_id>', methods=['GET'])
def get_todo(todo_id):
    user = get_current_user()
    if not user:
        return jsonify({"error": "Authentication required"}), 401
    
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user['id']:
        return jsonify({"error": "Todo not found"}), 404
    
    resp_todo = {k: v for k, v in todo.items() if k != 'user_id'}
    return jsonify(resp_todo), 200


@app.route('/todos/<int:todo_id>', methods=['PUT'])
def update_todo(todo_id):
    user = get_current_user()
    if not user:
        return jsonify({"error": "Authentication required"}), 401
    
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user['id']:
        return jsonify({"error": "Todo not found"}), 404
    
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        data = {}
    
    if 'title' in data:
        if not isinstance(data['title'], str) or data['title'].strip() == '':
            return jsonify({"error": "Title is required"}), 400
        todo['title'] = data['title']
        
    if 'description' in data:
        todo['description'] = str(data['description']) if data['description'] is not None else ''
        
    if 'completed' in data and data['completed'] is not None:
        todo['completed'] = bool(data['completed'])
        
    todo['updated_at'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    
    resp_todo = {k: v for k, v in todo.items() if k != 'user_id'}
    return jsonify(resp_todo), 200


@app.route('/todos/<int:todo_id>', methods=['DELETE'])
def delete_todo(todo_id):
    user = get_current_user()
    if not user:
        return jsonify({"error": "Authentication required"}), 401
    
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user['id']:
        return jsonify({"error": "Todo not found"}), 404
    
    del todos[todo_id]
    return '', 204


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8000)
    args = parser.parse_args()
    app.run(host='0.0.0.0', port=args.port)
