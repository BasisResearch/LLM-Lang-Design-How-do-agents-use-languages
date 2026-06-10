#!/usr/bin/env python3
import argparse
import re
import uuid
from datetime import datetime
from threading import Lock
from flask import Flask, request, jsonify, make_response

# In-memory data stores
users_by_id = {}
users_by_username = {}
passwords_by_user_id = {}
sessions = {}  # session_token -> user_id

# Todos: id -> todo dict including owner user_id
# Public fields: id, title, description, completed, created_at, updated_at
# Private field: _user_id

todos_by_id = {}

next_user_id = 1
next_todo_id = 1

user_lock = Lock()
todo_lock = Lock()
session_lock = Lock()

app = Flask(__name__)

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')

def now_iso_utc():
    # ISO 8601 UTC timestamp with second precision
    return datetime.utcnow().replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')


def json_error(message, status_code):
    resp = jsonify({"error": message})
    return resp, status_code


def get_auth_user():
    token = request.cookies.get('session_id')
    if not token:
        return None
    with session_lock:
        uid = sessions.get(token)
    if uid is None:
        return None
    user = users_by_id.get(uid)
    return user


def require_auth():
    user = get_auth_user()
    if not user:
        return None, json_error("Authentication required", 401)
    return user, None


def public_user(user):
    return {"id": user["id"], "username": user["username"]}


@app.after_request
def set_json_content_type(response):
    # Ensure Content-Type application/json for all JSON responses.
    # For 204 No Content, do not modify and ensure no body.
    if response.status_code == 204:
        response.response = []
        response.direct_passthrough = False
        # Remove Content-Type if any
        response.headers.pop('Content-Type', None)
        return response
    response.headers['Content-Type'] = 'application/json'
    return response


@app.route('/register', methods=['POST'])
def register():
    try:
        data = request.get_json(force=True)
    except Exception:
        data = None
    if not isinstance(data, dict):
        return json_error("Invalid JSON", 400)
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not USERNAME_RE.match(username):
        return json_error("Invalid username", 400)
    if not isinstance(password, str) or len(password) < 8:
        return json_error("Password too short", 400)

    global next_user_id
    with user_lock:
        if username in users_by_username:
            return json_error("Username already exists", 409)
        uid = next_user_id
        next_user_id += 1
        user = {"id": uid, "username": username}
        users_by_id[uid] = user
        users_by_username[username] = uid
        passwords_by_user_id[uid] = password

    resp = jsonify(public_user(user))
    return resp, 201


@app.route('/login', methods=['POST'])
def login():
    try:
        data = request.get_json(force=True)
    except Exception:
        data = None
    if not isinstance(data, dict):
        return json_error("Invalid JSON", 400)
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not isinstance(password, str):
        return json_error("Invalid credentials", 401)

    uid = users_by_username.get(username)
    if not uid:
        return json_error("Invalid credentials", 401)
    stored_pw = passwords_by_user_id.get(uid)
    if stored_pw != password:
        return json_error("Invalid credentials", 401)

    token = uuid.uuid4().hex
    with session_lock:
        sessions[token] = uid

    user = users_by_id[uid]
    resp = make_response(jsonify(public_user(user)), 200)
    # Set-Cookie: session_id=<token>; Path=/; HttpOnly
    resp.set_cookie('session_id', token, httponly=True, path='/')
    return resp


@app.route('/logout', methods=['POST'])
def logout():
    user = get_auth_user()
    if not user:
        return json_error("Authentication required", 401)
    token = request.cookies.get('session_id')
    if token:
        with session_lock:
            sessions.pop(token, None)
    return jsonify({}), 200


@app.route('/me', methods=['GET'])
def me():
    user, err = require_auth()
    if err:
        return err
    return jsonify(public_user(user)), 200


@app.route('/password', methods=['PUT'])
def change_password():
    user, err = require_auth()
    if err:
        return err
    try:
        data = request.get_json(force=True)
    except Exception:
        data = None
    if not isinstance(data, dict):
        return json_error("Invalid JSON", 400)

    old = data.get('old_password')
    new = data.get('new_password')

    if not isinstance(old, str) or passwords_by_user_id.get(user['id']) != old:
        return json_error("Invalid credentials", 401)
    if not isinstance(new, str) or len(new) < 8:
        return json_error("Password too short", 400)

    passwords_by_user_id[user['id']] = new
    return jsonify({}), 200


