from flask import Flask, request, jsonify, make_response
import uuid
import re
from datetime import datetime, timezone

app = Flask(__name__)

users = {}  
usernames = {} 
todos = {}  
sessions = {} 

next_user_id = 1
next_todo_id = 1

def get_utc_now():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

def require_auth(f):
    def wrapper(*args, **kwargs):
        token = request.cookies.get('session_id')
        if not token or token not in sessions:
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

    if not username or not isinstance(username, str) or not re.match(r'^[a-zA-Z0-9_]{3,50}$', username):
        return jsonify({"error": "Invalid username"}), 400
    if not password or not isinstance(password, str) or len(password) < 8:
        return jsonify({"error": "Password too short"}), 400
    if username in usernames:
        return jsonify({"error": "Username already exists"}), 409

    user_id = next_user_id
    next_user_id += 1
    users[user_id] = {'username': username, 'password': password}
    usernames[username] = user_id

    return jsonify({"id": user_id, "username": username}), 201

@app.route('/login', methods=['POST'])
def login():
    data = request.get_json(silent=True) or {}
    username = data.get('username')
    password = data.get('password')

    user_id = usernames.get(username)
    if not user_id or users[user_id]['password'] != password:
        return jsonify({"error": "Invalid credentials"}), 401

    token = uuid.uuid4().hex
    sessions[token] = user_id
    
    resp = make_response(jsonify({"id": user_id, "username": username}), 200)
    resp.set_cookie('session_id', token, path='/', httponly=True)
    return resp

@app.route('/logout', methods=['POST'])
@require_auth
def logout():
    token = request.cookies.get('session_id')
    if token in sessions:
        del sessions[token]
    return jsonify({}), 200

@app.route('/me', methods=['GET'])
@require_auth
def get_me():
    token = request.cookies.get('session_id')
    user_id = sessions[token]
    return jsonify({"id": user_id, "username": users[user_id]['username']}), 200

@app.route('/password', methods=['PUT'])
@require_auth
def update_password():
    token = request.cookies.get('session_id')
    user_id = sessions[token]
    
    data = request.get_json(silent=True) or {}
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    
    if old_password != users[user_id]['password']:
        return jsonify({"error": "Invalid credentials"}), 401
    if not new_password or not isinstance(new_password, str) or len(new_password) < 8:
        return jsonify({"error": "Password too short"}), 400
        
    users[user_id]['password'] = new_password
    return jsonify({}), 200

@app.route('/todos', methods=['GET'])
@require_auth
def get_todos():
    token = request.cookies.get('session_id')
    user_id = sessions[token]
    
    user_todos = [todo for todo in todos.values() if todo['user_id'] == user_id]
    user_todos.sort(key=lambda x: x['id'])
    return jsonify(user_todos), 200

@app.route('/todos', methods=['POST'])
@require_auth
def create_todo():
    global next_todo_id
    token = request.cookies.get('session_id')
    user_id = sessions[token]
    
    data = request.get_json(silent=True) or {}
    title = data.get('title')
    
    if not isinstance(title, str) or len(title.strip()) == 0:
        return jsonify({"error": "Title is required"}), 400
        
    description = data.get('description', '')
    if not isinstance(description, str):
        description = str(description)
    
    todo_id = next_todo_id
    next_todo_id += 1
    
    now = get_utc_now()
    todos[todo_id] = {
        'id': todo_id,
        'user_id': user_id,
        'title': title,
        'description': description,
        'completed': False,
        'created_at': now,
        'updated_at': now
    }
    
    resp_todo = {k: v for k, v in todos[todo_id].items() if k != 'user_id'}
    return jsonify(resp_todo), 201

@app.route('/todos/<int:todo_id>', methods=['GET'])
@require_auth
def get_todo(todo_id):
    token = request.cookies.get('session_id')
    user_id = sessions[token]
    
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user_id:
        return jsonify({"error": "Todo not found"}), 404
        
    resp_todo = {k: v for k, v in todo.items() if k != 'user_id'}
    return jsonify(resp_todo), 200

@app.route('/todos/<int:todo_id>', methods=['PUT'])
@require_auth
def update_todo(todo_id):
    token = request.cookies.get('session_id')
    user_id = sessions[token]
    
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user_id:
        return jsonify({"error": "Todo not found"}), 404
        
    data = request.get_json(silent=True) or {}
    
    if 'title' in data:
        if not isinstance(data['title'], str) or len(data['title'].strip()) == 0:
            return jsonify({"error": "Title is required"}), 400
        todo['title'] = data['title']
        
    if 'description' in data:
        todo['description'] = data['description']
        
    if 'completed' in data:
        todo['completed'] = bool(data['completed'])
        
    todo['updated_at'] = get_utc_now()
    
    resp_todo = {k: v for k, v in todo.items() if k != 'user_id'}
    return jsonify(resp_todo), 200

@app.route('/todos/<int:todo_id>', methods=['DELETE'])
@require_auth
def delete_todo(todo_id):
    token = request.cookies.get('session_id')
    user_id = sessions[token]
    
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user_id:
        return jsonify({"error": "Todo not found"}), 404
        
    del todos[todo_id]
    return '', 204

if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    app.run(host='0.0.0.0', port=args.port, threaded=True)