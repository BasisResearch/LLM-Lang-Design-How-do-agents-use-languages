from __future__ import annotations

import argparse
import hmac
import os
import re
import sys
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple, cast

from flask import Flask, Request, Response, jsonify, request


# Data models
@dataclass
class User:
    id: int
    username: str
    password_salt_hex: str
    password_hash_hex: str


@dataclass
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class InMemoryDB:
    def __init__(self) -> None:
        self.users_by_id: Dict[int, User] = {}
        self.users_by_username: Dict[str, User] = {}
        self.next_user_id: int = 1

        self.todos_by_id: Dict[int, Todo] = {}
        self.next_todo_id: int = 1

        # session_id token -> user_id
        self.sessions: Dict[str, int] = {}

    def create_user(self, username: str, password: str) -> User:
        user_id = self.next_user_id
        self.next_user_id += 1
        salt_hex, hash_hex = generate_password_hash(password)
        user = User(id=user_id, username=username, password_salt_hex=salt_hex, password_hash_hex=hash_hex)
        self.users_by_id[user_id] = user
        self.users_by_username[username] = user
        return user

    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        now = now_utc_iso()
        todo_id = self.next_todo_id
        self.next_todo_id += 1
        todo = Todo(
            id=todo_id,
            user_id=user_id,
            title=title,
            description=description,
            completed=False,
            created_at=now,
            updated_at=now,
        )
        self.todos_by_id[todo_id] = todo
        return todo


def now_utc_iso() -> str:
    # ISO 8601 UTC with seconds precision, e.g., 2025-01-15T09:30:00Z
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def generate_password_hash(password: str) -> Tuple[str, str]:
    # Use PBKDF2-HMAC-SHA256
    salt = os.urandom(16)
    import hashlib

    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100_000)
    return salt.hex(), dk.hex()


def verify_password(salt_hex: str, expected_hash_hex: str, password: str) -> bool:
    import hashlib

    salt = bytes.fromhex(salt_hex)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, 100_000)
    return hmac.compare_digest(dk.hex(), expected_hash_hex)


def user_to_dict(user: User) -> Dict[str, Any]:
    return {"id": user.id, "username": user.username}


def todo_to_dict(todo: Todo) -> Dict[str, Any]:
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at,
    }


def make_json(data: Any, status: int = 200) -> Response:
    resp_any = jsonify(data)
    resp = cast(Response, resp_any)
    resp.status_code = status
    return resp


def error_response(message: str, status: int) -> Response:
    return make_json({"error": message}, status)


def get_json_body(req: Request) -> Dict[str, Any]:
    data = req.get_json(silent=True)
    if isinstance(data, dict):
        # Ensure keys are strings
        return {str(k): v for k, v in data.items()}
    return {}


def generate_session_token() -> str:
    return uuid.uuid4().hex


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


