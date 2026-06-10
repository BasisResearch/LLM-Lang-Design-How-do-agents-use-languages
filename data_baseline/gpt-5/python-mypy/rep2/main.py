from __future__ import annotations

import re
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, List, Mapping, MutableMapping, Optional, Tuple

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse


def now_iso() -> str:
    # ISO 8601 UTC with second precision, trailing Z
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


USERNAME_RE = re.compile(r"^[a-zA-Z0-9_]{3,50}$")


@dataclass
class User:
    id: int
    username: str
    password: str


@dataclass
class Todo:
    id: int
    user_id: int
    title: str
    description: str
    completed: bool
    created_at: str
    updated_at: str


class InMemoryStore:
    def __init__(self) -> None:
        self._lock: threading.Lock = threading.Lock()
        self._user_id_counter: int = 1
        self._todo_id_counter: int = 1
        self._users_by_id: Dict[int, User] = {}
        self._usernames: Dict[str, int] = {}
        self._sessions: Dict[str, int] = {}
        self._todos_by_id: Dict[int, Todo] = {}

    # User operations
    def is_username_taken(self, username: str) -> bool:
        with self._lock:
            return username in self._usernames

    def create_user(self, username: str, password: str) -> User:
        with self._lock:
            if username in self._usernames:
                raise ValueError("Username exists")
            uid = self._user_id_counter
            self._user_id_counter += 1
            user = User(id=uid, username=username, password=password)
            self._users_by_id[uid] = user
            self._usernames[username] = uid
            return user

    def get_user_by_username(self, username: str) -> Optional[User]:
        with self._lock:
            uid = self._usernames.get(username)
            if uid is None:
                return None
            return self._users_by_id.get(uid)

    def get_user_by_id(self, user_id: int) -> Optional[User]:
        with self._lock:
            return self._users_by_id.get(user_id)

    def set_user_password(self, user_id: int, new_password: str) -> None:
        with self._lock:
            user = self._users_by_id.get(user_id)
            if user is None:
                raise KeyError("User not found")
            user.password = new_password

    # Session operations
    def create_session(self, user_id: int) -> str:
        token = uuid.uuid4().hex
        with self._lock:
            self._sessions[token] = user_id
        return token

    def get_session_user(self, token: str) -> Optional[User]:
        with self._lock:
            uid = self._sessions.get(token)
            if uid is None:
                return None
            return self._users_by_id.get(uid)

    def invalidate_session(self, token: str) -> None:
        with self._lock:
            if token in self._sessions:
                del self._sessions[token]

    # Todo operations
    def create_todo(self, user_id: int, title: str, description: str) -> Todo:
        with self._lock:
            tid = self._todo_id_counter
            self._todo_id_counter += 1
            ts = now_iso()
            todo = Todo(
                id=tid,
                user_id=user_id,
                title=title,
                description=description,
                completed=False,
                created_at=ts,
                updated_at=ts,
            )
            self._todos_by_id[tid] = todo
            return todo

    def list_todos_for_user(self, user_id: int) -> List[Todo]:
        with self._lock:
            return sorted(
                [t for t in self._todos_by_id.values() if t.user_id == user_id],
                key=lambda t: t.id,
            )

    def get_todo_if_owner(self, todo_id: int, user_id: int) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return None
            return todo

    def update_todo(self, todo_id: int, user_id: int, *, title: Optional[str], description: Optional[str], completed: Optional[bool]) -> Optional[Todo]:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return None
            if title is not None:
                todo.title = title
            if description is not None:
                todo.description = description
            if completed is not None:
                todo.completed = completed
            todo.updated_at = now_iso()
            return todo

    def delete_todo(self, todo_id: int, user_id: int) -> bool:
        with self._lock:
            todo = self._todos_by_id.get(todo_id)
            if todo is None or todo.user_id != user_id:
                return False
            del self._todos_by_id[todo_id]
            return True


store = InMemoryStore()
app = FastAPI()


def json_error(status_code: int, message: str) -> JSONResponse:
    return JSONResponse(status_code=status_code, content={"error": message})


def user_public(user: User) -> Dict[str, Any]:
    return {"id": user.id, "username": user.username}


def todo_public(todo: Todo) -> Dict[str, Any]:
    return {
        "id": todo.id,
        "title": todo.title,
        "description": todo.description,
        "completed": todo.completed,
        "created_at": todo.created_at,
        "updated_at": todo.updated_at,
    }


def get_session_token_from_cookies(cookies: Mapping[str, str]) -> Optional[str]:
    token = cookies.get("session_id")
    if token is None or token == "":
        return None
    return token


def get_authenticated_user(request: Request) -> Tuple[Optional[User], Optional[str]]:
    token = get_session_token_from_cookies(request.cookies)
    if token is None:
        return (None, None)
    user = store.get_session_user(token)
    if user is None:
        return (None, None)
    return (user, token)


@app.post("/register")
async def register(request: Request) -> Response:
    try:
        body_raw: Any = await request.json()
    except Exception:
        return json_error(400, "Invalid JSON")
    if not isinstance(body_raw, dict):
        return json_error(400, "Invalid JSON")

    username_any = body_raw.get("username")
    password_any = body_raw.get("password")

    if not isinstance(username_any, str) or not USERNAME_RE.fullmatch(username_any):
        return json_error(400, "Invalid username")
    username = username_any

    if not isinstance(password_any, str):
        return json_error(400, "Password too short")
    password = password_any
    if len(password) < 8:
        return json_error(400, "Password too short")

    if store.is_username_taken(username):
        return json_error(409, "Username already exists")

    try:
        user = store.create_user(username, password)
    except ValueError:
        return json_error(409, "Username already exists")

    return JSONResponse(status_code=201, content=user_public(user))


