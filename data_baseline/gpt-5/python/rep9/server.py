import argparse
import re
import uuid
from datetime import datetime, timezone
from typing import Dict, Any, Optional

from flask import Flask, request, jsonify, make_response, Response

app = Flask(__name__)

# In-memory storage
users_by_id: Dict[int, Dict[str, Any]] = {}
users_by_username: Dict[str, Dict[str, Any]] = {}
user_password: Dict[int, str] = {}
user_id_counter = 1

sessions: Dict[str, int] = {}  # session_id -> user_id

todos_by_id: Dict[int, Dict[str, Any]] = {}

todo_id_counter = 1

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def now_iso() -> str:
    # ISO 8601 UTC with second precision
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def json_error(message: str, status: int):
    resp = jsonify({"error": message})
    return make_response(resp, status)


def get_auth_user() -> Optional[Dict[str, Any]]:
    token = request.cookies.get("session_id")
    if not token:
        return None
    user_id = sessions.get(token)
    if not user_id:
        return None
    user = users_by_id.get(user_id)
    return user


def require_auth() -> Optional[Dict[str, Any]]:
    user = get_auth_user()
    if not user:
        return None
    return user


@app.errorhandler(404)
def handle_404(e):
    # Unknown path
    return json_error("Not found", 404)


@app.errorhandler(405)
def handle_405(e):
    return json_error("Method not allowed", 405)


@app.errorhandler(400)
def handle_400(e):
    return json_error("Bad request", 400)


@app.errorhandler(500)
def handle_500(e):
    return json_error("Internal server error", 500)


# Helper to ensure request JSON

def get_json_body() -> Optional[Dict[str, Any]]:
    try:
        data = request.get_json(force=True, silent=False)
        if data is None:
            return None
        if not isinstance(data, dict):
            return None
        return data
    except Exception:
        return None


# Routes

@app.post('/register')
def register():
    global user_id_counter
    data = get_json_body()
    if data is None:
        return json_error("Bad request", 400)
    username = data.get('username')
    password = data.get('password')

    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
        return json_error("Invalid username", 400)
    if not isinstance(password, str) or len(password) < 8:
        return json_error("Password too short", 400)
    if username in users_by_username:
        return json_error("Username already exists", 409)

    user = {"id": user_id_counter, "username": username}
    users_by_id[user_id_counter] = user
    users_by_username[username] = user
    user_password[user_id_counter] = password
    user_id_counter += 1

    return make_response(jsonify(user), 201)


@app.post('/login')
def login():
    data = get_json_body()
    if data is None:
        return json_error("Invalid credentials", 401)
    username = data.get('username')
    password = data.get('password')
    if not isinstance(username, str) or not isinstance(password, str):
        return json_error("Invalid credentials", 401)
    user = users_by_username.get(username)
    if not user:
        return json_error("Invalid credentials", 401)
    if user_password.get(user['id']) != password:
        return json_error("Invalid credentials", 401)

    token = uuid.uuid4().hex
    sessions[token] = user['id']

    resp = make_response(jsonify(user), 200)
    resp.set_cookie('session_id', token, httponly=True, path='/')
    return resp


@app.post('/logout')
def logout():
    user = require_auth()
    if not user:
        return json_error("Authentication required", 401)
    token = request.cookies.get('session_id')
    if token and token in sessions:
        del sessions[token]
    resp = make_response(jsonify({}), 200)
    # Optionally clear cookie on client side
    resp.set_cookie('session_id', '', httponly=True, path='/', max_age=0)
    return resp


@app.get('/me')
def me():
    user = require_auth()
    if not user:
        return json_error("Authentication required", 401)
    return jsonify(user)