def create_app() -> Flask:
    app = Flask(__name__)

    db = InMemoryDB()

    def get_current_user() -> Tuple[Optional[User], Optional[Response]]:
        token = request.cookies.get("session_id")
        if token is None:
            return None, error_response("Authentication required", 401)
        user_id = db.sessions.get(token)
        if user_id is None:
            return None, error_response("Authentication required", 401)
        user = db.users_by_id.get(user_id)
        if user is None:
            # Should not happen, but treat as invalid session
            return None, error_response("Authentication required", 401)
        return user, None

    @app.after_request
    def set_json_content_type(resp: Response) -> Response:
        # Ensure Content-Type is application/json for all responses except 204 (DELETE)
        if resp.status_code != 204:
            resp.headers["Content-Type"] = "application/json"
        return resp

    @app.route("/register", methods=["POST"])
    def register() -> Response:
        body = get_json_body(request)
        username_val = body.get("username")
        password_val = body.get("password")

        if not isinstance(username_val, str) or not USERNAME_RE.fullmatch(username_val):
            return error_response("Invalid username", 400)
        if not isinstance(password_val, str) or len(password_val) < 8:
            return error_response("Password too short", 400)
        if username_val in db.users_by_username:
            return error_response("Username already exists", 409)

        user = db.create_user(username_val, password_val)
        return make_json(user_to_dict(user), 201)

    @app.route("/login", methods=["POST"])
    def login() -> Response:
        body = get_json_body(request)
        username_val = body.get("username")
        password_val = body.get("password")
        if not isinstance(username_val, str) or not isinstance(password_val, str):
            return error_response("Invalid credentials", 401)
        user = db.users_by_username.get(username_val)
        if user is None:
            return error_response("Invalid credentials", 401)
        if not verify_password(user.password_salt_hex, user.password_hash_hex, password_val):
            return error_response("Invalid credentials", 401)

        token = generate_session_token()
        db.sessions[token] = user.id
        resp = make_json(user_to_dict(user), 200)
        # Set-Cookie: session_id=<token>; Path=/; HttpOnly
        resp.set_cookie("session_id", token, httponly=True, path="/")
        return resp

    @app.route("/logout", methods=["POST"])
    def logout() -> Response:
        user, err = get_current_user()
        if err is not None:
            return err
        assert user is not None  # for mypy
        token = request.cookies.get("session_id")
        if token is not None:
            db.sessions.pop(token, None)
        resp = make_json({}, 200)
        # Clear cookie client-side as well (optional but courteous)
        resp.set_cookie("session_id", "", expires=0, path="/")
        return resp

    @app.route("/me", methods=["GET"])
    def me() -> Response:
        user, err = get_current_user()
        if err is not None:
            return err
        assert user is not None
        return make_json(user_to_dict(user), 200)

    @app.route("/password", methods=["PUT"])
    def change_password() -> Response:
        user, err = get_current_user()
        if err is not None:
            return err
        assert user is not None
        body = get_json_body(request)
        old_pw = body.get("old_password")
        new_pw = body.get("new_password")
        if not isinstance(old_pw, str) or not verify_password(user.password_salt_hex, user.password_hash_hex, old_pw):
            return error_response("Invalid credentials", 401)
        if not isinstance(new_pw, str) or len(new_pw) < 8:
            return error_response("Password too short", 400)
        # Update password
        salt_hex, hash_hex = generate_password_hash(new_pw)
        user.password_salt_hex = salt_hex
        user.password_hash_hex = hash_hex
        return make_json({}, 200)

    @app.route("/todos", methods=["GET"])
    def list_todos() -> Response:
        user, err = get_current_user()
        if err is not None:
            return err
        assert user is not None
        todos: List[Todo] = [t for t in db.todos_by_id.values() if t.user_id == user.id]
        todos.sort(key=lambda t: t.id)
        return make_json([todo_to_dict(t) for t in todos], 200)

    @app.route("/todos", methods=["POST"])
    def create_todo() -> Response:
        user, err = get_current_user()
        if err is not None:
            return err
        assert user is not None
        body = get_json_body(request)
        title_val = body.get("title")
        description_val = body.get("description")
        if not isinstance(title_val, str) or title_val.strip() == "":
            return error_response("Title is required", 400)
        description_str = description_val if isinstance(description_val, str) else ""
        todo = db.create_todo(user.id, title_val, description_str)
        return make_json(todo_to_dict(todo), 201)

    def get_todo_if_allowed(todo_id: int, user_id: int) -> Optional[Todo]:
        todo = db.todos_by_id.get(todo_id)
        if todo is None:
            return None
        if todo.user_id != user_id:
            # Do not reveal existence
            return None
        return todo

    @app.route("/todos/<int:todo_id>", methods=["GET"])
    def get_todo(todo_id: int) -> Response:
        user, err = get_current_user()
        if err is not None:
            return err
        assert user is not None
        todo = get_todo_if_allowed(todo_id, user.id)
        if todo is None:
            return error_response("Todo not found", 404)
        return make_json(todo_to_dict(todo), 200)

    @app.route("/todos/<int:todo_id>", methods=["PUT"])
    def update_todo(todo_id: int) -> Response:
        user, err = get_current_user()
        if err is not None:
            return err
        assert user is not None
        todo = get_todo_if_allowed(todo_id, user.id)
        if todo is None:
            return error_response("Todo not found", 404)
        body = get_json_body(request)
        if "title" in body:
            title_val = body.get("title")
            if not isinstance(title_val, str) or title_val.strip() == "":
                return error_response("Title is required", 400)
            todo.title = title_val
        if "description" in body:
            desc_val = body.get("description")
            if isinstance(desc_val, str):
                todo.description = desc_val
        if "completed" in body:
            comp_val = body.get("completed")
            if isinstance(comp_val, bool):
                todo.completed = comp_val
        # Update timestamp if any change occurred; to be safe, always update on PUT
        todo.updated_at = now_utc_iso()
        return make_json(todo_to_dict(todo), 200)

    @app.route("/todos/<int:todo_id>", methods=["DELETE"])
    def delete_todo(todo_id: int) -> Response:
        user, err = get_current_user()
        if err is not None:
            return err
        assert user is not None
        todo = get_todo_if_allowed(todo_id, user.id)
        if todo is None:
            return error_response("Todo not found", 404)
        db.todos_by_id.pop(todo_id, None)
        # 204 No Content, no body
        return Response(status=204)

    return app


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args(argv)

    app = create_app()
    # Bind to 0.0.0.0:PORT
    app.run(host="0.0.0.0", port=args.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
