#!/usr/bin/env python3
import argparse
import re
import uuid
from datetime import datetime, timezone
from typing import Optional, Dict, Any

from flask import Flask, request, jsonify, make_response

app = Flask(__name__)

# In-memory storage
users_by_id: Dict[int, Dict[str, Any]] = {}
users_by_username: Dict[str, Dict[str, Any]] = {}
sessions: Dict[str, int] = {}
todos_by_id: Dict[int, Dict[str, Any]] = {}

next_user_id = 1
next_todo_id = 1

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')

def now_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')

def error_response(message: str, status: int):
    resp = jsonify({"error": message})
    return make_response(resp, status)

def get_current_user() -> Optional[Dict[str, Any]]:
    token = request.cookies.get('session_id')
    if not token:
        return None
    uid = sessions.get(token)
    if not uid:
        return None
    return users_by_id.get(uid)

@app.after_request
def set_default_json_content_type(response):
    # Ensure Content-Type application/json for all responses with a body (non-204)
    # DELETE 204 returns no body by our implementation.
    if response.status_code != 204:
        # Many responses are created via jsonify and already set application/json.
        # For any other response with a body, force application/json to satisfy spec.
        if not response.mimetype or response.mimetype in ('text/html', 'text/plain'):
            response.mimetype = 'application/json'
    return response

# JSON error handlers for unmatched routes and methods
@app.errorhandler(404)
def handle_404(e):
    return error_response("Not found", 404)

@app.errorhandler(405)
def handle_405(e):
    return error_response("Method not allowed", 405)

# Authentication required helper

def require_auth() -> Optional[Any]:
    user = get_current_user()
    if not user:
        return error_response("Authentication required", 401)
    return user

# Utilities to expose public user/todo objects

def public_user(user: Dict[str, Any]) -> Dict[str, Any]:
    return {"id": user["id"], "username": user["username"]}

def public_todo(todo: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": todo["id"],
        "title": todo["title"],
        "description": todo["description"],
        "completed": todo["completed"],
        "created_at": todo["created_at"],
        "updated_at": todo["updated_at"],
    }

# Routes

@app.route('/register', methods=['POST'])
def register():
    global next_user_id
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return error_response("Invalid JSON", 400)
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
        return error_response("Invalid username", 400)
    if not isinstance(password, str) or len(password) < 8:
        return error_response("Password too short", 400)
    if username in users_by_username:
        return error_response("Username already exists", 409)

    user = {"id": next_user_id, "username": username, "password": password}
    users_by_id[next_user_id] = user
    users_by_username[username] = user
    next_user_id += 1

    return make_response(jsonify(public_user(user)), 201)

@app.route('/login', methods=['POST'])
def login():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return error_response("Invalid JSON", 400)
    username = data.get('username')
    password = data.get('password')

    user = users_by_username.get(username)
    if not user or user.get('password') != password:
        return error_response("Invalid credentials", 401)

    token = uuid.uuid4().hex
    sessions[token] = user['id']

    resp = make_response(jsonify(public_user(user)), 200)
    # Set-Cookie: session_id=<token>; Path=/; HttpOnly
    resp.set_cookie('session_id', token, httponly=True, path='/')
    return resp

@app.route('/logout', methods=['POST'])
def logout():
    user = require_auth()
    if not isinstance(user, dict):
        return user  # error response
    token = request.cookies.get('session_id')
    if token in sessions:
        del sessions[token]
    resp = make_response(jsonify({}), 200)
    # Also clear the cookie client-side
    resp.set_cookie('session_id', '', httponly=True, path='/', max_age=0)
    return resp

@app.route('/me', methods=['GET'])
def me():
    user = require_auth()
    if not isinstance(user, dict):
        return user
    return jsonify(public_user(user))

