#!/usr/bin/env python3
import argparse
import re
import uuid
from datetime import datetime, timezone
from flask import Flask, request, jsonify, make_response

app = Flask(__name__)

# In-memory storage
users = {}  # user_id -> {id, username, password}
username_index = {}  # username -> user_id
sessions = {}  # session_token -> user_id

todos = {}  # todo_id -> {id, user_id, title, description, completed, created_at, updated_at}

next_user_id = 1
next_todo_id = 1

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')


def now_iso8601_utc_seconds():
    # ISO 8601 UTC timestamp with second precision
    return datetime.utcnow().replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')


def json_error(message, status_code):
    resp = jsonify({"error": message})
    return resp, status_code


def get_json_body():
    if not request.data:
        return None, 'Invalid JSON'
    try:
        data = request.get_json(force=True, silent=False)
    except Exception:
        return None, 'Invalid JSON'
    if data is None or not isinstance(data, dict):
        return None, 'Invalid JSON'
    return data, None


def get_authenticated_user():
    token = request.cookies.get('session_id')
    if not token:
        return None
    uid = sessions.get(token)
    if uid is None:
        return None
    user = users.get(uid)
    return user


def require_auth():
    user = get_authenticated_user()
    if not user:
        return None, (json_error('Authentication required', 401))
    return user, None


@app.after_request
def set_json_content_type(response):
    # Ensure Content-Type is application/json for all responses except 204 (DELETE)
    # If status code is 204 (No Content), do not force content type.
    if response.status_code != 204:
        response.headers['Content-Type'] = 'application/json'
    return response


@app.route('/register', methods=['POST'])
def register():
    global next_user_id
    data, err = get_json_body()
    if err:
        return json_error(err, 400)
    username = data.get('username')
    password = data.get('password')
    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
        return json_error('Invalid username', 400)
    if not isinstance(password, str) or len(password) < 8:
        return json_error('Password too short', 400)
    if username in username_index:
        return json_error('Username already exists', 409)
    user_id = next_user_id
    next_user_id += 1
    users[user_id] = {"id": user_id, "username": username, "password": password}
    username_index[username] = user_id
    return jsonify({"id": user_id, "username": username}), 201


@app.route('/login', methods=['POST'])
def login():
    data, err = get_json_body()
    if err:
        return json_error(err, 400)
    username = data.get('username')
    password = data.get('password')
    if not isinstance(username, str) or not isinstance(password, str):
        return json_error('Invalid credentials', 401)
    uid = username_index.get(username)
    if not uid:
        return json_error('Invalid credentials', 401)
    user = users.get(uid)
    if not user or user.get('password') != password:
        return json_error('Invalid credentials', 401)
    token = uuid.uuid4().hex
    sessions[token] = uid
    resp = jsonify({"id": user['id'], "username": user['username']})
    resp.set_cookie('session_id', token, path='/', httponly=True)
    return resp, 200


@app.route('/logout', methods=['POST'])
def logout():
    user, auth_err = require_auth()
    if auth_err:
        return auth_err
    # Invalidate the session token
    token = request.cookies.get('session_id')
    if token and token in sessions:
        del sessions[token]
    # Return empty JSON object
    return jsonify({}), 200


@app.route('/me', methods=['GET'])
def me():
    user, auth_err = require_auth()
    if auth_err:
        return auth_err
    return jsonify({"id": user['id'], "username": user['username']}), 200


@app.route('/password', methods=['PUT'])
def change_password():
    user, auth_err = require_auth()
    if auth_err:
        return auth_err
    data, err = get_json_body()
    if err:
        return json_error(err, 400)
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    if not isinstance(old_password, str) or users[user['id']]['password'] != old_password:
        return json_error('Invalid credentials', 401)
    if not isinstance(new_password, str) or len(new_password) < 8:
        return json_error('Password too short', 400)
    users[user['id']]['password'] = new_password
    return jsonify({}), 200


@app.route('/todos', methods=['GET'])
def list_todos():
    user, auth_err = require_auth()
    if auth_err:
        return auth_err
    user_todos = [t for t in todos.values() if t['user_id'] == user['id']]
    user_todos.sort(key=lambda x: x['id'])
    # Exclude user_id from response
    sanitized = [
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
    return jsonify(sanitized), 200


@app.route('/todos', methods=['POST'])
def create_todo():
    global next_todo_id
    user, auth_err = require_auth()
    if auth_err:
        return auth_err
    data, err = get_json_body()
    if err:
        return json_error(err, 400)
    title = data.get('title')
    description = data.get('description', '')
    if not isinstance(title, str) or title.strip() == '':
        return json_error('Title is required', 400)
    if description is None:
        description = ''
    if not isinstance(description, str):
        # Coerce to string to avoid errors
        description = str(description)
    ts = now_iso8601_utc_seconds()
    todo_id = next_todo_id
    next_todo_id += 1
    todo = {
        'id': todo_id,
        'user_id': user['id'],
        'title': title,
        'description': description,
        'completed': False,
        'created_at': ts,
        'updated_at': ts,
    }
    todos[todo_id] = todo
    resp_todo = {k: todo[k] for k in ['id', 'title', 'description', 'completed', 'created_at', 'updated_at']}
    return jsonify(resp_todo), 201


def get_todo_for_user(todo_id, user_id):
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user_id:
        return None
    return todo


@app.route('/todos/<int:todo_id>', methods=['GET'])
def get_todo(todo_id):
    user, auth_err = require_auth()
    if auth_err:
        return auth_err
    todo = get_todo_for_user(todo_id, user['id'])
    if not todo:
        return json_error('Todo not found', 404)
    resp_todo = {k: todo[k] for k in ['id', 'title', 'description', 'completed', 'created_at', 'updated_at']}
    return jsonify(resp_todo), 200


@app.route('/todos/<int:todo_id>', methods=['PUT'])
def update_todo(todo_id):
    user, auth_err = require_auth()
    if auth_err:
        return auth_err
    todo = get_todo_for_user(todo_id, user['id'])
    if not todo:
        return json_error('Todo not found', 404)
    data, err = get_json_body()
    if err:
        return json_error(err, 400)
    if 'title' in data:
        title = data.get('title')
        if not isinstance(title, str) or title.strip() == '':
            return json_error('Title is required', 400)
        todo['title'] = title
    if 'description' in data:
        desc = data.get('description')
        if desc is None:
            desc = ''
        if not isinstance(desc, str):
            desc = str(desc)
        todo['description'] = desc
    if 'completed' in data:
        comp = data.get('completed')
        if isinstance(comp, bool):
            todo['completed'] = comp
        else:
            # If provided but not boolean, reject request to avoid ambiguous state
            return json_error('Invalid data', 400)
    todo['updated_at'] = now_iso8601_utc_seconds()
    resp_todo = {k: todo[k] for k in ['id', 'title', 'description', 'completed', 'created_at', 'updated_at']}
    return jsonify(resp_todo), 200


@app.route('/todos/<int:todo_id>', methods=['DELETE'])
def delete_todo(todo_id):
    user, auth_err = require_auth()
    if auth_err:
        return auth_err
    todo = get_todo_for_user(todo_id, user['id'])
    if not todo:
        return json_error('Todo not found', 404)
    del todos[todo_id]
    # Return 204 No Content with no body and no Content-Type
    resp = make_response('', 204)
    if 'Content-Type' in resp.headers:
        del resp.headers['Content-Type']
    return resp


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    app.run(host='0.0.0.0', port=args.port, debug=False)


if __name__ == '__main__':
    main()
