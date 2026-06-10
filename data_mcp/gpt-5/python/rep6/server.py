import argparse
import uuid
import re
from datetime import datetime, timezone
from typing import Dict, Any, Optional, Tuple

from flask import Flask, request, jsonify, make_response

app = Flask(__name__)

# In-memory storage
users: Dict[int, Dict[str, Any]] = {}
username_to_id: Dict[str, int] = {}
passwords: Dict[int, str] = {}  # store plaintext for simplicity (in-memory only)
sessions: Dict[str, int] = {}   # session_id -> user_id

# Todos storage: id -> todo dict (includes user_id)
todos: Dict[int, Dict[str, Any]] = {}

# Auto-increment counters
next_user_id = 1
next_todo_id = 1

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def now_iso_utc() -> str:
    # ISO 8601 UTC timestamp with second precision
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def json_error(message: str, status: int):
    resp = jsonify({"error": message})
    resp.status_code = status
    resp.headers["Content-Type"] = "application/json"
    return resp


def make_json_response(data: Any, status: int = 200):
    resp = make_response(jsonify(data), status)
    resp.headers["Content-Type"] = "application/json"
    return resp


def get_authenticated_user() -> Optional[Dict[str, Any]]:
    token = request.cookies.get("session_id")
    if not token:
        return None
    uid = sessions.get(token)
    if not uid:
        return None
    return users.get(uid)


def require_auth() -> Tuple[Optional[Dict[str, Any]], Optional[Any]]:
    user = get_authenticated_user()
    if not user:
        return None, json_error("Authentication required", 401)
    return user, None


@app.after_request
def ensure_json_content_type(response):
    # Ensure Content-Type is application/json for all responses except DELETE 204 with no body.
    # We'll enforce for non-empty responses and non-204 status codes.
    # For DELETE endpoints we explicitly construct responses.
    if response.status_code != 204:
        # If response has no Content-Type or not application/json, and has a body that looks like JSON,
        # set it to application/json as per spec.
        response.headers["Content-Type"] = "application/json"
    return response


@app.route('/register', methods=['POST'])
def register():
    global next_user_id
    data = request.get_json(silent=True) or {}
    username = data.get('username')
    password = data.get('password')

    # Validate username
    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
        return json_error("Invalid username", 400)

    # Validate password
    if not isinstance(password, str) or len(password) < 8:
        return json_error("Password too short", 400)

    # Unique username
    if username in username_to_id:
        return json_error("Username already exists", 409)

    user_id = next_user_id
    next_user_id += 1
    users[user_id] = {"id": user_id, "username": username}
    username_to_id[username] = user_id
    passwords[user_id] = password

    return make_json_response(users[user_id], 201)


@app.route('/login', methods=['POST'])
def login():
    data = request.get_json(silent=True) or {}
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not isinstance(password, str):
        return json_error("Invalid credentials", 401)

    uid = username_to_id.get(username)
    if not uid or passwords.get(uid) != password:
        return json_error("Invalid credentials", 401)

    token = uuid.uuid4().hex
    sessions[token] = uid

    resp = make_json_response(users[uid], 200)
    # Set-Cookie: session_id=<token>; Path=/; HttpOnly
    resp.set_cookie('session_id', token, path='/', httponly=True)
    return resp


@app.route('/logout', methods=['POST'])
def logout():
    user, err = require_auth()
    if err:
        return err
    # Invalidate session
    token = request.cookies.get('session_id')
    if token in sessions:
        del sessions[token]
    # Return empty JSON object
    return make_json_response({}, 200)


@app.route('/me', methods=['GET'])
def me():
    user, err = require_auth()
    if err:
        return err
    return make_json_response(user, 200)


@app.route('/password', methods=['PUT'])
def change_password():
    user, err = require_auth()
    if err:
        return err

    data = request.get_json(silent=True) or {}
    old_password = data.get('old_password')
    new_password = data.get('new_password')

    if not isinstance(new_password, str) or len(new_password) < 8:
        return json_error("Password too short", 400)

    uid = user['id']
    if passwords.get(uid) != old_password:
        return json_error("Invalid credentials", 401)

    passwords[uid] = new_password
    return make_json_response({}, 200)


