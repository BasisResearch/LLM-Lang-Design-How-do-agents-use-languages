#!/usr/bin/env python3
from __future__ import annotations

import argparse
import datetime
import json
import re
import threading
import uuid
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

from flask import Flask, Request, Response, make_response, request


# Data models
@dataclass(frozen=True)
class User:
    id: int
    username: str
    password: str  # Stored as plaintext for this exercise (in-memory only)


@dataclass(frozen=True)
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class Storage:
    def __init__(self) -> None:
        self._lock: threading.Lock = threading.Lock()
        self._users_by_id: Dict[int, User] = {}
        self._users_by_username: Dict[str, User] = {}
        self._user_id_counter: int = 1

        self._todos_by_id: Dict[int, Todo] = {}
        self._todo_id_counter: int = 1

        self._sessions: Dict[str, int] = {}  # token -> user_id

    # User management
    def create_user(self, username: str, password: str) -> User:
        with self._lock:
            if username in self._users_by_username:
                raise ValueError("Username exists")
            user = User(id=self._user_id_counter, username=username, password=password)
            self._users_by_id[self._user_id_counter] = user
            self._users_by_username[username] = user
            self._user_id_counter += 1
            return user

    def find_user_by_username(self, username: str) -> Optional[User]:
        with self._lock:
            return self._users_by_username.get(username)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        with self._lock:
            return self._users_by_id.get(user_id)

    def set_user_password(self, user_id: int, new_password: str) -> User:
        with self._lock:
            user = self._users_by_id.get(user_id)
            if user is None:
                raise KeyError("User not found")
            new_user = User(id=user.id, username=user.username, password=new_password)
            self._users_by_id[user_id] = new_user
            self._users_by_username[user.username] = new_user
            return new_user

    # Session management
    def create_session(self, user_id: int) -> str:
        token = uuid.uuid4().hex
        with self._lock:
            self._sessions[token] = user_id
        return token

    def get_user_id_by_session(self, token: str) -> Optional[int]:
        with self._lock:
            return self._sessions.get(token)

    def invalidate_session(self, token: str) -> None:
        with self._lock:
            if token in self._sessions:
                del self._sessions[token]

    # Todo management
    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        now = utc_now_iso()
        with self._lock:
            todo = Todo(
                id=self._todo_id_counter,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=now,
                updated_at=now,
            )
            self._todos_by_id[self._todo_id_counter] = todo
            self._todo_id_counter += 1
            return todo

    def get_todo_for_user(self, todo_id: int, user_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return None
            return todo

    def update_todo(
        self,
        todo_id: int,
        *,
        title: Optional[str],
        description: Optional[str],
        completed: Optional[bool],
    ) -> Optional[Todo]:
        now = utc_now_iso()
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None:
                return None
            new_title = todo.title if title is None else title
            new_description = todo.description if description is None else description
            new_completed = todo.completed if completed is None else completed
            new_todo = Todo(
                id=todo.id,
                user_id=todo.user_id,
                title=new_title,
                description=new_description,
                completed=new_completed,
                created_at=todo.created_at,
                updated_at=now,
            )
            self._todos_by_id[todo_id] = new_todo
            return new_todo

    def delete_todo(self, todo_id: int) -> bool:
        with self._lock:
            if todo_id in self._todos_by_id:
                del self._todos_by_id[todo_id]
                return True
            return False

    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        with self._lock:
            todos = [t for t in self._todos_by_id.values() if t.user_id == user_id]
        todos.sort(key=lambda t: t.id)
        return todos


# Utilities
USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def utc_now_iso() -> str:
    return datetime.datetime.utcnow().replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def json_response(obj: Any, status: int = 200) -> Response:
    body = json.dumps(obj)
    resp = make_response(body, status)
    resp.headers["Content-Type"] = "application/json"
    return resp


def error_response(message: str, status: int) -> Response:
    return json_response({"error": message}, status)


def serialize_user(user: User) -> Dict[str, Any]:
    return {"id": user.id, "username": user.username}


def serialize_todo(todo: Todo) -> Dict[str, Any]:
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at,
    }


app = Flask(__name__)
storage = Storage()


# Helper to get current user from session cookie

def get_current_user_from_request(req: Request) -> Optional[User]:
    token = req.cookies.get("session_id")
    if token is None:
        return None
    user_id = storage.get_user_id_by_session(token)
    if user_id is None:
        return None
    return storage.get_user_by_id(user_id)


# Routes (defined as plain functions and registered via add_url_rule to satisfy mypy)

def register() -> Response:
    data_raw = request.get_json(silent=True)
    data: Dict[str, Any] = data_raw if isinstance(data_raw, dict) else {}
    username_val = data.get("username")
    password_val = data.get("password")

    if not isinstance(username_val, str) or not USERNAME_RE.fullmatch(username_val):
        return error_response("Invalid username", 400)
    if not isinstance(password_val, str) or len(password_val) < 8:
        return error_response("Password too short", 400)

    if storage.find_user_by_username(username_val) is not None:
        return error_response("Username already exists", 409)

    try:
        user = storage.create_user(username=username_val, password=password_val)
    except ValueError:
        return error_response("Username already exists", 409)

    return json_response(serialize_user(user), 201)


def login() -> Response:
    data_raw = request.get_json(silent=True)
    data: Dict[str, Any] = data_raw if isinstance(data_raw, dict) else {}
    username_val = data.get("username")
    password_val = data.get("password")

    if not isinstance(username_val, str) or not isinstance(password_val, str):
        return error_response("Invalid credentials", 401)

    user = storage.find_user_by_username(username_val)
    if user is None or user.password != password_val:
        return error_response("Invalid credentials", 401)

    token = storage.create_session(user.id)
    resp = json_response(serialize_user(user), 200)
    # Set-Cookie: session_id=<token>; Path=/; HttpOnly
    resp.set_cookie("session_id", token, httponly=True, path="/")
    return resp


