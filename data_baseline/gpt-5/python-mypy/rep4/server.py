from __future__ import annotations

import argparse
import re
import threading
import uuid
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple, TypedDict, Any

from fastapi import FastAPI, Request
from starlette.responses import JSONResponse, Response


# Typed dictionaries for internal and public representations
class UserInternal(TypedDict):
    id: int
    username: str
    password: str


class UserPublic(TypedDict):
    id: int
    username: str


class TodoInternal(TypedDict):
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class TodoPublic(TypedDict):
    id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class ApiError(Exception):
    def __init__(self, status_code: int, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.message = message


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def public_user(user: UserInternal) -> UserPublic:
    return {"id": user["id"], "username": user["username"]}


def public_todo(todo: TodoInternal) -> TodoPublic:
    return {
        "id": todo["id"],
        "title": todo["title"],
        "description": todo["description"],
        "completed": todo["completed"],
        "created_at": todo["created_at"],
        "updated_at": todo["updated_at"],
    }


class AppState:
    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._next_user_id: int = 1
        self._next_todo_id: int = 1
        self._users_by_id: Dict[int, UserInternal] = {}
        self._usernames: Dict[str, int] = {}
        self._sessions: Dict[str, int] = {}
        self._todos_by_id: Dict[int, TodoInternal] = {}

    # Lock helpers
    def lock(self) -> threading.RLock:
        return self._lock

    # User operations
    def create_user(self, username: str, password: str) -> UserPublic:
        with self._lock:
            if username in self._usernames:
                raise ApiError(409, "Username already exists")
            user_id = self._next_user_id
            self._next_user_id += 1
            user: UserInternal = {"id": user_id, "username": username, "password": password}
            self._users_by_id[user_id] = user
            self._usernames[username] = user_id
            return public_user(user)

    def get_user_by_username(self, username: str) -> Optional[UserInternal]:
        with self._lock:
            user_id = self._usernames.get(username)
            if user_id is None:
                return None
            return self._users_by_id.get(user_id)

    def get_user_by_id(self, user_id: int) -> Optional[UserInternal]:
        with self._lock:
            return self._users_by_id.get(user_id)

    def set_user_password(self, user_id: int, new_password: str) -> None:
        with self._lock:
            user = self._users_by_id.get(user_id)
            if user is None:
                raise ApiError(500, "Internal server error")
            user["password"] = new_password

    # Session operations
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
            self._sessions.pop(token, None)

    # Todo operations
    def create_todo(self, user_id: int, title: str, description: str) -> TodoPublic:
        with self._lock:
            todo_id = self._next_todo_id
            self._next_todo_id += 1
            created = now_iso()
            todo: TodoInternal = {
                "id": todo_id,
                "user_id": user_id,
                "title": title,
                "description": description,
                "completed": False,
                "created_at": created,
                "updated_at": created,
            }
            self._todos_by_id[todo_id] = todo
            return public_todo(todo)

    def list_todos_for_user(self, user_id: int) -> List[TodoPublic]:
        with self._lock:
            todos = [t for t in self._todos_by_id.values() if t["user_id"] == user_id]
            todos.sort(key=lambda x: x["id"])  # in-place
            return [public_todo(t) for t in todos]

    def get_todo_for_user(self, user_id: int, todo_id: int) -> Optional[TodoInternal]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo["user_id"] != user_id:
                return None
            return todo

    def update_todo_for_user(self, user_id: int, todo_id: int, *,
                              title: Optional[str], description: Optional[str], completed: Optional[bool]) -> Optional[TodoPublic]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo["user_id"] != user_id:
                return None
            if title is not None:
                todo["title"] = title
            if description is not None:
                todo["description"] = description
            if completed is not None:
                todo["completed"] = completed
            todo["updated_at"] = now_iso()
            return public_todo(todo)

    def delete_todo_for_user(self, user_id: int, todo_id: int) -> bool:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo["user_id"] != user_id:
                return False
            del self._todos_by_id[todo_id]
            return True


app = FastAPI()
state = AppState()


@app.exception_handler(ApiError)
async def api_error_handler(_: Request, exc: ApiError) -> JSONResponse:
    return JSONResponse(status_code=exc.status_code, content={"error": exc.message})


def get_json_body(data: Any) -> Dict[str, Any]:
    if isinstance(data, dict):
        # Ensure keys are strings for safer access
        return {str(k): v for k, v in data.items()}
    raise ApiError(400, "Invalid JSON body")


def get_session_token_from_request(request: Request) -> Optional[str]:
    cookie_header = request.cookies.get("session_id")
    if cookie_header is None:
        return None
    return cookie_header


def require_auth(request: Request) -> Tuple[UserInternal, str]:
    token = get_session_token_from_request(request)
    if token is None:
        raise ApiError(401, "Authentication required")
    user_id = state.get_user_id_by_session(token)
    if user_id is None:
        raise ApiError(401, "Authentication required")
    user = state.get_user_by_id(user_id)
    if user is None:
        # Should not happen but handle safely
        raise ApiError(401, "Authentication required")
    return user, token


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


@app.post("/register")
async def register(request: Request) -> JSONResponse:
    try:
        payload_raw = await request.json()
    except Exception:
        raise ApiError(400, "Invalid JSON body")
    payload = get_json_body(payload_raw)

    username_val = payload.get("username")
    password_val = payload.get("password")

    if not isinstance(username_val, str) or not USERNAME_RE.fullmatch(username_val):
        raise ApiError(400, "Invalid username")
    if not isinstance(password_val, str) or len(password_val) < 8:
        raise ApiError(400, "Password too short")

    user_public = state.create_user(username_val, password_val)
    return JSONResponse(status_code=201, content=user_public)


@app.post("/login")
async def login(request: Request) -> JSONResponse:
    try:
        payload_raw = await request.json()
    except Exception:
        raise ApiError(400, "Invalid JSON body")
    payload = get_json_body(payload_raw)

    username_val = payload.get("username")
    password_val = payload.get("password")

    if not isinstance(username_val, str) or not isinstance(password_val, str):
        raise ApiError(401, "Invalid credentials")

    user = state.get_user_by_username(username_val)
    if user is None or user["password"] != password_val:
        raise ApiError(401, "Invalid credentials")

    token = state.create_session(user["id"])
    resp = JSONResponse(status_code=200, content=public_user(user))
    # Set-Cookie: session_id=<token>; Path=/; HttpOnly
    resp.set_cookie(key="session_id", value=token, path="/", httponly=True)
    return resp


@app.post("/logout")
async def logout(request: Request) -> JSONResponse:
    user, token = require_auth(request)
    # invalidate token
    state.invalidate_session(token)
    # Return empty JSON
    _ = user  # suppress unused variable in static analysis
    return JSONResponse(status_code=200, content={})


@app.get("/me")
async def me(request: Request) -> JSONResponse:
    user, _ = require_auth(request)
    return JSONResponse(status_code=200, content=public_user(user))


@app.put("/password")
async def change_password(request: Request) -> JSONResponse:
    user, _ = require_auth(request)
    try:
        payload_raw = await request.json()
    except Exception:
        raise ApiError(400, "Invalid JSON body")
    payload = get_json_body(payload_raw)

    old_password_val = payload.get("old_password")
    new_password_val = payload.get("new_password")

    if not isinstance(old_password_val, str) or user["password"] != old_password_val:
        raise ApiError(401, "Invalid credentials")
    if not isinstance(new_password_val, str) or len(new_password_val) < 8:
        raise ApiError(400, "Password too short")

    state.set_user_password(user["id"], new_password_val)
    return JSONResponse(status_code=200, content={})


@app.get("/todos")
async def list_todos(request: Request) -> JSONResponse:
    user, _ = require_auth(request)
    todos = state.list_todos_for_user(user["id"])
    return JSONResponse(status_code=200, content=todos)


@app.post("/todos")
async def create_todo(request: Request) -> JSONResponse:
    user, _ = require_auth(request)
    try:
        payload_raw = await request.json()
    except Exception:
        raise ApiError(400, "Invalid JSON body")
    payload = get_json_body(payload_raw)

    title_val = payload.get("title")
    description_val = payload.get("description", "")

    if not isinstance(title_val, str) or title_val.strip() == "":
        raise ApiError(400, "Title is required")
    if not isinstance(description_val, str):
        description_val = ""

    todo_public = state.create_todo(user["id"], title_val, description_val)
    return JSONResponse(status_code=201, content=todo_public)


@app.get("/todos/{todo_id}")
async def get_todo(todo_id: int, request: Request) -> JSONResponse:
    user, _ = require_auth(request)
    todo = state.get_todo_for_user(user["id"], todo_id)
    if todo is None:
        raise ApiError(404, "Todo not found")
    return JSONResponse(status_code=200, content=public_todo(todo))


@app.put("/todos/{todo_id}")
async def update_todo(todo_id: int, request: Request) -> JSONResponse:
    user, _ = require_auth(request)
    try:
        payload_raw = await request.json()
    except Exception:
        raise ApiError(400, "Invalid JSON body")
    payload = get_json_body(payload_raw)

    title_to_set: Optional[str] = None
    description_to_set: Optional[str] = None
    completed_to_set: Optional[bool] = None

    if "title" in payload:
        title_val = payload.get("title")
        if not isinstance(title_val, str) or title_val.strip() == "":
            raise ApiError(400, "Title is required")
        title_to_set = title_val
    if "description" in payload:
        desc_val = payload.get("description")
        if isinstance(desc_val, str):
            description_to_set = desc_val
        else:
            description_to_set = ""
    if "completed" in payload:
        comp_val = payload.get("completed")
        if isinstance(comp_val, bool):
            completed_to_set = comp_val
        else:
            # Treat non-bool as False for safety
            completed_to_set = False

    updated = state.update_todo_for_user(user["id"], todo_id, title=title_to_set, description=description_to_set, completed=completed_to_set)
    if updated is None:
        raise ApiError(404, "Todo not found")
    return JSONResponse(status_code=200, content=updated)


@app.delete("/todos/{todo_id}")
async def delete_todo(todo_id: int, request: Request) -> Response:
    user, _ = require_auth(request)
    ok = state.delete_todo_for_user(user["id"], todo_id)
    if not ok:
        raise ApiError(404, "Todo not found")
    # 204 No Content, no body
    return Response(status_code=204)


# Ensure all non-JSON routes still return JSON content-type; FastAPI already sets for JSONResponse.
# The root path can be a simple health check.
@app.get("/")
async def root() -> JSONResponse:
    return JSONResponse(status_code=200, content={"status": "ok"})


# CLI entry

def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, required=True, help="Port to listen on")
    args = parser.parse_args()

    # Lazy import uvicorn here to keep mypy happy without optional dependencies at type-check time
    import uvicorn

    uvicorn.run("server:app", host="0.0.0.0", port=args.port, reload=False, access_log=True, log_level="info")


if __name__ == "__main__":
    main()
