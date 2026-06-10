import argparse
import re
import threading
import uuid
from datetime import datetime
from typing import Any, Dict, Optional

from flask import Flask, jsonify, request, make_response

app = Flask(__name__)

# In-memory storage
users: Dict[int, Dict[str, Any]] = {}
usernames: Dict[str, int] = {}
next_user_id = 1
user_lock = threading.Lock()

# Store password hashes and salts
# user_passwords[user_id] = {"salt": bytes, "hash": bytes}
user_passwords: Dict[int, Dict[str, bytes]] = {}

# Sessions: session_id -> user_id
sessions: Dict[str, int] = {}
session_lock = threading.Lock()

# Todos: todo_id -> {"owner_id": int, ...todo fields...}
todos: Dict[int, Dict[str, Any]] = {}
next_todo_id = 1
todo_lock = threading.Lock()

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def now_iso8601_utc() -> str:
    # Second precision, UTC Z suffix
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"


def json_response(data: Any, status: int = 200):
    resp = make_response(jsonify(data), status)
    # Ensure JSON content type
    resp.headers["Content-Type"] = "application/json"
    return resp


def error_response(message: str, status: int):
    return json_response({"error": message}, status)


# Password hashing utilities
import hashlib
import os
import hmac


def hash_password(password: str, salt: Optional[bytes] = None) -> Dict[str, bytes]:
    if salt is None:
        salt = os.urandom(16)
    # Use PBKDF2-HMAC-SHA256 with 100k iterations
    pwd_hash = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100_000)
    return {"salt": salt, "hash": pwd_hash}


def verify_password(password: str, stored: Dict[str, bytes]) -> bool:
    test = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), stored["salt"], 100_000)
    # constant-time comparison
    return hmac.compare_digest(test, stored["hash"])  # type: ignore[arg-type]


# Flask prior to 2.3 may not have typing for Request.cookies

def get_authenticated_user_id() -> Optional[int]:
    token = request.cookies.get("session_id")
    if not token:
        return None
    with session_lock:
        uid = sessions.get(token)
    return uid


def require_auth() -> Optional[int]:
    uid = get_authenticated_user_id()
    if uid is None or uid not in users:
        return None
    return uid


@app.after_request
def ensure_json_content_type(resp):
    # Ensure JSON content-type for all responses except DELETE 204 with no body
    if request.method == "DELETE":
        # For DELETE, spec requires no body. We try to remove Content-Type header
        if resp.status_code == 204:
            # Remove Content-Type header if present
            try:
                del resp.headers["Content-Type"]
            except KeyError:
                pass
            return resp
    # For other methods, ensure application/json
    # If response has no body (e.g., 204 for non-DELETE), leave as is
    if resp.status_code != 204:
        resp.headers["Content-Type"] = "application/json"
    return resp


# Routes
@app.route("/register", methods=["POST"])
def register():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return error_response("Invalid username", 400)
    username = data.get("username")
    password = data.get("password")

    # Validate username
    if not isinstance(username, str) or not USERNAME_RE.fullmatch(username):
        return error_response("Invalid username", 400)
    # Validate password
    if not isinstance(password, str) or len(password) < 8:
        return error_response("Password too short", 400)

    with user_lock:
        if username in usernames:
            return error_response("Username already exists", 409)
        global next_user_id
        uid = next_user_id
        next_user_id += 1
        users[uid] = {"id": uid, "username": username}
        usernames[username] = uid
        user_passwords[uid] = hash_password(password)

    return json_response({"id": uid, "username": username}, 201)


@app.route("/login", methods=["POST"])
def login():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return error_response("Invalid credentials", 401)
    username = data.get("username")
    password = data.get("password")
    if not isinstance(username, str) or not isinstance(password, str):
        return error_response("Invalid credentials", 401)

    with user_lock:
        uid = usernames.get(username)
        if not uid:
            return error_response("Invalid credentials", 401)
        stored = user_passwords.get(uid)
    if stored is None or not verify_password(password, stored):
        return error_response("Invalid credentials", 401)

    token = uuid.uuid4().hex
    with session_lock:
        sessions[token] = uid

    resp = json_response({"id": uid, "username": username}, 200)
    # Set-Cookie: session_id=<token>; Path=/; HttpOnly
    resp.set_cookie("session_id", token, path="/", httponly=True)
    return resp


@app.route("/logout", methods=["POST"])
def logout():
    uid = require_auth()
    if uid is None:
        return error_response("Authentication required", 401)
    token = request.cookies.get("session_id")
    if token:
        with session_lock:
            sessions.pop(token, None)
    # Return empty JSON object per spec
    resp = json_response({}, 200)
    # Optionally clear cookie client-side (not required by spec), but safe
    resp.set_cookie("session_id", "", path="/", httponly=True, max_age=0)
    return resp


@app.route("/me", methods=["GET"])
def me():
    uid = require_auth()
    if uid is None:
        return error_response("Authentication required", 401)
    with user_lock:
        u = users.get(uid)
        if not u:
            return error_response("Authentication required", 401)
        return json_response({"id": u["id"], "username": u["username"]}, 200)


