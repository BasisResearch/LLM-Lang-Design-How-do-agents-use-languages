import argparse
import json
import re
import secrets
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import uvicorn
from fastapi import FastAPI, Request, Response, status

app = FastAPI()


class User:
    def __init__(self, user_id: int, username: str, password: str) -> None:
        self.id: int = user_id
        self.username: str = username
        self.password: str = password


class Todo:
    def __init__(self, todo_id: int, user_id: int, title: str, description: str) -> None:
        self.id: int = todo_id
        self.user_id: int = user_id
        self.title: str = title
        self.description: str = description
        self.completed: bool = False
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.created_at: str = now
        self.updated_at: str = now

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
            "completed": self.completed,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
        }


# In-memory storage
users: Dict[int, User] = {}
usernames: Dict[str, int] = {}  # username -> user_id
todos: Dict[int, Todo] = {}
sessions: Dict[str, int] = {}  # session_token -> user_id

next_user_id: int = 1
next_todo_id: int = 1


async def get_current_user(request: Request) -> Optional[User]:
    session_id = request.cookies.get("session_id")
    if not session_id:
        return None
    user_id = sessions.get(session_id)
    if user_id is None:
        return None
    return users.get(user_id)


@app.post("/register", status_code=status.HTTP_201_CREATED)
async def register(request: Request) -> Response:
    try:
        body = await request.json()
    except Exception:
        body = {}

    if not isinstance(body, dict):
        body = {}

    username = body.get("username")
    password = body.get("password")

    if not isinstance(username, str):
        return Response(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=json.dumps({"error": "Invalid username"}),
            media_type="application/json",
        )

    if not (3 <= len(username) <= 50) or not re.match(r"^[a-zA-Z0-9_]+$", username):
        return Response(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=json.dumps({"error": "Invalid username"}),
            media_type="application/json",
        )

    if not isinstance(password, str):
        return Response(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=json.dumps({"error": "Password too short"}),
            media_type="application/json",
        )

    if len(password) < 8:
        return Response(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=json.dumps({"error": "Password too short"}),
            media_type="application/json",
        )

    if username in usernames:
        return Response(
            status_code=status.HTTP_409_CONFLICT,
            content=json.dumps({"error": "Username already exists"}),
            media_type="application/json",
        )

    global next_user_id
    user = User(next_user_id, username, password)
    users[next_user_id] = user
    usernames[username] = next_user_id
    next_user_id += 1

    return Response(
        status_code=status.HTTP_201_CREATED,
        content=json.dumps({"id": user.id, "username": user.username}),
        media_type="application/json",
    )


@app.post("/login")
async def login(request: Request) -> Response:
    try:
        body = await request.json()
    except Exception:
        body = {}

    if not isinstance(body, dict):
        body = {}

    username = body.get("username")
    password = body.get("password")

    if not isinstance(username, str) or not isinstance(password, str):
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Invalid credentials"}),
            media_type="application/json",
        )

    user_id = usernames.get(username)
    if user_id is None:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Invalid credentials"}),
            media_type="application/json",
        )

    user = users[user_id]
    if user.password != password:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Invalid credentials"}),
            media_type="application/json",
        )

    token = secrets.token_hex(32)
    sessions[token] = user.id

    resp = Response(
        status_code=status.HTTP_200_OK,
        content=json.dumps({"id": user.id, "username": user.username}),
        media_type="application/json",
    )
    resp.set_cookie(key="session_id", value=token, httponly=True, path="/")
    return resp


@app.post("/logout")
async def logout(request: Request) -> Response:
    user = await get_current_user(request)
    if user is None:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Authentication required"}),
            media_type="application/json",
        )

    session_id = request.cookies.get("session_id")
    if session_id and session_id in sessions:
        del sessions[session_id]

    return Response(
        status_code=status.HTTP_200_OK,
        content=json.dumps({}),
        media_type="application/json",
    )


@app.get("/me")
async def me(request: Request) -> Response:
    user = await get_current_user(request)
    if user is None:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Authentication required"}),
            media_type="application/json",
        )

    return Response(
        status_code=status.HTTP_200_OK,
        content=json.dumps({"id": user.id, "username": user.username}),
        media_type="application/json",
    )


