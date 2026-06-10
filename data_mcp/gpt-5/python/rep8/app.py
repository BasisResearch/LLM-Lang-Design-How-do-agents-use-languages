import argparse
import re
import uuid
from datetime import datetime, timezone, timedelta
from flask import Flask, request, jsonify, make_response

app = Flask(__name__)

# In-memory storage
users_by_id = {}
usernames = {}  # username -> user_id
password_hashes = {}  # user_id -> password_hash
next_user_id = 1

sessions = {}  # session_token -> user_id

# Todos storage: todo_id -> todo dict incl. user_id
todos = {}
next_todo_id = 1

USERNAME_RE = re.compile(r'^[a-zA-Z0-9_]{3,50}$')


def now_iso8601_utc_seconds() -> str:
    # Use timezone-aware UTC, second precision
    return datetime.now(timezone.utc).replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')


def parse_iso8601_utc_seconds(ts: str) -> datetime:
    # ts like 'YYYY-MM-DDTHH:MM:SSZ'
    return datetime.strptime(ts, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)


def hash_password(pw: str) -> str:
    # Simple SHA-256 hash for demo purposes
    import hashlib
    return hashlib.sha256(pw.encode('utf-8')).hexdigest()


def get_authenticated_user():
    token = request.cookies.get('session_id')
    if not token:
        return None
    user_id = sessions.get(token)
    if not user_id:
        return None
    return users_by_id.get(user_id)


def require_auth():
    user = get_authenticated_user()
    if not user:
        resp = jsonify({"error": "Authentication required"})
        return resp, 401
    return user


def sanitize_user(user):
    return {"id": user["id"], "username": user["username"]}


@app.after_request
def set_default_json_content_type(response):
    # Ensure JSON Content-Type for all responses except DELETE which returns no body (204)
    if response.status_code == 204 or (request.method == 'DELETE' and not response.get_data()):
        # Ensure no Content-Type header for DELETE/no body
        if 'Content-Type' in response.headers:
            del response.headers['Content-Type']
        return response
    response.headers['Content-Type'] = 'application/json'
    return response


@app.route('/register', methods=['POST'])
def register():
    global next_user_id
    try:
        data = request.get_json(force=True, silent=False)
    except Exception:
        return jsonify({"error": "Invalid JSON"}), 400
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON"}), 400
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
        return jsonify({"error": "Invalid username"}), 400
    if not isinstance(password, str) or len(password) < 8:
        return jsonify({"error": "Password too short"}), 400
    if username in usernames:
        return jsonify({"error": "Username already exists"}), 409

    user_id = next_user_id
    next_user_id += 1
    user = {"id": user_id, "username": username}
    users_by_id[user_id] = user
    usernames[username] = user_id
    password_hashes[user_id] = hash_password(password)

    return jsonify(sanitize_user(user)), 201


@app.route('/login', methods=['POST'])
def login():
    try:
        data = request.get_json(force=True, silent=False)
    except Exception:
        return jsonify({"error": "Invalid JSON"}), 400
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON"}), 400

    username = data.get('username')
    password = data.get('password')
    if not isinstance(username, str) or not isinstance(password, str):
        return jsonify({"error": "Invalid credentials"}), 401

    user_id = usernames.get(username)
    if not user_id:
        return jsonify({"error": "Invalid credentials"}), 401
    if password_hashes.get(user_id) != hash_password(password):
        return jsonify({"error": "Invalid credentials"}), 401

    user = users_by_id[user_id]
    token = uuid.uuid4().hex
    sessions[token] = user_id

    resp = make_response(jsonify(sanitize_user(user)))
    # Set-Cookie: session_id=<token>; Path=/; HttpOnly
    resp.set_cookie('session_id', token, httponly=True, path='/')
    return resp


@app.route('/logout', methods=['POST'])
def logout():
    user = require_auth()
    if not isinstance(user, dict):
        # It's a (response, status)
        return user
    token = request.cookies.get('session_id')
    if token and token in sessions:
        del sessions[token]
    # Return empty object
    return jsonify({}), 200


@app.route('/me', methods=['GET'])
def me():
    user = require_auth()
    if not isinstance(user, dict):
        return user
    return jsonify(sanitize_user(user))


