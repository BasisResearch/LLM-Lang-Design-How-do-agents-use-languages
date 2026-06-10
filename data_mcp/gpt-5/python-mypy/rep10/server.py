from __future__ import annotations

import argparse
import re
import secrets
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from typing import Any, Callable, Dict, List, Mapping, MutableMapping, Optional, Tuple, TypedDict, cast

from flask import Flask, jsonify, request, Response, make_response


# Type aliases
JSONDict = Dict[str, Any]


class UserPublic(TypedDict):
    id: int
    username: str


@dataclass(frozen=True)
class User:
    id: int
    username: str
    # Store password as salted hash (hex string) and salt (hex string)
    password_hash: str
    salt: str

    def to_public(self) -> UserPublic:
        return UserPublic(id=self.id, username=self.username)


class TodoPublic(TypedDict):
    id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


@dataclass
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str

    def to_public(self) -> TodoPublic:
        return TodoPublic(
            id=self.id,
            title=self.title,
            description=self.description,
            completed=self.completed,
            created_at=self.created_at,
            updated_at=self.updated_at,
        )


class Storage:
    def __init__(self) -> None:
        self._users_by_id: Dict[int, User] = {}
        self._users_by_username: Dict[str, User] = {}
        self._todos_by_id: Dict[int, Todo] = {}
        self._todos_by_user: Dict[int, List[int]] = {}
        self._sessions: Dict[str, int] = {}  # session_id -> user_id
        self._next_user_id: int = 1
        self._next_todo_id: int = 1

    # User operations
    def is_username_taken(self, username: str) -> bool:
        return username in self._users_by_username

    def add_user(self, username: str, password_hash: str, salt: str) -> User:
        uid = self._next_user_id
        self._next_user_id += 1
        user = User(id=uid, username=username, password_hash=password_hash, salt=salt)
        self._users_by_id[uid] = user
        self._users_by_username[username] = user
        return user

    def get_user_by_username(self, username: str) -> Optional[User]:
        return self._users_by_username.get(username)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        return self._users_by_id.get(user_id)

    def update_user_password(self, user_id: int, password_hash: str, salt: str) -> None:
        user = self._users_by_id[user_id]
        updated = User(id=user.id, username=user.username, password_hash=password_hash, salt=salt)
        self._users_by_id[user_id] = updated
        self._users_by_username[user.username] = updated

    # Session operations
    def create_session(self, user_id: int) -> str:
        token = secrets.token_hex(16)
        self._sessions[token] = user_id
        return token

    def get_user_id_for_session(self, token: str) -> Optional[int]:
        return self._sessions.get(token)

    def invalidate_session(self, token: str) -> None:
        self._sessions.pop(token, None)

    # Todo operations
    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        ids = self._todos_by_user.get(user_id, [])
        # Already stored in ascending id order
        return [self._todos_by_id[i] for i in ids]

    def add_todo(self, user_id: int, title: str, description: str) -> Todo:
        tid = self._next_todo_id
        self._next_todo_id += 1
        now = current_time_str()
        todo = Todo(
            id=tid,
            user_id=user_id,
            title=title,
            description=description,
            completed=False,
            created_at=now,
            updated_at=now,
        )
        self._todos_by_id[tid] = todo
        self._todos_by_user.setdefault(user_id, []).append(tid)
        return todo

    def get_todo_if_owned(self, todo_id: int, user_id: int) -> Optional[Todo]:
        todo = self._todos_by_id.get(todo_id)
        if todo is None:
            return None
        if todo.user_id != user_id:
            return None
        return todo

    def update_todo(
        self,
        todo: Todo,
        *,
        title: Optional[str] = None,
        description: Optional[str] = None,
        completed: Optional[bool] = None,
    ) -> Todo:
        if title is not None:
            todo.title = title
        if description is not None:
            todo.description = description
        if completed is not None:
            todo.completed = completed
        todo.updated_at = current_time_str()
        return todo

    def delete_todo(self, todo_id: int) -> None:
        todo = self._todos_by_id.pop(todo_id, None)
        if todo is None:
            return
        ids = self._todos_by_user.get(todo.user_id)
        if ids is not None:
            try:
                ids.remove(todo_id)
            except ValueError:
                pass