def logout() -> Response:
    user = get_current_user_from_request(request)
    if user is None:
        return error_response("Authentication required", 401)
    token = request.cookies.get("session_id")
    if token is not None:
        storage.invalidate_session(token)
    return json_response({}, 200)


def me() -> Response:
    user = get_current_user_from_request(request)
    if user is None:
        return error_response("Authentication required", 401)
    return json_response(serialize_user(user), 200)


def change_password() -> Response:
    user = get_current_user_from_request(request)
    if user is None:
        return error_response("Authentication required", 401)

    data_raw = request.get_json(silent=True)
    data: Dict[str, Any] = data_raw if isinstance(data_raw, dict) else {}

    old_password = data.get("old_password")
    new_password = data.get("new_password")

    if not isinstance(old_password, str) or user.password != old_password:
        return error_response("Invalid credentials", 401)
    if not isinstance(new_password, str) or len(new_password) < 8:
        return error_response("Password too short", 400)

    storage.set_user_password(user.id, new_password)
    return json_response({}, 200)


def list_todos() -> Response:
    user = get_current_user_from_request(request)
    if user is None:
        return error_response("Authentication required", 401)

    todos = storage.list_todos_for_user(user.id)
    return json_response([serialize_todo(t) for t in todos], 200)


def create_todo() -> Response:
    user = get_current_user_from_request(request)
    if user is None:
        return error_response("Authentication required", 401)

    data_raw = request.get_json(silent=True)
    data: Dict[str, Any] = data_raw if isinstance(data_raw, dict) else {}

    title_val = data.get("title")
    description_val_raw = data.get("description")

    if not isinstance(title_val, str) or title_val.strip() == "":
        return error_response("Title is required", 400)

    description_val = description_val_raw if isinstance(description_val_raw, str) else ""

    todo = storage.create_todo(user.id, title_val, description_val)
    return json_response(serialize_todo(todo), 201)


def get_todo(todo_id: int) -> Response:
    user = get_current_user_from_request(request)
    if user is None:
        return error_response("Authentication required", 401)

    todo = storage.get_todo_for_user(todo_id, user.id)
    if todo is None:
        return error_response("Todo not found", 404)
    return json_response(serialize_todo(todo), 200)


def update_todo(todo_id: int) -> Response:
    user = get_current_user_from_request(request)
    if user is None:
        return error_response("Authentication required", 401)

    # Must verify existence and ownership first
    existing = storage.get_todo_for_user(todo_id, user.id)
    if existing is None:
        return error_response("Todo not found", 404)

    data_raw = request.get_json(silent=True)
    data: Dict[str, Any] = data_raw if isinstance(data_raw, dict) else {}

    title_update_present = "title" in data
    descr_update_present = "description" in data
    completed_update_present = "completed" in data

    new_title: Optional[str] = None
    new_description: Optional[str] = None
    new_completed: Optional[bool] = None

    if title_update_present:
        title_val = data.get("title")
        if not isinstance(title_val, str) or title_val.strip() == "":
            return error_response("Title is required", 400)
        new_title = title_val

    if descr_update_present:
        descr_val = data.get("description")
        if isinstance(descr_val, str):
            new_description = descr_val
        else:
            new_description = existing.description  # keep as is if not string

    if completed_update_present:
        comp_val = data.get("completed")
        if isinstance(comp_val, bool):
            new_completed = comp_val
        else:
            # If provided but not boolean, keep as is
            new_completed = existing.completed

    updated = storage.update_todo(
        todo_id, title=new_title, description=new_description, completed=new_completed
    )
    # updated cannot be None because we checked existence
    if updated is None:
        return error_response("Todo not found", 404)
    return json_response(serialize_todo(updated), 200)


def delete_todo(todo_id: int) -> Response:
    user = get_current_user_from_request(request)
    if user is None:
        return error_response("Authentication required", 401)

    todo = storage.get_todo_for_user(todo_id, user.id)
    if todo is None:
        return error_response("Todo not found", 404)

    storage.delete_todo(todo_id)
    resp = make_response("", 204)
    # Ensure no Content-Type header for 204 response
    if "Content-Type" in resp.headers:
        del resp.headers["Content-Type"]
    return resp


# Register routes explicitly to avoid untyped decorator complaints in mypy
app.add_url_rule("/register", view_func=register, methods=["POST"])
app.add_url_rule("/login", view_func=login, methods=["POST"])
app.add_url_rule("/logout", view_func=logout, methods=["POST"])
app.add_url_rule("/me", view_func=me, methods=["GET"])
app.add_url_rule("/password", view_func=change_password, methods=["PUT"])
app.add_url_rule("/todos", view_func=list_todos, methods=["GET"])
app.add_url_rule("/todos", view_func=create_todo, methods=["POST"])
app.add_url_rule("/todos/<int:todo_id>", view_func=get_todo, methods=["GET"])
app.add_url_rule("/todos/<int:todo_id>", view_func=update_todo, methods=["PUT"])
app.add_url_rule("/todos/<int:todo_id>", view_func=delete_todo, methods=["DELETE"])


def parse_args() -> Tuple[str, int]:
    parser = argparse.ArgumentParser(description="In-memory Todo API server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()
    return ("0.0.0.0", args.port)


if __name__ == "__main__":
    host, port = parse_args()
    # Disable Flask's default reloader to avoid running app twice
    app.run(host=host, port=port, debug=False, use_reloader=False)
