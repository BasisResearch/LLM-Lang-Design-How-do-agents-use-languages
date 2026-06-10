import argparse
import re
import uuid
from datetime import datetime, timezone
from typing import Dict, Optional, Tuple

from flask import Flask, request, jsonify, make_response
import hashlib
import os
import hmac

app = Flask(__name__)

# In-memory storage
users_by_id: Dict[int, dict] = {}
users_by_username: Dict[str, dict] = {}
next_user_id: int = 1

sessions: Dict[str, int] = {}  # session_token -> user_id

todos_by_id: Dict[int, dict] = {}
next_todo_id: int = 1

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")
PASSWORD_MIN_LEN = 8

PBKDF2_ITERATIONS = 200_000
HASH_NAME = 'sha256'
SALT_BYTES = 16


def _now_iso_utc_seconds() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime('%Y-%m-%dT%H:%M:%SZ')


def _hash_password(password: str, salt: Optional[bytes] = None) -> Tuple[bytes, bytes]:
    if salt is None:
        salt = os.urandom(SALT_BYTES)
    dk = hashlib.pbkdf2_hmac(HASH_NAME, password.encode('utf-8'), salt, PBKDF2_ITERATIONS)
    return salt, dk


def _verify_password(password: str, salt: bytes, expected_hash: bytes) -> bool:
    dk = hashlib.pbkdf2_hmac(HASH_NAME, password.encode('utf-8'), salt, PBKDF2_ITERATIONS)
    # constant-time compare
    return hmac.compare_digest(dk, expected_hash)


def _user_public(user: dict) -> dict:
    return {"id": user["id"], "username": user["username"]}


def _todo_public(todo: dict) -> dict:
    return {
        "id": todo["id"],
        "title": todo["title"],
        "description": todo["description"],
        "completed": todo["completed"],
        "created_at": todo["created_at"],
        "updated_at": todo["updated_at"],
    }


def _json_error(status_code: int, message: str):
    resp = jsonify({"error": message})
    return resp, status_code


def _get_current_user() -> Optional[dict]:
    token = request.cookies.get('session_id')
    if not token:
        return None
    uid = sessions.get(token)
    if not uid:
        return None
    return users_by_id.get(uid)


def _require_auth() -> Optional[Tuple[dict, Tuple]]:
    user = _get_current_user()
    if not user:
        return None, _json_error(401, "Authentication required")
    return user, None


@app.after_request
def ensure_json_content_type(response):
    # Ensure Content-Type application/json for all responses that have a body and are not 204/304
    if response.status_code not in (204, 304):
        ctype = response.headers.get('Content-Type', '')
        if not ctype or 'application/json' not in ctype:
            response.headers['Content-Type'] = 'application/json'
    return response


@app.route('/register', methods=['POST'])
def register():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return _json_error(400, "Invalid JSON")
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username or ''):
        return _json_error(400, "Invalid username")
    if not isinstance(password, str) or len(password) < PASSWORD_MIN_LEN:
        return _json_error(400, "Password too short")
    if username in users_by_username:
        return _json_error(409, "Username already exists")

    global next_user_id
    uid = next_user_id
    next_user_id += 1

    salt, pw_hash = _hash_password(password)

    user = {
        'id': uid,
        'username': username,
        'pw_salt': salt,
        'pw_hash': pw_hash,
    }
    users_by_id[uid] = user
    users_by_username[username] = user

    resp = jsonify(_user_public(user))
    return resp, 201


@app.route('/login', methods=['POST'])
def login():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return _json_error(400, "Invalid JSON")
    username = data.get('username')
    password = data.get('password')
    if not isinstance(username, str) or not isinstance(password, str):
        # Treat as invalid credentials to avoid leaking info
        return _json_error(401, "Invalid credentials")
    user = users_by_username.get(username)
    if not user:
        return _json_error(401, "Invalid credentials")
    if not _verify_password(password, user['pw_salt'], user['pw_hash']):
        return _json_error(401, "Invalid credentials")

    # Create a new session token
    token = uuid.uuid4().hex
    sessions[token] = user['id']

    resp = make_response(jsonify(_user_public(user)))
    # Set-Cookie: session_id=<token>; Path=/; HttpOnly
    resp.set_cookie('session_id', token, path='/', httponly=True)
    return resp, 200