@app.put('/password')
def change_password():
    user = require_auth()
    if not user:
        return json_error("Authentication required", 401)
    data = get_json_body()
    if data is None:
        return json_error("Bad request", 400)
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    if user_password.get(user['id']) != old_password:
        return json_error("Invalid credentials", 401)
    if not isinstance(new_password, str) or len(new_password) < 8:
        return json_error("Password too short", 400)
    user_password[user['id']] = new_password
    return jsonify({})


@app.get('/todos')
def list_todos():
    user = require_auth()
    if not user:
        return json_error("Authentication required", 401)
    uid = user['id']
    todos = [t for t in todos_by_id.values() if t['_user_id'] == uid]
    todos.sort(key=lambda x: x['id'])
    # Remove internal field
    result = []
    for t in todos:
        td = {k: v for k, v in t.items() if k != '_user_id'}
        result.append(td)
    return jsonify(result)


@app.post('/todos')
def create_todo():
    global todo_id_counter
    user = require_auth()
    if not user:
        return json_error("Authentication required", 401)
    data = get_json_body()
    if data is None:
        return json_error("Bad request", 400)
    title = data.get('title')
    if not isinstance(title, str) or title.strip() == '':
        return json_error("Title is required", 400)
    description = data.get('description', "")
    if not isinstance(description, str):
        description = str(description)

    now = now_iso()
    todo = {
        'id': todo_id_counter,
        'title': title,
        'description': description,
        'completed': False,
        'created_at': now,
        'updated_at': now,
        '_user_id': user['id'],
    }
    todos_by_id[todo_id_counter] = todo
    todo_id_counter += 1

    resp_obj = {k: v for k, v in todo.items() if k != '_user_id'}
    return make_response(jsonify(resp_obj), 201)


def get_visible_todo(user_id: int, todo_id: int) -> Optional[Dict[str, Any]]:
    t = todos_by_id.get(todo_id)
    if not t:
        return None
    if t.get('_user_id') != user_id:
        return None
    return t


@app.get('/todos/<int:todo_id>')
def get_todo(todo_id: int):
    user = require_auth()
    if not user:
        return json_error("Authentication required", 401)
    t = get_visible_todo(user['id'], todo_id)
    if not t:
        return json_error("Todo not found", 404)
    resp_obj = {k: v for k, v in t.items() if k != '_user_id'}
    return jsonify(resp_obj)


@app.put('/todos/<int:todo_id>')
def update_todo(todo_id: int):
    user = require_auth()
    if not user:
        return json_error("Authentication required", 401)
    t = get_visible_todo(user['id'], todo_id)
    if not t:
        return json_error("Todo not found", 404)
    data = get_json_body()
    if data is None:
        return json_error("Bad request", 400)

    if 'title' in data:
        title = data.get('title')
        if not isinstance(title, str) or title.strip() == '':
            return json_error("Title is required", 400)
        t['title'] = title
    if 'description' in data:
        description = data.get('description')
        if not isinstance(description, str):
            description = str(description)
        t['description'] = description
    if 'completed' in data:
        completed = data.get('completed')
        if not isinstance(completed, bool):
            return json_error("Bad request", 400)
        t['completed'] = completed

    t['updated_at'] = now_iso()

    resp_obj = {k: v for k, v in t.items() if k != '_user_id'}
    return jsonify(resp_obj)


@app.delete('/todos/<int:todo_id>')
def delete_todo(todo_id: int):
    user = require_auth()
    if not user:
        # For DELETE, even errors should be JSON content-type, but DELETE success is no body.
        return json_error("Authentication required", 401)
    t = get_visible_todo(user['id'], todo_id)
    if not t:
        return json_error("Todo not found", 404)
    del todos_by_id[todo_id]
    # Return 204 No Content without body
    return Response(status=204)


def main():
    parser = argparse.ArgumentParser(description='Todo App Server')
    parser.add_argument('--port', type=int, required=True, help='Port to listen on')
    args = parser.parse_args()
    app.run(host='0.0.0.0', port=args.port, debug=False, threaded=False)


if __name__ == '__main__':
    main()