@app.route('/todos', methods=['GET'])
def list_todos():
    user, err = require_auth()
    if err:
        return err

    uid = user['id']
    user_todos = [
        {k: v for k, v in todo.items() if k != 'user_id'}
        for todo in sorted((t for t in todos.values() if t['user_id'] == uid), key=lambda x: x['id'])
    ]
    return make_json_response(user_todos, 200)


@app.route('/todos', methods=['POST'])
def create_todo():
    global next_todo_id
    user, err = require_auth()
    if err:
        return err

    data = request.get_json(silent=True) or {}
    title = data.get('title')
    description = data.get('description', "")

    if not isinstance(title, str) or len(title.strip()) == 0:
        return json_error("Title is required", 400)

    if not isinstance(description, str):
        return json_error("Title is required", 400)  # Keep error message per spec focus on title

    tid = next_todo_id
    next_todo_id += 1
    timestamp = now_iso_utc()
    todo = {
        'id': tid,
        'title': title,
        'description': description,
        'completed': False,
        'created_at': timestamp,
        'updated_at': timestamp,
        'user_id': user['id'],
    }
    todos[tid] = todo

    public_todo = {k: v for k, v in todo.items() if k != 'user_id'}
    return make_json_response(public_todo, 201)


def get_todo_for_user(tid: int, uid: int) -> Optional[Dict[str, Any]]:
    todo = todos.get(tid)
    if not todo or todo['user_id'] != uid:
        return None
    return todo


@app.route('/todos/<int:tid>', methods=['GET'])
def get_todo(tid: int):
    user, err = require_auth()
    if err:
        return err
    uid = user['id']
    todo = get_todo_for_user(tid, uid)
    if not todo:
        return json_error("Todo not found", 404)
    public_todo = {k: v for k, v in todo.items() if k != 'user_id'}
    return make_json_response(public_todo, 200)


@app.route('/todos/<int:tid>', methods=['PUT'])
def update_todo(tid: int):
    user, err = require_auth()
    if err:
        return err
    uid = user['id']
    todo = get_todo_for_user(tid, uid)
    if not todo:
        return json_error("Todo not found", 404)

    data = request.get_json(silent=True) or {}

    changed = False

    if 'title' in data:
        title = data.get('title')
        if not isinstance(title, str) or len(title.strip()) == 0:
            return json_error("Title is required", 400)
        if title != todo['title']:
            todo['title'] = title
            changed = True

    if 'description' in data:
        description = data.get('description')
        if not isinstance(description, str):
            # If provided but not a string, treat as no change? Better to coerce error.
            # Spec does not define, but we avoid changing and not error except title.
            description = str(description)
        if description != todo['description']:
            todo['description'] = description
            changed = True

    if 'completed' in data:
        completed = data.get('completed')
        if isinstance(completed, bool):
            if completed != todo['completed']:
                todo['completed'] = completed
                changed = True
        else:
            # Coerce truthiness for non-bool? Spec expects bool; reject silently? We'll coerce strictly.
            # If not bool, ignore update (no change).
            pass

    if changed:
        todo['updated_at'] = now_iso_utc()

    public_todo = {k: v for k, v in todo.items() if k != 'user_id'}
    return make_json_response(public_todo, 200)


@app.route('/todos/<int:tid>', methods=['DELETE'])
def delete_todo(tid: int):
    user, err = require_auth()
    if err:
        return err
    uid = user['id']
    todo = get_todo_for_user(tid, uid)
    if not todo:
        return json_error("Todo not found", 404)

    del todos[tid]
    resp = make_response('', 204)
    # Remove content-type to emphasize no body
    if 'Content-Type' in resp.headers:
        del resp.headers['Content-Type']
    return resp


@app.errorhandler(404)
def handle_404(e):
    # Generic 404 for unknown routes
    return json_error("Not found", 404)


@app.errorhandler(405)
def handle_405(e):
    return json_error("Method not allowed", 405)


@app.errorhandler(400)
def handle_400(e):
    return json_error("Bad request", 400)


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()

    app.run(host='0.0.0.0', port=args.port)


if __name__ == '__main__':
    main()