@app.route('/logout', methods=['POST'])
def logout():
    user = _get_current_user()
    if not user:
        return _json_error(401, "Authentication required")
    token = request.cookies.get('session_id')
    if token and token in sessions:
        sessions.pop(token, None)
    resp = make_response(jsonify({}))
    # Invalidate client-side cookie as well
    resp.set_cookie('session_id', '', path='/', httponly=True, max_age=0)
    return resp, 200


@app.route('/me', methods=['GET'])
def me():
    user, err = _require_auth()
    if err:
        return err
    return jsonify(_user_public(user))


@app.route('/password', methods=['PUT'])
def change_password():
    user, err = _require_auth()
    if err:
        return err
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return _json_error(400, "Invalid JSON")
    old_password = data.get('old_password')
    new_password = data.get('new_password')

    if not isinstance(old_password, str) or not _verify_password(old_password, user['pw_salt'], user['pw_hash']):
        return _json_error(401, "Invalid credentials")
    if not isinstance(new_password, str) or len(new_password) < PASSWORD_MIN_LEN:
        return _json_error(400, "Password too short")

    salt, pw_hash = _hash_password(new_password)
    user['pw_salt'] = salt
    user['pw_hash'] = pw_hash

    return jsonify({})


@app.route('/todos', methods=['GET'])
def list_todos():
    user, err = _require_auth()
    if err:
        return err
    uid = user['id']
    todos = [t for t in todos_by_id.values() if t['user_id'] == uid]
    todos.sort(key=lambda t: t['id'])
    return jsonify([_todo_public(t) for t in todos])


@app.route('/todos', methods=['POST'])
def create_todo():
    user, err = _require_auth()
    if err:
        return err
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return _json_error(400, "Invalid JSON")
    title = data.get('title')
    description = data.get('description', "")

    if not isinstance(title, str) or len(title.strip()) == 0:
        return _json_error(400, "Title is required")
    if not isinstance(description, str):
        # Coerce to string for robustness
        description = str(description)

    global next_todo_id
    tid = next_todo_id
    next_todo_id += 1

    now = _now_iso_utc_seconds()

    todo = {
        'id': tid,
        'user_id': user['id'],
        'title': title,
        'description': description,
        'completed': False,
        'created_at': now,
        'updated_at': now,
    }
    todos_by_id[tid] = todo

    resp = jsonify(_todo_public(todo))
    return resp, 201


def _get_user_todo_or_404(uid: int, tid: int):
    todo = todos_by_id.get(tid)
    if not todo or todo['user_id'] != uid:
        return None
    return todo


@app.route('/todos/<int:tid>', methods=['GET'])
def get_todo(tid: int):
    user, err = _require_auth()
    if err:
        return err
    todo = _get_user_todo_or_404(user['id'], tid)
    if not todo:
        return _json_error(404, "Todo not found")
    return jsonify(_todo_public(todo))


@app.route('/todos/<int:tid>', methods=['PUT'])
def update_todo(tid: int):
    user, err = _require_auth()
    if err:
        return err
    todo = _get_user_todo_or_404(user['id'], tid)
    if not todo:
        return _json_error(404, "Todo not found")

    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return _json_error(400, "Invalid JSON")

    if 'title' in data:
        title = data.get('title')
        if not isinstance(title, str) or len(title.strip()) == 0:
            return _json_error(400, "Title is required")
        todo['title'] = title
    if 'description' in data:
        description = data.get('description')
        if not isinstance(description, str):
            description = str(description)
        todo['description'] = description
    if 'completed' in data:
        completed = data.get('completed')
        if isinstance(completed, bool):
            todo['completed'] = completed
        else:
            # If provided but not a bool, treat as invalid type
            return _json_error(400, "Invalid JSON")

    todo['updated_at'] = _now_iso_utc_seconds()

    return jsonify(_todo_public(todo))


@app.route('/todos/<int:tid>', methods=['DELETE'])
def delete_todo(tid: int):
    user, err = _require_auth()
    if err:
        return err
    todo = _get_user_todo_or_404(user['id'], tid)
    if not todo:
        # For DELETE with error, still JSON body as per general rule (only success DELETE returns no body)
        return _json_error(404, "Todo not found")
    todos_by_id.pop(tid, None)
    # 204 No Content, and ensure no body
    return ('', 204)


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    app.run(host='0.0.0.0', port=args.port)


if __name__ == '__main__':
    main()