@app.put("/password")
async def change_password(request: Request) -> Response:
    user = await get_current_user(request)
    if user is None:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Authentication required"}),
            media_type="application/json",
        )

    try:
        body = await request.json()
    except Exception:
        body = {}

    if not isinstance(body, dict):
        body = {}

    old_password = body.get("old_password")
    new_password = body.get("new_password")

    if not isinstance(old_password, str) or not isinstance(new_password, str):
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Invalid credentials"}),
            media_type="application/json",
        )

    if user.password != old_password:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Invalid credentials"}),
            media_type="application/json",
        )

    if len(new_password) < 8:
        return Response(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=json.dumps({"error": "Password too short"}),
            media_type="application/json",
        )

    user.password = new_password
    return Response(
        status_code=status.HTTP_200_OK,
        content=json.dumps({}),
        media_type="application/json",
    )


@app.get("/todos")
async def get_todos(request: Request) -> Response:
    user = await get_current_user(request)
    if user is None:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Authentication required"}),
            media_type="application/json",
        )

    user_todos = [todo for todo in todos.values() if todo.user_id == user.id]
    user_todos.sort(key=lambda t: t.id)

    return Response(
        status_code=status.HTTP_200_OK,
        content=json.dumps([t.to_dict() for t in user_todos]),
        media_type="application/json",
    )


@app.post("/todos", status_code=status.HTTP_201_CREATED)
async def create_todo(request: Request) -> Response:
    user = await get_current_user(request)
    if user is None:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Authentication required"}),
            media_type="application/json",
        )

    try:
        body = await request.json()
    except Exception:
        body = {}

    if not isinstance(body, dict):
        body = {}

    title = body.get("title")

    if not isinstance(title, str) or title == "":
        return Response(
            status_code=status.HTTP_400_BAD_REQUEST,
            content=json.dumps({"error": "Title is required"}),
            media_type="application/json",
        )

    description = body.get("description", "")
    if not isinstance(description, str):
        description = ""

    global next_todo_id
    todo = Todo(next_todo_id, user.id, title, description)
    todos[next_todo_id] = todo
    next_todo_id += 1

    return Response(
        status_code=status.HTTP_201_CREATED,
        content=json.dumps(todo.to_dict()),
        media_type="application/json",
    )


@app.get("/todos/{todo_id}")
async def get_todo(request: Request, todo_id: int) -> Response:
    user = await get_current_user(request)
    if user is None:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Authentication required"}),
            media_type="application/json",
        )

    todo = todos.get(todo_id)
    if todo is None or todo.user_id != user.id:
        return Response(
            status_code=status.HTTP_404_NOT_FOUND,
            content=json.dumps({"error": "Todo not found"}),
            media_type="application/json",
        )

    return Response(
        status_code=status.HTTP_200_OK,
        content=json.dumps(todo.to_dict()),
        media_type="application/json",
    )


@app.put("/todos/{todo_id}")
async def update_todo(request: Request, todo_id: int) -> Response:
    user = await get_current_user(request)
    if user is None:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Authentication required"}),
            media_type="application/json",
        )

    todo = todos.get(todo_id)
    if todo is None or todo.user_id != user.id:
        return Response(
            status_code=status.HTTP_404_NOT_FOUND,
            content=json.dumps({"error": "Todo not found"}),
            media_type="application/json",
        )

    try:
        body = await request.json()
    except Exception:
        body = {}

    if not isinstance(body, dict):
        body = {}

    if "title" in body:
        title = body["title"]
        if not isinstance(title, str) or title == "":
            return Response(
                status_code=status.HTTP_400_BAD_REQUEST,
                content=json.dumps({"error": "Title is required"}),
                media_type="application/json",
            )
        todo.title = title

    if "description" in body:
        desc = body["description"]
        if isinstance(desc, str):
            todo.description = desc

    if "completed" in body:
        comp = body["completed"]
        if isinstance(comp, bool):
            todo.completed = comp

    todo.updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    return Response(
        status_code=status.HTTP_200_OK,
        content=json.dumps(todo.to_dict()),
        media_type="application/json",
    )


@app.delete("/todos/{todo_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_todo(request: Request, todo_id: int) -> Response:
    user = await get_current_user(request)
    if user is None:
        return Response(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content=json.dumps({"error": "Authentication required"}),
            media_type="application/json",
        )

    todo = todos.get(todo_id)
    if todo is None or todo.user_id != user.id:
        return Response(
            status_code=status.HTTP_404_NOT_FOUND,
            content=json.dumps({"error": "Todo not found"}),
            media_type="application/json",
        )

    del todos[todo_id]
    return Response(status_code=status.HTTP_204_NO_CONTENT)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument("--port", type=int, default=8000, help="Port to listen on")
    args = parser.parse_args()
    uvicorn.run(app, host="0.0.0.0", port=args.port)