@app.post("/login")
async def login(request: Request) -> Response:
    try:
        body_raw: Any = await request.json()
    except Exception:
        return json_error(400, "Invalid JSON")
    if not isinstance(body_raw, dict):
        return json_error(400, "Invalid JSON")

    username_any = body_raw.get("username")
    password_any = body_raw.get("password")
    if not isinstance(username_any, str) or not isinstance(password_any, str):
        return json_error(401, "Invalid credentials")

    user = store.get_user_by_username(username_any)
    if user is None or user.password != password_any:
        return json_error(401, "Invalid credentials")

    token = store.create_session(user.id)

    resp = JSONResponse(status_code=200, content=user_public(user))
    # Set-Cookie: session_id=<token>; Path=/; HttpOnly
    resp.set_cookie(key="session_id", value=token, httponly=True, path="/")
    return resp


@app.post("/logout")
async def logout(request: Request) -> Response:
    user, token = get_authenticated_user(request)
    if user is None or token is None:
        return json_error(401, "Authentication required")

    store.invalidate_session(token)
    # Return empty JSON object
    return JSONResponse(status_code=200, content={})


@app.get("/me")
async def me(request: Request) -> Response:
    user, _ = get_authenticated_user(request)
    if user is None:
        return json_error(401, "Authentication required")
    return JSONResponse(status_code=200, content=user_public(user))


@app.put("/password")
async def change_password(request: Request) -> Response:
    user, _ = get_authenticated_user(request)
    if user is None:
        return json_error(401, "Authentication required")

    try:
        body_raw: Any = await request.json()
    except Exception:
        return json_error(400, "Invalid JSON")

    if not isinstance(body_raw, dict):
        return json_error(400, "Invalid JSON")

    old_pw_any = body_raw.get("old_password")
    new_pw_any = body_raw.get("new_password")
    if not isinstance(old_pw_any, str) or user.password != old_pw_any:
        return json_error(401, "Invalid credentials")
    if not isinstance(new_pw_any, str) or len(new_pw_any) < 8:
        return json_error(400, "Password too short")

    store.set_user_password(user.id, new_pw_any)
    return JSONResponse(status_code=200, content={})


@app.get("/todos")
async def list_todos(request: Request) -> Response:
    user, _ = get_authenticated_user(request)
    if user is None:
        return json_error(401, "Authentication required")
    todos = store.list_todos_for_user(user.id)
    return JSONResponse(status_code=200, content=[todo_public(t) for t in todos])


@app.post("/todos")
async def create_todo(request: Request) -> Response:
    user, _ = get_authenticated_user(request)
    if user is None:
        return json_error(401, "Authentication required")

    try:
        body_raw: Any = await request.json()
    except Exception:
        return json_error(400, "Invalid JSON")

    if not isinstance(body_raw, dict):
        return json_error(400, "Invalid JSON")

    title_any = body_raw.get("title")
    description_any = body_raw.get("description", "")

    if not isinstance(title_any, str) or title_any.strip() == "":
        return json_error(400, "Title is required")
    title = title_any

    description: str
    if description_any is None:
        description = ""
    elif isinstance(description_any, str):
        description = description_any
    else:
        # Coerce to string representation for safety
        description = str(description_any)

    todo = store.create_todo(user.id, title, description)
    return JSONResponse(status_code=201, content=todo_public(todo))


@app.get("/todos/{todo_id}")
async def get_todo(request: Request, todo_id: int) -> Response:
    user, _ = get_authenticated_user(request)
    if user is None:
        return json_error(401, "Authentication required")

    todo = store.get_todo_if_owner(todo_id, user.id)
    if todo is None:
        return json_error(404, "Todo not found")
    return JSONResponse(status_code=200, content=todo_public(todo))


@app.put("/todos/{todo_id}")
async def update_todo(request: Request, todo_id: int) -> Response:
    user, _ = get_authenticated_user(request)
    if user is None:
        return json_error(401, "Authentication required")

    try:
        body_raw: Any = await request.json()
    except Exception:
        return json_error(400, "Invalid JSON")

    if not isinstance(body_raw, dict):
        return json_error(400, "Invalid JSON")

    title: Optional[str] = None
    description: Optional[str] = None
    completed: Optional[bool] = None

    if "title" in body_raw:
        t_any = body_raw.get("title")
        if not isinstance(t_any, str) or t_any.strip() == "":
            return json_error(400, "Title is required")
        title = t_any

    if "description" in body_raw:
        d_any = body_raw.get("description")
        if d_any is None:
            description = ""
        elif isinstance(d_any, str):
            description = d_any
        else:
            description = str(d_any)

    if "completed" in body_raw:
        c_any = body_raw.get("completed")
        if isinstance(c_any, bool):
            completed = c_any
        else:
            return json_error(400, "Invalid JSON")

    todo = store.update_todo(todo_id, user.id, title=title, description=description, completed=completed)
    if todo is None:
        return json_error(404, "Todo not found")

    return JSONResponse(status_code=200, content=todo_public(todo))


@app.delete("/todos/{todo_id}")
async def delete_todo(request: Request, todo_id: int) -> Response:
    user, _ = get_authenticated_user(request)
    if user is None:
        # For DELETE, error should still be JSON; but spec says all responses except DELETE no body.
        # However for error we must return JSON. So we return 401 with JSON.
        return json_error(401, "Authentication required")

    ok = store.delete_todo(todo_id, user.id)
    if not ok:
        return json_error(404, "Todo not found")

    # 204 No Content, no body
    return Response(status_code=204)