@app.route('/todos', methods=['GET'])
def list_todos():
    user, err = require_auth()
    if err:
        return err
    uid = user['id']
    # Collect and sort by id asc
    items = []
    with todo_lock:
        for t in todos_by_id.values():
            if t['_user_id'] == uid:
                items.append({k: t[k] for k in ('id','title','description','completed','created_at','updated_at')})
    items.sort(key=lambda x: x['id'])
    return jsonify(items), 200


@app.route('/todos', methods=['POST'])
def create_todo():
    user, err = require_auth()
    if err:
        return err
    try:
        data = request.get_json(force=True)
    except Exception:
        data = None
    if not isinstance(data, dict):
        return json_error("Invalid JSON", 400)

    title = data.get('title')
    description = data.get('description', '')
    if title is None or not isinstance(title, str) or title.strip() == '':
        return json_error("Title is required", 400)
    if not isinstance(description, str):
        return json_error("Invalid JSON", 400)

    global next_todo_id
    with todo_lock:
        tid = next_todo_id
        next_todo_id += 1
        now = now_iso_utc()
        todo = {
            'id': tid,
            'title': title,
            'description': description,
            'completed': False,
            'created_at': now,
            'updated_at': now,
            '_user_id': user['id'],
        }
        todos_by_id[tid] = todo

    pub = {k: todo[k] for k in ('id','title','description','completed','created_at','updated_at')}
    return jsonify(pub), 201


def get_todo_for_user(tid, uid):
    try:
        tid = int(tid)
    except Exception:
        return None
    t = todos_by_id.get(tid)
    if not t or t.get('_user_id') != uid:
        return None
    return t


@app.route('/todos/<tid>', methods=['GET'])
def get_todo(tid):
    user, err = require_auth()
    if err:
        return err
    t = get_todo_for_user(tid, user['id'])
    if not t:
        return json_error("Todo not found", 404)
    pub = {k: t[k] for k in ('id','title','description','completed','created_at','updated_at')}
    return jsonify(pub), 200


@app.route('/todos/<tid>', methods=['PUT'])
def update_todo(tid):
    user, err = require_auth()
    if err:
        return err
    t = get_todo_for_user(tid, user['id'])
    if not t:
        return json_error("Todo not found", 404)
    try:
        data = request.get_json(force=True)
    except Exception:
        data = None
    if not isinstance(data, dict):
        return json_error("Invalid JSON", 400)

    # Partial update handling
    if 'title' in data:
        new_title = data.get('title')
        if not isinstance(new_title, str) or new_title.strip() == '':
            return json_error("Title is required", 400)
        t['title'] = new_title
    if 'description' in data:
        new_desc = data.get('description')
        if not isinstance(new_desc, str):
            return json_error("Invalid JSON", 400)
        t['description'] = new_desc
    if 'completed' in data:
        comp = data.get('completed')
        if not isinstance(comp, bool):
            return json_error("Invalid JSON", 400)
        t['completed'] = comp

    t['updated_at'] = now_iso_utc()

    pub = {k: t[k] for k in ('id','title','description','completed','created_at','updated_at')}
    return jsonify(pub), 200


@app.route('/todos/<tid>', methods=['DELETE'])
def delete_todo(tid):
    user, err = require_auth()
    if err:
        return err
    uid = user['id']
    try:
        tid_int = int(tid)
    except Exception:
        return json_error("Todo not found", 404)
    from flask import Response
    with todo_lock:
        t = todos_by_id.get(tid_int)
        if not t or t.get('_user_id') != uid:
            return json_error("Todo not found", 404)
        del todos_by_id[tid_int]
    # 204 No Content, no body, no Content-Type
    return Response(status=204)


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    # Bind to 0.0.0.0
    app.run(host='0.0.0.0', port=args.port, threaded=True)


if __name__ == '__main__':
    main()