@app.route('/password', methods=['PUT'])
def change_password():
    user = require_auth()
    if not isinstance(user, dict):
        return user
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return error_response("Invalid JSON", 400)
    old_password = data.get('old_password')
    new_password = data.get('new_password')

    if user.get('password') != old_password:
        return error_response("Invalid credentials", 401)
    if not isinstance(new_password, str) or len(new_password) < 8:
        return error_response("Password too short", 400)

    user['password'] = new_password
    return jsonify({})

@app.route('/todos', methods=['GET'])
def list_todos():
    user = require_auth()
    if not isinstance(user, dict):
        return user
    uid = user['id']
    # Filter and order by id ascending
    todos = [public_todo(t) for t in sorted(todos_by_id.values(), key=lambda x: x['id']) if t['user_id'] == uid]
    return jsonify(todos)

@app.route('/todos', methods=['POST'])
def create_todo():
    global next_todo_id
    user = require_auth()
    if not isinstance(user, dict):
        return user
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return error_response("Invalid JSON", 400)
    title = data.get('title')
    description = data.get('description', "")

    if not isinstance(title, str) or title.strip() == "":
        return error_response("Title is required", 400)
    if description is None:
        description = ""
    if not isinstance(description, str):
        # Coerce to string to be forgiving
        description = str(description)

    ts = now_timestamp()
    todo = {
        'id': next_todo_id,
        'user_id': user['id'],
        'title': title,
        'description': description,
        'completed': False,
        'created_at': ts,
        'updated_at': ts,
    }
    todos_by_id[next_todo_id] = todo
    next_todo_id += 1

    return make_response(jsonify(public_todo(todo)), 201)


def _get_todo_for_user(todo_id: int, user_id: int) -> Optional[Dict[str, Any]]:
    todo = todos_by_id.get(todo_id)
    if not todo:
        return None
    if todo['user_id'] != user_id:
        return None
    return todo

@app.route('/todos/<int:todo_id>', methods=['GET'])
def get_todo(todo_id: int):
    user = require_auth()
    if not isinstance(user, dict):
        return user
    todo = _get_todo_for_user(todo_id, user['id'])
    if not todo:
        return error_response("Todo not found", 404)
    return jsonify(public_todo(todo))

@app.route('/todos/<int:todo_id>', methods=['PUT'])
def update_todo(todo_id: int):
    user = require_auth()
    if not isinstance(user, dict):
        return user
    todo = _get_todo_for_user(todo_id, user['id'])
    if not todo:
        return error_response("Todo not found", 404)
    data = request.get_json(silent=True)
    if data is None:
        data = {}
    if not isinstance(data, dict):
        return error_response("Invalid JSON", 400)

    modified = False

    if 'title' in data:
        title = data.get('title')
        if not isinstance(title, str) or title.strip() == "":
            return error_response("Title is required", 400)
        if title != todo['title']:
            todo['title'] = title
            modified = True

    if 'description' in data:
        desc = data.get('description')
        if desc is None:
            desc = ""
        if not isinstance(desc, str):
            desc = str(desc)
        if desc != todo['description']:
            todo['description'] = desc
            modified = True

    if 'completed' in data:
        comp = data.get('completed')
        if not isinstance(comp, bool):
            # Be strict: if provided, must be boolean
            return error_response("Invalid JSON", 400)
        if comp != todo['completed']:
            todo['completed'] = comp
            modified = True

    if modified:
        todo['updated_at'] = now_timestamp()

    return jsonify(public_todo(todo))

@app.route('/todos/<int:todo_id>', methods=['DELETE'])
def delete_todo(todo_id: int):
    user = require_auth()
    if not isinstance(user, dict):
        return user
    todo = _get_todo_for_user(todo_id, user['id'])
    if not todo:
        return error_response("Todo not found", 404)
    del todos_by_id[todo_id]
    # 204 No Content, no body
    return ('', 204)


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    app.run(host='0.0.0.0', port=args.port, debug=False, use_reloader=False)

if __name__ == '__main__':
    main()
