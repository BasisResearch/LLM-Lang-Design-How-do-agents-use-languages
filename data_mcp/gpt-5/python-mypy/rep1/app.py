from __future__ import annotations

import argparse
import re
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple, TypedDict

from flask import Flask, Response, jsonify, make_response, request


# Data models
@dataclass
class User:
    id: int
    username: str
    password: str  # stored as plain for simplicity (in-memory only)


@dataclass
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class RegisterBody(TypedDict):
    username: str
    password: str


class LoginBody(TypedDict):
    username: str
    password: str


class CreateTodoBody(TypedDict, total=False):
    title: str
    description: str


class UpdateTodoBody(TypedDict, total=False):
    title: str
    description: str
    completed: bool


class PasswordChangeBody(TypedDict):
    old_password: str
    new_password: str


# In-memory storage
class Storage:
    def __init__(self) -> None:
        self.users_by_id: Dict[int, User] = {}
        self.users_by_username: Dict[str, User] = {}
        self.todos_by_id: Dict[int, Todo] = {}
        self.todos_by_user: Dict[int, List[int]] = {}
        self.sessions: Dict[str, int] = {}
        self.next_user_id: int = 1
        self.next_todo_id: int = 1

    def create_user(self, username: str, password: str) -> User:
        user = User(id=self.next_user_id, username=username, password=password)
        self.users_by_id[user.id] = user
        self.users_by_username[user.username] = user
        self.todos_by_user[user.id] = []
        self.next_user_id += 1
        return user

    def find_user_by_username(self, username: str) -> Optional[User]:
        return self.users_by_username.get(username)

    def create_session(self, user_id: int) -> str:
        token = uuid.uuid4().hex
        self.sessions[token] = user_id
        return token

    def invalidate_session(self, token: str) -> None:
        if token in self.sessions:
            del self.sessions[token]

    def get_user_by_session(self, token: str) -> Optional[User]:
        uid = self.sessions.get(token)
        if uid is None:
            return None
        return self.users_by_id.get(uid)

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        now = now_iso()
        todo = Todo(
            id=self.next_todo_id,
            user_id=user_id,
            title=title,
            description=description,
            completed=False,
            created_at=now,
            updated_at=now,
        )
        self.todos_by_id[todo.id] = todo
        self.todos_by_user[user_id].append(todo.id)
        self.next_todo_id += 1
        return todo

    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        ids = self.todos_by_user.get(user_id, [])
        # Ensure ascending by id
        sorted_ids = sorted(ids)
        return [self.todos_by_id[i] for i in sorted_ids if i in self.todos_by_id]

    def get_todo_for_user(self, user_id: int, todo_id: int) -> Optional[Todo]:
        todo = self.todos_by_id.get(todo_id)
        if todo is None:
            return None
        if todo.user_id != user_id:
            return None
        return todo

    def delete_todo_for_user(self, user_id: int, todo_id: int) -> bool:
        todo = self.todos_by_id.get(todo_id)
        if todo is None or todo.user_id != user_id:
            return False
        del self.todos_by_id[todo_id]
        # Remove from user's list
        ids = self.todos_by_user.get(user_id, [])
        self.todos_by_user[user_id] = [i for i in ids if i != todo_id]
        return True


# Utility functions

def now_iso() -> str:
    # UTC ISO 8601 with seconds precision and Z
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def user_to_public(user: User) -> Dict[str, Any]:
    return {"id": user.id, "username": user.username}


def todo_to_public(todo: Todo) -> Dict[str, Any]:
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at,
    }


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]+$")


def error_response(message: str, status: int) -> Response:
    resp = jsonify({"error": message})
    resp.status_code = status
    return resp


def get_json_body() -> Dict[str, Any]:
    data = request.get_json(silent=True)
    if data is None or not isinstance(data, dict):
        return {}
    # Defensive copy with str keys only
    result: Dict[str, Any] = {}
    for k, v in data.items():
        if isinstance(k, str):
            result[k] = v
    return result


def require_auth() -> Tuple[Optional[User], Optional[Response]]:
    token = request.cookies.get("session_id")
    if token is None:
        return None, error_response("Authentication required", 401)
    user = storage.get_user_by_session(token)
    if user is None:
        return None, error_response("Authentication required", 401)
    return user, None


# Flask app
app = Flask(__name__)

# Global in-memory storage instance
storage = Storage()


# Routes
@app.post("/register")
def register() -> Response:
    body = get_json_body()
    username = body.get("username") if isinstance(body.get("username"), str) else None
    password = body.get("password") if isinstance(body.get("password"), str) else None

    if username is None or len(username) < 3 or len(username) > 50 or not USERNAME_RE.fullmatch(username):
        return error_response("Invalid username", 400)
    if password is None or len(password) < 8:
        return error_response("Password too short", 400)
    if storage.find_user_by_username(username) is not None:
        return error_response("Username already exists", 409)

    user = storage.create_user(username=username, password=password)
    resp = jsonify(user_to_public(user))
    resp.status_code = 201
    return resp