def current_time_str() -> str:
    # ISO 8601 UTC with seconds precision, Z suffix
    now = datetime.now(timezone.utc).replace(microsecond=0)
    return now.strftime("%Y-%m-%dT%H:%M:%SZ")


def hash_password(password: str, salt_hex: Optional[str] = None) -> Tuple[str, str]:
    import hashlib
    if salt_hex is None:
        salt_bytes = secrets.token_bytes(16)
        salt_hex = salt_bytes.hex()
    else:
        salt_bytes = bytes.fromhex(salt_hex)
    # Using PBKDF2-HMAC-SHA256
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt_bytes, 100_000)
    return dk.hex(), salt_hex


def verify_password(password: str, stored_hash: str, salt_hex: str) -> bool:
    computed, _ = hash_password(password, salt_hex)
    # Use secrets.compare_digest for timing safety
    return secrets.compare_digest(computed, stored_hash)


# Initialize Flask app and storage
app = Flask(__name__)
storage = Storage()


# Utilities for responses

def json_error(message: str, status: int) -> Response:
    resp = make_response(jsonify({"error": message}), status)
    resp.headers["Content-Type"] = "application/json"
    return resp


def require_auth() -> Optional[int]:
    token = request.cookies.get("session_id")
    if token is None:
        return None
    uid = storage.get_user_id_for_session(token)
    return uid


# Endpoint implementations

@app.post("/register")
def register() -> Response:
    body = cast(Optional[Mapping[str, Any]], request.get_json(silent=True))
    if body is None:
        return json_error("Invalid JSON", 400)
    username_val = body.get("username")
    password_val = body.get("password")
    if not isinstance(username_val, str):
        return json_error("Invalid username", 400)
    if not isinstance(password_val, str):
        return json_error("Password too short", 400)

    username = username_val
    password = password_val

    if not (3 <= len(username) <= 50) or re.fullmatch(r"^[a-zA-Z0-9_]+$", username) is None:
        return json_error("Invalid username", 400)
    if len(password) < 8:
        return json_error("Password too short", 400)
    if storage.is_username_taken(username):
        return json_error("Username already exists", 409)

    pw_hash, salt = hash_password(password)
    user = storage.add_user(username, pw_hash, salt)
    resp = make_response(jsonify(user.to_public()), 201)
    resp.headers["Content-Type"] = "application/json"
    return resp


@app.post("/login")
def login() -> Response:
    body = cast(Optional[Mapping[str, Any]], request.get_json(silent=True))
    if body is None:
        return json_error("Invalid credentials", 401)
    username_val = body.get("username")
    password_val = body.get("password")
    if not isinstance(username_val, str) or not isinstance(password_val, str):
        return json_error("Invalid credentials", 401)
    user = storage.get_user_by_username(username_val)
    if user is None:
        return json_error("Invalid credentials", 401)
    if not verify_password(password_val, user.password_hash, user.salt):
        return json_error("Invalid credentials", 401)

    token = storage.create_session(user.id)
    resp = make_response(jsonify(user.to_public()), 200)
    resp.set_cookie("session_id", token, path="/", httponly=True)
    resp.headers["Content-Type"] = "application/json"
    return resp


@app.post("/logout")
def logout() -> Response:
    uid = require_auth()
    if uid is None:
        return json_error("Authentication required", 401)
    token = request.cookies.get("session_id")
    if token is not None:
        storage.invalidate_session(token)
    resp = make_response(jsonify({}), 200)
    # Invalidate cookie on client side too (optional but good practice)
    resp.set_cookie("session_id", "", path="/", httponly=True, expires=0)
    resp.headers["Content-Type"] = "application/json"
    return resp


@app.get("/me")
def me() -> Response:
    uid = require_auth()
    if uid is None:
        return json_error("Authentication required", 401)
    user = storage.get_user_by_id(uid)
    assert user is not None  # if session is valid, user must exist
    resp = make_response(jsonify(user.to_public()), 200)
    resp.headers["Content-Type"] = "application/json"
    return resp


