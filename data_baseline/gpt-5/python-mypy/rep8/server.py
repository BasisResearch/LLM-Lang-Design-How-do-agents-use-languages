from __future__ import annotations

import argparse
import re
import threading
import uuid
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from typing import Any, Dict, List, MutableMapping, Optional, Tuple

from flask import Flask, Request, Response, jsonify, make_response, request


# Data models
@dataclass
class User:
    id: int
    username: str
    password: str  # Plaintext for simplicity per spec (in-memory only)

    def to_public_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "username": self.username}


@dataclass
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str

    def to_public_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
            "completed": self.completed,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


# Storage
class InMemoryStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._users_by_id: Dict[int, User] = {}
        self._users_by_username: Dict[str, User] = {}
        self._todos_by_id: Dict[int, Todo] = {}
        self._sessions: Dict[str, int] = {}  # session_id -> user_id
        self._next_user_id: int = 1
        self._next_todo_id: int = 1

    def _now_iso(self) -> str:
        # ISO 8601 UTC with second precision
        return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")

    def create_user(self, username: str, password: str) -> User:
        with self._lock:
            if username in self._users_by_username:
                raise ValueError("Username already exists")
            user = User(id=self._next_user_id, username=username, password=password)
            self._users_by_id[user.id] = user
            self._users_by_username[username] = user
            self._next_user_id += 1
            return user

    def get_user_by_username(self, username: str) -> Optional[User]:
        with self._lock:
            return self._users_by_username.get(username)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        with self._lock:
            return self._users_by_id.get(user_id)

    def set_user_password(self, user_id: int, new_password: str) -> None:
        with self._lock:
            user = self._users_by_id.get(user_id)
            if user is None:
                return
            user.password = new_password

    def create_session(self, user_id: int) -> str:
        token = uuid.uuid4().hex
        with self._lock:
            self._sessions[token] = user_id
        return token

    def get_user_id_for_session(self, token: str) -> Optional[int]:
        with self._lock:
            return self._sessions.get(token)

    def invalidate_session(self, token: str) -> None:
        with self._lock:
            if token in self._sessions:
                del self._sessions[token]

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        with self._lock:
            todo_id = self._next_todo_id
            now = self._now_iso()
            todo = Todo(
                id=todo_id,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=now,
                updated_at=now,
            )
            self._todos_by_id[todo_id] = todo
            self._next_todo_id += 1
            return todo

    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        with self._lock:
            todos = [t for t in self._todos_by_id.values() if t.user_id == user_id]
            todos.sort(key=lambda t: t.id)
            return list(todos)

    def get_todo_for_user(self, user_id: int, todo_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return None
            return todo

    def update_todo(self, user_id: int, todo_id: int, *, title: Optional[str], description: Optional[str], completed: Optional[bool]) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return None
            changed = False
            if title is not None:
                todo.title = title
                changed = True
            if description is not None:
                todo.description = description
                changed = True
            if completed is not None:
                todo.completed = completed
                changed = True
            if changed:
                todo.updated_at = self._now_iso()
            return todo

    def delete_todo(self, user_id: int, todo_id: int) -> bool:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return False
            del self._todos_by_id[todo_id]
            return True


app = Flask(__name__)
store = InMemoryStore()

USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]+$")


def json_error(message: str, status: int) -> Response:
    resp = jsonify({"error": message})
    resp.status_code = status
    # jsonify already sets Content-Type: application/json
    return resp


def get_json_body(req: Request) -> Optional[Dict[str, Any]]:
    try:
        parsed = req.get_json(silent=True)
    except Exception:
        return None
    if not isinstance(parsed, dict):
        return None
    # Enforce dict[str, Any]
    body: Dict[str, Any] = dict(parsed)
    return body


def require_auth(req: Request) -> Tuple[Optional[User], Optional[str], Optional[Response]]:
    token = req.cookies.get("session_id")
    if token is None:
        return None, None, json_error("Authentication required", 401)
    user_id = store.get_user_id_for_session(token)
    if user_id is None:
        return None, None, json_error("Authentication required", 401)
    user = store.get_user_by_id(user_id)
    if user is None:
        return None, None, json_error("Authentication required", 401)
    return user, token, None


@app.after_request
def set_json_content_type(response: Response) -> Response:
    # Ensure JSON content type for all responses except 204 No Content
    if response.status_code != 204:
        response.headers["Content-Type"] = "application/json"
    else:
        # Remove content-type for 204 to respect no body
        if "Content-Type" in response.headers:
            del response.headers["Content-Type"]
    return response


# Routes
@app.post("/register")
def register() -> Response:
    body = get_json_body(request)
    if body is None:
        return json_error("Invalid JSON", 400)
    username_any = body.get("username")
    password_any = body.get("password")
    if not isinstance(username_any, str) or not USERNAME_RE.match(username_any) or len(username_any) < 3 or len(username_any) > 50:
        return json_error("Invalid username", 400)
    if not isinstance(password_any, str) or len(password_any) < 8:
        return json_error("Password too short", 400)
    username = username_any
    password = password_any
    try:
        user = store.create_user(username, password)
    except ValueError:
        return json_error("Username already exists", 409)
    resp = jsonify(user.to_public_dict())
    resp.status_code = 201
    return resp