@app.route("/password", methods=["PUT"])
def change_password():
    uid = require_auth()
    if uid is None:
        return error_response("Authentication required", 401)
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return error_response("Invalid credentials", 401)
    old_password = data.get("old_password")
    new_password = data.get("new_password")

    if not isinstance(old_password, str):
        return error_response("Invalid credentials", 401)
    with user_lock:
        stored = user_passwords.get(uid)
    if stored is None or not verify_password(old_password, stored):
        return error_response("Invalid credentials", 401)

    if not isinstance(new_password, str) or len(new_password) < 8:
        return error_response("Password too short", 400)

    with user_lock:
        user_passwords[uid] = hash_password(new_password)

    return json_response({}, 200)


@app.route("/todos", methods=["GET"])
def list_todos():
    uid = require_auth()
    if uid is None:
        return error_response("Authentication required", 401)

    with todo_lock:
        items = [
            {
                "id": t["id"],
                "title": t["title"],
                "description": t["description"],
                "completed": t["completed"],
                "created_at": t["created_at"],
                "updated_at": t["updated_at"],
            }
            for t in sorted((todo for todo in todos.values() if todo["owner_id"] == uid), key=lambda x: x["id"])  # type: ignore
        ]

    return json_response(items, 200)


@app.route("/todos", methods=["POST"])
def create_todo():
    uid = require_auth()
    if uid is None:
        return error_response("Authentication required", 401)

    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return error_response("Title is required", 400)
    title = data.get("title")
    description = data.get("description", "")
    if not isinstance(title, str) or len(title.strip()) == 0:
        return error_response("Title is required", 400)
    if not isinstance(description, str):
        # Coerce non-string descriptions to string for robustness
        description = str(description)

    created = now_iso8601_utc()

    with todo_lock:
        global next_todo_id
        tid = next_todo_id
        next_todo_id += 1
        todo = {
            "id": tid,
            "owner_id": uid,
            "title": title,
            "description": description,
            "completed": False,
            "created_at": created,
            "updated_at": created,
        }
        todos[tid] = todo

        resp_obj = {
            "id": todo["id"],
            "title": todo["title"],
            "description": todo["description"],
            "completed": todo["completed"],
            "created_at": todo["created_at"],
            "updated_at": todo["updated_at"],
        }

    return json_response(resp_obj, 201)


@app.route("/todos/<int:todo_id>", methods=["GET"])
def get_todo(todo_id: int):
    uid = require_auth()
    if uid is None:
        return error_response("Authentication required", 401)

    with todo_lock:
        todo = todos.get(todo_id)
        if not todo or todo.get("owner_id") != uid:
            return error_response("Todo not found", 404)
        resp_obj = {
            "id": todo["id"],
            "title": todo["title"],
            "description": todo["description"],
            "completed": todo["completed"],
            "created_at": todo["created_at"],
            "updated_at": todo["updated_at"],
        }
    return json_response(resp_obj, 200)


@app.route("/todos/<int:todo_id>", methods=["PUT"])
def update_todo(todo_id: int):
    uid = require_auth()
    if uid is None:
        return error_response("Authentication required", 401)

    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        data = {}

    with todo_lock:
        todo = todos.get(todo_id)
        if not todo or todo.get("owner_id") != uid:
            return error_response("Todo not found", 404)

        changed = False
        if "title" in data:
            title = data.get("title")
            if not isinstance(title, str) or len(title.strip()) == 0:
                return error_response("Title is required", 400)
            if title != todo["title"]:
                todo["title"] = title
                changed = True
        if "description" in data:
            desc = data.get("description")
            if not isinstance(desc, str):
                desc = str(desc)
            if desc != todo["description"]:
                todo["description"] = desc
                changed = True
        if "completed" in data:
            comp = data.get("completed")
            if not isinstance(comp, bool):
                return error_response("Invalid completed", 400)
            if comp != todo["completed"]:
                todo["completed"] = comp
                changed = True
        if changed:
            todo["updated_at"] = now_iso8601_utc()

        resp_obj = {
            "id": todo["id"],
            "title": todo["title"],
            "description": todo["description"],
            "completed": todo["completed"],
            "created_at": todo["created_at"],
            "updated_at": todo["updated_at"],
        }

    return json_response(resp_obj, 200)


@app.route("/todos/<int:todo_id>", methods=["DELETE"])
def delete_todo(todo_id: int):
    uid = require_auth()
    if uid is None:
        # For DELETE, still return JSON error with content-type omitted by after_request for 204 only
        return error_response("Authentication required", 401)

    with todo_lock:
        todo = todos.get(todo_id)
        if not todo or todo.get("owner_id") != uid:
            return error_response("Todo not found", 404)
        # Delete
        del todos[todo_id]

    # Return 204 No Content, no body
    resp = make_response("", 204)
    try:
        del resp.headers["Content-Type"]
    except KeyError:
        pass
    return resp


def main():
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()

    # Bind to 0.0.0.0
    app.run(host="0.0.0.0", port=args.port, debug=False, threaded=True)


if __name__ == "__main__":
    main()
