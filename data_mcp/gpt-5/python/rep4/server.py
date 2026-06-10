import argparse
import uuid
from flask import Flask, request, jsonify, make_response, Response
from datetime import datetime, timezone
import re
from typing import Dict, Any

app = Flask(__name__)

# In-memory storage
users: Dict[int, Dict[str, Any]] = {}
user_passwords: Dict[int, str] = {}
username_to_id: Dict[str, int] = {}
sessions: Dict[str, int] = {}

next_user_id = 1

# Todos storage
# Each todo: {id, user_id, title, description, completed, created_at, updated_at}
todos: Dict[int, Dict[str, Any]] = {}
next_todo_id = 1

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def now_iso_utc() -> str:
    # ISO 8601 UTC timestamp with second precision, e.g., 2025-01-15T09:30:00Z
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def error_json(message: str, code: int):
    resp = jsonify({"error": message})
    return resp, code


def get_json_body() -> Any:
    # Parse JSON body safely; return None if invalid or empty
    return request.get_json(silent=True)


def get_authenticated_user_id():
    token = request.cookies.get('session_id')
    if not token:
        return None
    uid = sessions.get(token)
    return uid


def require_auth():
    uid = get_authenticated_user_id()
    if uid is None:
        return None, error_json("Authentication required", 401)
    return uid, None


@app.after_request
def set_json_content_type(response):
    # Ensure Content-Type is application/json for non-204 responses
    if response.status_code != 204:
        # Only set if body exists and mimetype not already application/json
        # Using jsonify will set it already; this enforces consistency for empty dicts, etc.
        response.headers.setdefault('Content-Type', 'application/json')
    return response


@app.route('/register', methods=['POST'])
def register():
    global next_user_id
    data = get_json_body()
    if not isinstance(data, dict):
        return error_json("Invalid JSON", 400)
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
        return error_json("Invalid username", 400)
    if not isinstance(password, str) or len(password) < 8:
        return error_json("Password too short", 400)
    if username in username_to_id:
        return error_json("Username already exists", 409)

    uid = next_user_id
    next_user_id += 1
    user = {"id": uid, "username": username}
    users[uid] = user
    user_passwords[uid] = password
    username_to_id[username] = uid

    return jsonify(user), 201


@app.route('/login', methods=['POST'])
def login():
    data = get_json_body()
    if not isinstance(data, dict):
        return error_json("Invalid JSON", 400)
    username = data.get('username')
    password = data.get('password')
    if not isinstance(username, str) or not isinstance(password, str):
        return error_json("Invalid credentials", 401)

    uid = username_to_id.get(username)
    if not uid or user_passwords.get(uid) != password:
        return error_json("Invalid credentials", 401)

    token = uuid.uuid4().hex
    sessions[token] = uid

    user = users[uid]
    resp = make_response(jsonify(user), 200)
    # Set session cookie as HttpOnly
    resp.headers['Set-Cookie'] = f"session_id={token}; Path=/; HttpOnly"
    return resp


@app.route('/logout', methods=['POST'])
def logout():
    uid = get_authenticated_user_id()
    if uid is None:
        return error_json("Authentication required", 401)
    # Invalidate token
    token = request.cookies.get('session_id')
    if token in sessions:
        del sessions[token]
    resp = make_response(jsonify({}), 200)
    # Also clear cookie on client side (optional per spec)
    resp.headers['Set-Cookie'] = 'session_id=; Path=/; HttpOnly; Max-Age=0'
    return resp


@app.route('/me', methods=['GET'])
def me():
    uid, err = require_auth()
    if err:
        return err
    user = users.get(uid)
    return jsonify(user), 200


@app.route('/password', methods=['PUT'])
def change_password():
    uid, err = require_auth()
    if err:
        return err
    data = get_json_body()
    if not isinstance(data, dict):
        return error_json("Invalid JSON", 400)
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    if user_passwords.get(uid) != old_password:
        return error_json("Invalid credentials", 401)
    if not isinstance(new_password, str) or len(new_password) < 8:
        return error_json("Password too short", 400)
    user_passwords[uid] = new_password
    return jsonify({}), 200