@app.post("/login")
def login() -> Response:
    body = get_json_body(request)
    if body is None:
        return json_error("Invalid JSON", 400)
    username_any = body.get("username")
    password_any = body.get("password")
    if not isinstance(username_any, str) or not isinstance(password_any, str):
        return json_error("Invalid credentials", 401)
    user = store.get_user_by_username(username_any)
    if user is None or user.password != password_any:
        return json_error("Invalid credentials", 401)
    token = store.create_session(user.id)
    resp = jsonify(user.to_public_dict())
    resp.set_cookie("session_id", token, httponly=True, path="/")
    return resp


@app.post("/logout")
def logout() -> Response:
    user, token, err = require_auth(request)
    if err is not None:
        return err
    assert token is not None  # for type checker
    # Invalidate session server-side
    store.invalidate_session(token)
    resp = jsonify({})
    # Clear cookie on client side as well
    resp.set_cookie("session_id", "", httponly=True, path="/", max_age=0)
    return resp


@app.get("/me")
def me() -> Response:
    user, _token, err = require_auth(request)
    if err is not None:
        return err
    assert user is not None
    return jsonify(user.to_public_dict())


@app.put("/password")
def change_password() -> Response:
    user, _token, err = require_auth(request)
    if err is not None:
        return err
    assert user is not None
    body = get_json_body(request)
    if body is None:
        return json_error("Invalid JSON", 400)
    old_any = body.get("old_password")
    new_any = body.get("new_password")
    if not isinstance(old_any, str) or not isinstance(new_any, str):
        return json_error("Invalid JSON", 400)
    if old_any != user.password:
        return json_error("Invalid credentials", 401)
    if len(new_any) < 8:
        return json_error("Password too short", 400)
    store.set_user_password(user.id, new_any)
    return jsonify({})


@app.get("/todos")
def list_todos() -> Response:
    user, _token, err = require_auth(request)
    if err is not None:
        return err
    assert user is not None
    todos = [t.to_public_dict() for t in store.list_todos_for_user(user.id)]
    return jsonify(todos)


@app.post("/todos")
def create_todo() -> Response:
    user, _token, err = require_auth(request)
    if err is not None:
        return err
    assert user is not None
    body = get_json_body(request)
    if body is None:
        return json_error("Invalid JSON", 400)
    title_any = body.get("title")
    description_any = body.get("description", "")
    if not isinstance(title_any, str) or title_any.strip() == "":
        return json_error("Title is required", 400)
    if not isinstance(description_any, str):
        return json_error("Invalid JSON", 400)
    todo = store.create_todo(user.id, title_any, description_any)
    resp = jsonify(todo.to_public_dict())
    resp.status_code = 201
    return resp


def parse_int_id(id_str: str) -> Optional[int]:
    try:
        val = int(id_str)
    except ValueError:
        return None
    if val < 1:
        return None
    return val


@app.get("/todos/<id_str>")
def get_todo(id_str: str) -> Response:
    user, _token, err = require_auth(request)
    if err is not None:
        return err
    assert user is not None
    todo_id = parse_int_id(id_str)
    if todo_id is None:
        return json_error("Todo not found", 404)
    todo = store.get_todo_for_user(user.id, todo_id)
    if todo is None:
        return json_error("Todo not found", 404)
    return jsonify(todo.to_public_dict())


@app.put("/todos/<id_str>")
def update_todo(id_str: str) -> Response:
    user, _token, err = require_auth(request)
    if err is not None:
        return err
    assert user is not None
    todo_id = parse_int_id(id_str)
    if todo_id is None:
        return json_error("Todo not found", 404)
    body = get_json_body(request)
    if body is None:
        return json_error("Invalid JSON", 400)

    title: Optional[str] = None
    description: Optional[str] = None
    completed: Optional[bool] = None

    if "title" in body:
        title_any = body.get("title")
        if not isinstance(title_any, str):
            return json_error("Invalid JSON", 400)
        if title_any.strip() == "":
            return json_error("Title is required", 400)
        title = title_any
    if "description" in body:
        description_any = body.get("description")
        if not isinstance(description_any, str):
            return json_error("Invalid JSON", 400)
        description = description_any
    if "completed" in body:
        completed_any = body.get("completed")
        if not isinstance(completed_any, bool):
            return json_error("Invalid JSON", 400)
        completed = completed_any

    todo = store.update_todo(user.id, todo_id, title=title, description=description, completed=completed)
    if todo is None:
        return json_error("Todo not found", 404)
    return jsonify(todo.to_public_dict())


@app.delete("/todos/<id_str>")
def delete_todo(id_str: str) -> Response:
    user, _token, err = require_auth(request)
    if err is not None:
        return err
    assert user is not None
    todo_id = parse_int_id(id_str)
    if todo_id is None:
        # For 204 delete we must return 404 JSON, but DELETE endpoint specifies no body only on success (204)
        return json_error("Todo not found", 404)
    ok = store.delete_todo(user.id, todo_id)
    if not ok:
        return json_error("Todo not found", 404)
    # Return 204 No Content with no body and no JSON content type
    resp = make_response("", 204)
    # Remove content-type header if any
    if "Content-Type" in resp.headers:
        del resp.headers["Content-Type"]
    return resp



def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()
    port = args.port
    # Bind to 0.0.0.0 per spec
    app.run(host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