@app.post("/login")
def login() -> Response:
    body = get_json_body()
    username_val = body.get("username") if isinstance(body.get("username"), str) else None
    password_val = body.get("password") if isinstance(body.get("password"), str) else None

    if username_val is None or password_val is None:
        return error_response("Invalid credentials", 401)

    user = storage.find_user_by_username(username_val)
    if user is None or user.password != password_val:
        return error_response("Invalid credentials", 401)

    token = storage.create_session(user.id)
    resp = jsonify(user_to_public(user))
    # Set-Cookie header
    resp.headers["Set-Cookie"] = f"session_id={token}; Path=/; HttpOnly"
    return resp


@app.post("/logout")
def logout() -> Response:
    _user, err = require_auth()
    if err is not None:
        return err
    # Invalidate the session
    token = request.cookies.get("session_id")
    if token is not None:
        storage.invalidate_session(token)
    # Return empty JSON object
    return jsonify({})


@app.get("/me")
def me() -> Response:
    user, err = require_auth()
    if err is not None or user is None:
        # err cannot be None if user is None here, but guard anyway
        return error_response("Authentication required", 401)
    return jsonify(user_to_public(user))


@app.put("/password")
def change_password() -> Response:
    user, err = require_auth()
    if err is not None or user is None:
        return error_response("Authentication required", 401)

    body = get_json_body()
    old_pw = body.get("old_password") if isinstance(body.get("old_password"), str) else None
    new_pw = body.get("new_password") if isinstance(body.get("new_password"), str) else None

    if old_pw is None or user.password != old_pw:
        return error_response("Invalid credentials", 401)
    if new_pw is None or len(new_pw) < 8:
        return error_response("Password too short", 400)

    user.password = new_pw
    return jsonify({})


@app.get("/todos")
def list_todos() -> Response:
    user, err = require_auth()
    if err is not None or user is None:
        return error_response("Authentication required", 401)
    todos = storage.list_todos_for_user(user.id)
    return jsonify([todo_to_public(t) for t in todos])


@app.post("/todos")
def create_todo() -> Response:
    user, err = require_auth()
    if err is not None or user is None:
        return error_response("Authentication required", 401)

    body = get_json_body()
    title_val_raw = body.get("title")
    title_val = title_val_raw if isinstance(title_val_raw, str) else None
    if title_val is None or title_val.strip() == "":
        return error_response("Title is required", 400)
    description_raw = body.get("description")
    description_val: str = description_raw if isinstance(description_raw, str) else ""

    todo = storage.create_todo(user.id, title_val, description_val)
    resp = jsonify(todo_to_public(todo))
    resp.status_code = 201
    return resp


@app.get("/todos/<int:todo_id>")
def get_todo(todo_id: int) -> Response:
    user, err = require_auth()
    if err is not None or user is None:
        return error_response("Authentication required", 401)

    todo = storage.get_todo_for_user(user.id, todo_id)
    if todo is None:
        return error_response("Todo not found", 404)
    return jsonify(todo_to_public(todo))


@app.put("/todos/<int:todo_id>")
def update_todo(todo_id: int) -> Response:
    user, err = require_auth()
    if err is not None or user is None:
        return error_response("Authentication required", 401)

    todo = storage.get_todo_for_user(user.id, todo_id)
    if todo is None:
        return error_response("Todo not found", 404)

    body = get_json_body()

    if "title" in body:
        title_val = body.get("title") if isinstance(body.get("title"), str) else None
        if title_val is None or title_val.strip() == "":
            return error_response("Title is required", 400)
        todo.title = title_val
    if "description" in body and isinstance(body.get("description"), str):
        # mypy: we already type-checked above
        todo.description = body.get("description")  # type: ignore[assignment]
    if "completed" in body and isinstance(body.get("completed"), bool):
        todo.completed = body.get("completed")  # type: ignore[assignment]

    todo.updated_at = now_iso()

    return jsonify(todo_to_public(todo))


@app.delete("/todos/<int:todo_id>")
def delete_todo(todo_id: int) -> Response:
    user, err = require_auth()
    if err is not None or user is None:
        return error_response("Authentication required", 401)

    ok = storage.delete_todo_for_user(user.id, todo_id)
    if not ok:
        return error_response("Todo not found", 404)

    # 204 No Content, no body, and remove content-type header
    resp = make_response("", 204)
    # Ensure no Content-Type header per spec for DELETE
    try:
        # Some servers may auto-add; remove if present
        del resp.headers["Content-Type"]
    except Exception:
        pass
    return resp



def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()
    app.run(host="0.0.0.0", port=args.port)


if __name__ == "__main__":
    main()