@app.put("/password")
def change_password() -> Response:
    uid = require_auth()
    if uid is None:
        return json_error("Authentication required", 401)
    body = cast(Optional[Mapping[str, Any]], request.get_json(silent=True))
    if body is None:
        return json_error("Invalid credentials", 401)
    old_val = body.get("old_password")
    new_val = body.get("new_password")
    if not isinstance(old_val, str) or not isinstance(new_val, str):
        return json_error("Invalid credentials", 401)
    if len(new_val) < 8:
        return json_error("Password too short", 400)

    user = storage.get_user_by_id(uid)
    assert user is not None
    if not verify_password(old_val, user.password_hash, user.salt):
        return json_error("Invalid credentials", 401)

    pw_hash, salt = hash_password(new_val)
    storage.update_user_password(uid, pw_hash, salt)
    resp = make_response(jsonify({}), 200)
    resp.headers["Content-Type"] = "application/json"
    return resp


@app.get("/todos")
def list_todos() -> Response:
    uid = require_auth()
    if uid is None:
        return json_error("Authentication required", 401)
    todos = storage.list_todos_for_user(uid)
    data = [t.to_public() for t in todos]
    resp = make_response(jsonify(data), 200)
    resp.headers["Content-Type"] = "application/json"
    return resp


@app.post("/todos")
def create_todo() -> Response:
    uid = require_auth()
    if uid is None:
        return json_error("Authentication required", 401)
    body = cast(Optional[Mapping[str, Any]], request.get_json(silent=True))
    if body is None:
        return json_error("Title is required", 400)
    title_val = body.get("title")
    description_val = body.get("description")
    if not isinstance(title_val, str) or title_val.strip() == "":
        return json_error("Title is required", 400)
    title = title_val
    description = description_val if isinstance(description_val, str) else ""

    todo = storage.add_todo(uid, title, description)
    resp = make_response(jsonify(todo.to_public()), 201)
    resp.headers["Content-Type"] = "application/json"
    return resp


@app.get("/todos/<int:todo_id>")
def get_todo(todo_id: int) -> Response:
    uid = require_auth()
    if uid is None:
        return json_error("Authentication required", 401)
    todo = storage.get_todo_if_owned(todo_id, uid)
    if todo is None:
        return json_error("Todo not found", 404)
    resp = make_response(jsonify(todo.to_public()), 200)
    resp.headers["Content-Type"] = "application/json"
    return resp


@app.put("/todos/<int:todo_id>")
def update_todo(todo_id: int) -> Response:
    uid = require_auth()
    if uid is None:
        return json_error("Authentication required", 401)
    todo = storage.get_todo_if_owned(todo_id, uid)
    if todo is None:
        return json_error("Todo not found", 404)
    body = cast(Optional[Mapping[str, Any]], request.get_json(silent=True))
    if body is None:
        # No updates; still update timestamp per spec on modification; here treat as no-op
        storage.update_todo(todo)
        resp = make_response(jsonify(todo.to_public()), 200)
        resp.headers["Content-Type"] = "application/json"
        return resp

    title_update: Optional[str] = None
    description_update: Optional[str] = None
    completed_update: Optional[bool] = None

    if "title" in body:
        tv = body.get("title")
        if not isinstance(tv, str) or tv.strip() == "":
            return json_error("Title is required", 400)
        title_update = tv
    if "description" in body:
        dv = body.get("description")
        if isinstance(dv, str):
            description_update = dv
    if "completed" in body:
        cv = body.get("completed")
        if isinstance(cv, bool):
            completed_update = cv

    storage.update_todo(todo, title=title_update, description=description_update, completed=completed_update)
    resp = make_response(jsonify(todo.to_public()), 200)
    resp.headers["Content-Type"] = "application/json"
    return resp


@app.delete("/todos/<int:todo_id>")
def delete_todo(todo_id: int) -> Response:
    uid = require_auth()
    if uid is None:
        # Per spec, still return JSON for errors, but DELETE success should have no body.
        return json_error("Authentication required", 401)
    todo = storage.get_todo_if_owned(todo_id, uid)
    if todo is None:
        return json_error("Todo not found", 404)
    storage.delete_todo(todo_id)
    # 204 No Content, no body
    return Response(status=204)



def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()
    port = int(args.port)
    app.run(host="0.0.0.0", port=port, debug=False, use_reloader=False)


if __name__ == "__main__":
    main()