@app.route('/todos', methods=['GET'])
def list_todos():
    uid, err = require_auth()
    if err:
        return err
    # Return todos for this user ordered by id ascending
    user_todos = [t for t in todos.values() if t['user_id'] == uid]
    user_todos.sort(key=lambda t: t['id'])
    # Exclude user_id from output
    output = [
        {
            'id': t['id'],
            'title': t['title'],
            'description': t['description'],
            'completed': t['completed'],
            'created_at': t['created_at'],
            'updated_at': t['updated_at'],
        }
        for t in user_todos
    ]
    return jsonify(output), 200


@app.route('/todos', methods=['POST'])
def create_todo():
    global next_todo_id
    uid, err = require_auth()
    if err:
        return err
    data = get_json_body()
    if not isinstance(data, dict):
        return error_json("Invalid JSON", 400)
    title = data.get('title')
    description = data.get('description', "")
    if title is None or not isinstance(title, str) or title.strip() == "":
        return error_json("Title is required", 400)
    if not isinstance(description, str):
        return error_json("Invalid JSON", 400)
    tid = next_todo_id
    next_todo_id += 1
    ts = now_iso_utc()
    todo = {
        'id': tid,
        'user_id': uid,
        'title': title,
        'description': description,
        'completed': False,
        'created_at': ts,
        'updated_at': ts,
    }
    todos[tid] = todo
    output = {
        'id': todo['id'],
        'title': todo['title'],
        'description': todo['description'],
        'completed': todo['completed'],
        'created_at': todo['created_at'],
        'updated_at': todo['updated_at'],
    }
    return jsonify(output), 201


def get_todo_if_authorized(uid: int, tid: int):
    todo = todos.get(tid)
    if not todo or todo['user_id'] != uid:
        return None
    return todo


@app.route('/todos/<int:tid>', methods=['GET'])
def get_todo(tid: int):
    uid, err = require_auth()
    if err:
        return err
    todo = get_todo_if_authorized(uid, tid)
    if not todo:
        return error_json("Todo not found", 404)
    output = {
        'id': todo['id'],
        'title': todo['title'],
        'description': todo['description'],
        'completed': todo['completed'],
        'created_at': todo['created_at'],
        'updated_at': todo['updated_at'],
    }
    return jsonify(output), 200


@app.route('/todos/<int:tid>', methods=['PUT'])
def update_todo(tid: int):
    uid, err = require_auth()
    if err:
        return err
    todo = get_todo_if_authorized(uid, tid)
    if not todo:
        return error_json("Todo not found", 404)
    data = get_json_body()
    if not isinstance(data, dict):
        return error_json("Invalid JSON", 400)

    # Validate title if present
    if 'title' in data:
        new_title = data.get('title')
        if new_title is None or not isinstance(new_title, str) or new_title.strip() == "":
            return error_json("Title is required", 400)
    if 'description' in data:
        if data.get('description') is not None and not isinstance(data.get('description'), str):
            return error_json("Invalid JSON", 400)
    if 'completed' in data:
        if not isinstance(data.get('completed'), bool):
            return error_json("Invalid JSON", 400)

    modified = False
    if 'title' in data:
        todo['title'] = data['title']
        modified = True
    if 'description' in data:
        todo['description'] = data['description'] if data['description'] is not None else ''
        modified = True
    if 'completed' in data:
        todo['completed'] = data['completed']
        modified = True

    if modified:
        todo['updated_at'] = now_iso_utc()

    output = {
        'id': todo['id'],
        'title': todo['title'],
        'description': todo['description'],
        'completed': todo['completed'],
        'created_at': todo['created_at'],
        'updated_at': todo['updated_at'],
    }
    return jsonify(output), 200


@app.route('/todos/<int:tid>', methods=['DELETE'])
def delete_todo(tid: int):
    uid, err = require_auth()
    if err:
        return err
    todo = get_todo_if_authorized(uid, tid)
    if not todo:
        return error_json("Todo not found", 404)
    del todos[tid]
    return Response(status=204)


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    # Bind to 0.0.0.0:PORT
    app.run(host='0.0.0.0', port=args.port)


if __name__ == '__main__':
    main()