@app.route('/password', methods=['PUT'])
def change_password():
    user = require_auth()
    if not isinstance(user, dict):
        return user
    try:
        data = request.get_json(force=True, silent=False)
    except Exception:
        return jsonify({"error": "Invalid JSON"}), 400
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON"}), 400

    old_pw = data.get('old_password')
    new_pw = data.get('new_password')
    if password_hashes.get(user['id']) != hash_password(str(old_pw) if old_pw is not None else ''):
        return jsonify({"error": "Invalid credentials"}), 401
    if not isinstance(new_pw, str) or len(new_pw) < 8:
        return jsonify({"error": "Password too short"}), 400

    password_hashes[user['id']] = hash_password(new_pw)
    return jsonify({}), 200


@app.route('/todos', methods=['GET'])
def list_todos():
    user = require_auth()
    if not isinstance(user, dict):
        return user
    user_id = user['id']
    user_todos = [todo_view(t) for t in sorted(todos.values(), key=lambda x: x['id']) if t['user_id'] == user_id]
    return jsonify(user_todos)


@app.route('/todos', methods=['POST'])
def create_todo():
    global next_todo_id
    user = require_auth()
    if not isinstance(user, dict):
        return user
    try:
        data = request.get_json(force=True, silent=False)
    except Exception:
        return jsonify({"error": "Invalid JSON"}), 400
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON"}), 400

    title = data.get('title')
    description = data.get('description', '')
    if title is None or not isinstance(title, str) or title.strip() == '':
        return jsonify({"error": "Title is required"}), 400
    if not isinstance(description, str):
        # Coerce non-string descriptions to string to be safe
        description = str(description)

    todo_id = next_todo_id
    next_todo_id += 1
    created = now_iso8601_utc_seconds()
    todo = {
        'id': todo_id,
        'user_id': user['id'],
        'title': title,
        'description': description,
        'completed': False,
        'created_at': created,
        'updated_at': created,
    }
    todos[todo_id] = todo
    return jsonify(todo_view(todo)), 201


@app.route('/todos/<int:todo_id>', methods=['GET'])
def get_todo(todo_id: int):
    user = require_auth()
    if not isinstance(user, dict):
        return user
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user['id']:
        return jsonify({"error": "Todo not found"}), 404
    return jsonify(todo_view(todo))


@app.route('/todos/<int:todo_id>', methods=['PUT'])
def update_todo(todo_id: int):
    user = require_auth()
    if not isinstance(user, dict):
        return user
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user['id']:
        return jsonify({"error": "Todo not found"}), 404

    try:
        data = request.get_json(force=True, silent=False)
    except Exception:
        return jsonify({"error": "Invalid JSON"}), 400
    if not isinstance(data, dict):
        return jsonify({"error": "Invalid JSON"}), 400

    modified = False
    if 'title' in data:
        title = data.get('title')
        if title is None or not isinstance(title, str) or title.strip() == '':
            return jsonify({"error": "Title is required"}), 400
        todo['title'] = title
        modified = True
    if 'description' in data:
        desc = data.get('description')
        if not isinstance(desc, str):
            desc = str(desc)
        todo['description'] = desc
        modified = True
    if 'completed' in data:
        comp = data.get('completed')
        if isinstance(comp, bool):
            todo['completed'] = comp
        else:
            todo['completed'] = bool(comp)
        modified = True

    if modified:
        new_ts = now_iso8601_utc_seconds()
        # Ensure monotonic updated_at per todo in second precision
        if new_ts <= todo['updated_at']:
            dt = parse_iso8601_utc_seconds(todo['updated_at']) + timedelta(seconds=1)
            new_ts = dt.strftime('%Y-%m-%dT%H:%M:%SZ')
        todo['updated_at'] = new_ts

    return jsonify(todo_view(todo))


@app.route('/todos/<int:todo_id>', methods=['DELETE'])
def delete_todo(todo_id: int):
    user = require_auth()
    if not isinstance(user, dict):
        return user
    todo = todos.get(todo_id)
    if not todo or todo['user_id'] != user['id']:
        return jsonify({"error": "Todo not found"}), 404
    del todos[todo_id]
    resp = make_response('', 204)
    # Ensure no Content-Type header for 204
    if 'Content-Type' in resp.headers:
        del resp.headers['Content-Type']
    return resp


def todo_view(todo):
    return {
        'id': todo['id'],
        'title': todo['title'],
        'description': todo['description'],
        'completed': todo['completed'],
        'created_at': todo['created_at'],
        'updated_at': todo['updated_at'],
    }


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    app.run(host='0.0.0.0', port=args.port)


if __name__ == '__main__':
    main()
