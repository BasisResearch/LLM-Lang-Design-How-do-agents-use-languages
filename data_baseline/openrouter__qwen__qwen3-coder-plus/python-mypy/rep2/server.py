#!/usr/bin/env python3
"""
Todo App REST API Server
Cookie-based authentication with session management
"""

import argparse
import hashlib
import json
import re
import secrets
from datetime import datetime
from http.cookies import SimpleCookie
from typing import Any, Dict, List, Optional, Tuple, Union, Callable, cast
from urllib.parse import parse_qs
from wsgiref.simple_server import make_server, WSGIServer
from socketserver import ThreadingMixIn


class ThreadedHTTPServer(ThreadingMixIn, WSGIServer):
    """Handle multiple requests simultaneously."""
    daemon_threads = True


# Global store for data - in production use real database
users_db: List[Dict[str, Any]] = []
todos_db: List[Dict[str, Any]] = []
sessions_db: Dict[str, int] = {}  # session_id -> user_id
next_user_id = 1
next_todo_id = 1


class Request:
    def __init__(self, environ: Dict[str, Any]) -> None:
        self.environ = environ
        self.method = environ['REQUEST_METHOD']
        self.path = environ['PATH_INFO']
        self.content_type = environ.get('CONTENT_TYPE', '')
        
        # Handle cases where CONTENT_LENGTH might be empty string
        content_length_raw = environ.get('CONTENT_LENGTH', '0')
        try:
            self.content_length = int(content_length_raw) if content_length_raw else 0
        except ValueError:
            self.content_length = 0  # Default to 0 if conversion fails
        
        # Parse cookies
        self.cookies: Dict[str, str] = {}
        if 'HTTP_COOKIE' in environ:
            try:
                cookie_header = environ['HTTP_COOKIE']
                cookie = SimpleCookie()
                cookie.load(cookie_header)
                for key, morsel in cookie.items():
                    self.cookies[key] = morsel.value
            except Exception:
                pass  # Ignore malformed cookies
        
        # Parse query string
        self.query_params = parse_qs(environ.get('QUERY_STRING', ''))
    
    def get_body(self) -> bytes:
        input_stream = self.environ['wsgi.input']
        body: bytes = input_stream.read(self.content_length)
        return body
    
    def get_json(self) -> Optional[Dict[str, Any]]:
        body = self.get_body()
        if not body:
            return None
        try:
            parsed: Any = json.loads(body.decode('utf-8'))
            return parsed if isinstance(parsed, dict) else None
        except Exception:
            return None
    
    def get_user_id_from_session(self) -> Optional[int]:
        session_id = self.cookies.get('session_id')
        if session_id and session_id in sessions_db:
            return sessions_db[session_id]
        return None


class Response:
    def __init__(self, status: str = '200 OK', headers: Optional[List[Tuple[str, str]]] = None) -> None:
        self.status = status
        self.headers: List[Tuple[str, str]] = headers or []
        
        # Ensure default JSON content type
        if not any(h[0].lower() == 'content-type' for h in self.headers):
            self.headers.append(('Content-Type', 'application/json'))
    
    def json(self, data: Dict[str, Any]) -> bytes:
        return json.dumps(data).encode('utf-8')


def validate_username(username: str) -> bool:
    """Validate username: 3-50 chars, alphanumeric + underscore only"""
    return 3 <= len(username) <= 50 and bool(re.match(r'^[a-zA-Z0-9_]+$', username))


def create_session(user_id: int) -> str:
    """Create a new session token for a user"""
    session_id = secrets.token_hex(32)  # 64 chars of randomness
    sessions_db[session_id] = user_id
    return session_id


def hash_password(password: str) -> str:
    """Hash password using SHA-256"""
    return hashlib.sha256(password.encode('utf-8')).hexdigest()


def create_error_response(error_msg: str, status_code: int = 400) -> Tuple[bytes, str, List[Tuple[str, str]]]:
    """Create error response"""
    error_data = {"error": error_msg}
    response_body = json.dumps(error_data).encode('utf-8')
    status_str = {
        400: '400 Bad Request',
        401: '401 Unauthorized',
        404: '404 Not Found',
        409: '409 Conflict'
    }.get(status_code, f'{status_code} Error')
    headers = [('Content-Type', 'application/json')]
    return response_body, status_str, headers


def create_success_response_with_cookie(
    data: Dict[str, Any], 
    session_id: str,
    status: str = '200 OK'
) -> Tuple[bytes, str, List[Tuple[str, str]]]:
    """Create success response with session cookie"""
    response_body = json.dumps(data).encode('utf-8')
    headers = [
        ('Content-Type', 'application/json'),
        ('Set-Cookie', f'session_id={session_id}; Path=/; HttpOnly')
    ]
    return response_body, status, headers


def create_success_response_no_content(status: str = '204 No Content') -> Tuple[bytes, str, List[Tuple[str, str]]]:
    """Create success response with no content"""
    return b'', status, []


def create_list_success_response(todo_list: List[Dict[str, Any]], status: str = '200 OK') -> Tuple[bytes, str, List[Tuple[str, str]]]:
    """Create success response with list content"""
    response_body = json.dumps(todo_list).encode('utf-8')
    return response_body, status, [('Content-Type', 'application/json')]


def create_default_success_response(data: Dict[str, Any], status: str = '200 OK') -> Tuple[bytes, str, List[Tuple[str, str]]]:
    """Create default success response"""
    response_body = json.dumps(data).encode('utf-8')
    return response_body, status, [('Content-Type', 'application/json')]


def create_todo_object(title: str, description: str, user_id: int) -> Dict[str, Any]:
    """Create a todo object with current timestamps"""
    global next_todo_id
    # Using timezone-aware objects to address the deprecation warning
    now = datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')
    todo = {
        "id": next_todo_id,
        "title": title,
        "description": description,
        "completed": False,
        "created_at": now,
        "updated_at": now,
        "user_id": user_id
    }
    next_todo_id += 1
    return todo


def server_app(environ: Dict[str, Any], start_response: Callable[..., Any]) -> List[bytes]:
    """Main WSGI application"""
    request = Request(environ)
    
    # Extract path and check if this is a TODO ID endpoint
    path_parts = request.path.strip('/').split('/')
    resource = path_parts[0]
    
    # Handle routes
    if request.method == 'POST' and resource == 'register':
        return handle_register(request, start_response)
    
    elif request.method == 'POST' and resource == 'login':
        return handle_login(request, start_response)
    
    elif request.method == 'POST' and resource == 'logout':
        return handle_logout(request, start_response)
    
    elif request.method == 'GET' and resource == 'me':
        return handle_get_me(request, start_response)
    
    elif request.method == 'PUT' and resource == 'password':
        return handle_password_change(request, start_response)
    
    elif request.method == 'GET' and resource == 'todos':
        if len(path_parts) > 2 and path_parts[1] == 'todos':  # GET /todos/:id
            todo_id_str = path_parts[2]
            return handle_get_todo(request, start_response, todo_id_str)
        else:  # GET /todos
            return handle_get_todos(request, start_response)
    
    elif request.method == 'POST' and resource == 'todos':
        return handle_create_todo(request, start_response)
    
    elif request.method == 'PUT' and len(path_parts) >= 2 and path_parts[0] == 'todos':
        todo_id_str = path_parts[1]
        return handle_update_todo(request, start_response, todo_id_str)
    
    elif request.method == 'DELETE' and len(path_parts) >= 2 and path_parts[0] == 'todos':
        todo_id_str = path_parts[1]
        return handle_delete_todo(request, start_response, todo_id_str)
    
    else:
        response_body, status, headers = create_error_response("Not found", 404)
        start_response(status, headers)
        return [response_body]


def handle_register(request: Request, start_response: Callable[..., Any]) -> List[bytes]:
    """Handle POST /register"""
    data = request.get_json()
    if not data:
        response_body, status, headers = create_error_response("Missing request body", 400)
        start_response(status, headers)
        return [response_body]
    
    username = data.get('username')
    password = data.get('password')
    
    if not username or not isinstance(username, str) or not validate_username(username):
        response_body, status, headers = create_error_response("Invalid username", 400)
        start_response(status, headers)
        return [response_body]
    
    if not password or len(password) < 8:
        response_body, status, headers = create_error_response("Password too short", 400)
        start_response(status, headers)
        return [response_body]
    
    if not isinstance(password, str):
        response_body, status, headers = create_error_response("Password too short", 400)
        start_response(status, headers)
        return [response_body]
    
    # Check if username already exists
    for user in users_db:
        if user['username'] == username:
            response_body, status, headers = create_error_response("Username already exists", 409)
            start_response(status, headers)
            return [response_body]
    
    # Create user
    global next_user_id
    user = {
        "id": next_user_id,
        "username": username,
        "password_hash": hash_password(password)
    }
    users_db.append(user)
    
    user_return = {"id": next_user_id, "username": username}
    next_user_id += 1
    
    response_body, status, headers = create_default_success_response(user_return, "201 Created")
    start_response(status, headers)
    return [response_body]


def handle_login(request: Request, start_response: Callable[..., Any]) -> List[bytes]:
    """Handle POST /login"""
    data = request.get_json()
    if not data:
        response_body, status, headers = create_error_response("Missing request body", 400)
        start_response(status, headers)
        return [response_body]
    
    username = data.get('username')
    password = data.get('password')
    
    if not username or not password:
        response_body, status, headers = create_error_response("Invalid credentials", 401)
        start_response(status, headers)
        return [response_body]
    
    if not isinstance(username, str) or not isinstance(password, str):
        response_body, status, headers = create_error_response("Invalid credentials", 401)
        start_response(status, headers)
        return [response_body]
    
    # Find user
    user = None
    for u in users_db:
        if u['username'] == username:
            user = u
            break
    
    if not user or user['password_hash'] != hash_password(password):
        response_body, status, headers = create_error_response("Invalid credentials", 401)
        start_response(status, headers)
        return [response_body]
    
    # Create session
    session_id = create_session(user['id'])
    
    user_info = {"id": user['id'], "username": user['username']}
    response_body, status, headers = create_success_response_with_cookie(
        user_info, session_id, "200 OK"
    )
    start_response(status, headers)
    return [response_body]


def handle_logout(request: Request, start_response: Callable[..., Any]) -> List[bytes]:
    """Handle POST /logout"""
    user_id = request.get_user_id_from_session()
    if not user_id:
        response_body, status, headers = create_error_response("Authentication required", 401)
        start_response(status, headers)
        return [response_body]
    
    # Remove session
    session_id = request.cookies.get('session_id')
    if session_id and session_id in sessions_db:
        del sessions_db[session_id]
    
    # Return empty success response
    response_body, status, headers = create_success_response_no_content()
    start_response(status, headers)
    return [response_body]


def handle_get_me(request: Request, start_response: Callable[..., Any]) -> List[bytes]:
    """Handle GET /me"""
    user_id = request.get_user_id_from_session()
    if not user_id:
        response_body, status, headers = create_error_response("Authentication required", 401)
        start_response(status, headers)
        return [response_body]
    
    # Find user
    for user in users_db:
        if user['id'] == user_id:
            user_info = {"id": user['id'], "username": user['username']}
            response_body, status, headers = create_default_success_response(user_info)
            start_response(status, headers)
            return [response_body]
    
    response_body, status, headers = create_error_response("Authentication required", 401)
    start_response(status, headers)
    return [response_body]


def handle_password_change(request: Request, start_response: Callable[..., Any]) -> List[bytes]:
    """Handle PUT /password"""
    user_id = request.get_user_id_from_session()
    if not user_id:
        response_body, status, headers = create_error_response("Authentication required", 401)
        start_response(status, headers)
        return [response_body]
    
    data = request.get_json()
    if not data:
        response_body, status, headers = create_error_response("Missing request body", 400)
        start_response(status, headers)
        return [response_body]
    
    old_password = data.get('old_password')
    new_password = data.get('new_password')
    
    if not old_password or not new_password:
        response_body, status, headers = create_error_response("Missing password fields", 400)
        start_response(status, headers)
        return [response_body]
    
    if len(new_password) < 8:
        response_body, status, headers = create_error_response("Password too short", 400)
        start_response(status, headers)
        return [response_body]
    
    if not isinstance(old_password, str) or not isinstance(new_password, str):
        response_body, status, headers = create_error_response("Missing password fields", 400)
        start_response(status, headers)
        return [response_body]
    
    # Verify old password
    user = None
    for u in users_db:
        if u['id'] == user_id:
            user = u
            break
    
    if not user or user['password_hash'] != hash_password(old_password):
        response_body, status, headers = create_error_response("Invalid credentials", 401)
        start_response(status, headers)
        return [response_body]
    
    # Update password hash
    user['password_hash'] = hash_password(new_password)
    
    response_body, status, headers = create_success_response_no_content()
    start_response(status, headers)
    return [response_body]


def handle_get_todos(request: Request, start_response: Callable[..., Any]) -> List[bytes]:
    """Handle GET /todos"""
    user_id = request.get_user_id_from_session()
    if not user_id:
        response_body, status, headers = create_error_response("Authentication required", 401)
        start_response(status, headers)
        return [response_body]
    
    # Get user's todos
    user_todos = [t for t in todos_db if t['user_id'] == user_id]
    
    # Sort by ID
    user_todos.sort(key=lambda t: t['id'])
    
    # Return todos
    response_body, status, headers = create_list_success_response(user_todos)
    start_response(status, headers)
    return [response_body]


def handle_create_todo(request: Request, start_response: Callable[..., Any]) -> List[bytes]:
    """Handle POST /todos"""
    user_id = request.get_user_id_from_session()
    if not user_id:
        response_body, status, headers = create_error_response("Authentication required", 401)
        start_response(status, headers)
        return [response_body]
    
    data = request.get_json()
    if not data:
        response_body, status, headers = create_error_response("Missing request body", 400)
        start_response(status, headers)
        return [response_body]
    
    title = data.get('title')
    description = data.get('description', "")
    
    if not title or not isinstance(title, str):
        response_body, status, headers = create_error_response("Title is required", 400)
        start_response(status, headers)
        return [response_body]
    
    if not isinstance(description, str):
        response_body, status, headers = create_error_response("Description must be a string", 400)
        start_response(status, headers)
        return [response_body]
    
    # Create todo
    todo = create_todo_object(title, description, user_id)
    todos_db.append(todo)
    
    # Return created todo
    response_body, status, headers = create_default_success_response(todo, "201 Created")
    start_response(status, headers)
    return [response_body]


def handle_get_todo(request: Request, start_response: Callable[..., Any], todo_id_str: str) -> List[bytes]:
    """Handle GET /todos/{id}"""
    user_id = request.get_user_id_from_session()
    if not user_id:
        response_body, status, headers = create_error_response("Authentication required", 401)
        start_response(status, headers)
        return [response_body]
    
    try:
        todo_id = int(todo_id_str)
    except ValueError:
        response_body, status, headers = create_error_response("Todo not found", 404)
        start_response(status, headers)
        return [response_body]
    
    # Find todo belonging to user
    for todo in todos_db:
        if todo['id'] == todo_id and todo['user_id'] == user_id:
            response_body, status, headers = create_default_success_response(todo)
            start_response(status, headers)
            return [response_body]
    
    response_body, status, headers = create_error_response("Todo not found", 404)
    start_response(status, headers)
    return [response_body]


def update_todo(updated_fields: Dict[str, Any], user_id: int) -> Tuple[Optional[Tuple[bytes, str, List[Tuple[str, str]]]], Optional[Dict[str, Any]]]:
    """Helper to update a todo with validation"""
    # Validate fields
    if 'title' in updated_fields:
        title = updated_fields['title']
        if not title or not isinstance(title, str):
            response_body, status, headers = create_error_response("Title is required", 400)
            return (response_body, status, headers), None
    
    # Update timestamps
    updated_fields['updated_at'] = datetime.now().strftime('%Y-%m-%dT%H:%M:%SZ')
    
    # Ensure id exists in updated_fields
    if 'id' not in updated_fields:
        response_body, status, headers = create_error_response("Todo not found", 404)
        return (response_body, status, headers), None
    
    # Update actual todo fields
    todo = None
    for t in todos_db:
        if t['id'] == updated_fields['id'] and t['user_id'] == user_id:
            todo = t
            break
    
    if not todo:
        response_body, status, headers = create_error_response("Todo not found", 404)
        return (response_body, status, headers), None
          
    # Apply updates
    for field, value in updated_fields.items():
        if field in ['title', 'description', 'completed', 'updated_at']:
            todo[field] = value
    
    return None, todo


def handle_update_todo(request: Request, start_response: Callable[..., Any], todo_id_str: str) -> List[bytes]:
    """Handle PUT /todos/{id}"""
    user_id = request.get_user_id_from_session()
    if not user_id:
        response_body, status, headers = create_error_response("Authentication required", 401)
        start_response(status, headers)
        return [response_body]
    
    try:
        todo_id = int(todo_id_str)
    except ValueError:
        response_body, status, headers = create_error_response("Todo not found", 404)
        start_response(status, headers)
        return [response_body]
    
    data = request.get_json()
    if not data:
        response_body, status, headers = create_error_response("Missing request body", 400)
        start_response(status, headers)
        return [response_body]
    
    # Check if the todo belongs to this user
    todo_exists = False
    for todo in todos_db:
        if todo['id'] == todo_id and todo['user_id'] == user_id:
            todo_exists = True
            break
    
    if not todo_exists:
        response_body, status, headers = create_error_response("Todo not found", 404)
        start_response(status, headers)
        return [response_body]
    
    # Prepare update
    updated_fields = {'id': todo_id}
    if 'title' in data:
        updated_fields['title'] = data['title']
    if 'description' in data:
        updated_fields['description'] = data['description']
    if 'completed' in data:
        updated_fields['completed'] = data['completed']
    
    # Perform update
    err_resp, updated_todo = update_todo(updated_fields, user_id)
    if err_resp is not None:
        # Unpack the error response properly
        error_body, error_status, error_headers = err_resp
        start_response(error_status, error_headers)
        return [error_body]
    
    if updated_todo is None:
        response_body, status, headers = create_error_response("Todo not found", 404)
        start_response(status, headers)
        return [response_body]
    
    # Success - return updated todo
    response_body, status, headers = create_default_success_response(updated_todo)
    start_response(status, headers)
    return [response_body]


def handle_delete_todo(request: Request, start_response: Callable[..., Any], todo_id_str: str) -> List[bytes]:
    """Handle DELETE /todos/{id}"""
    user_id = request.get_user_id_from_session()
    if not user_id:
        response_body, status, headers = create_error_response("Authentication required", 401)
        start_response(status, headers)
        return [response_body]
    
    try:
        todo_id = int(todo_id_str)
    except ValueError:
        response_body, status, headers = create_error_response("Todo not found", 404)
        start_response(status, headers)
        return [response_body]
    
    # Find the todo and check ownership
    index_to_remove = -1
    todo_found = False
    for i, todo in enumerate(todos_db):
        if todo['id'] == todo_id:
            if todo['user_id'] == user_id:
                index_to_remove = i
                todo_found = True
            else:
                # This is to prevent ID enumeration - always return 404 if not their todo
                response_body, status, headers = create_error_response("Todo not found", 404)
                start_response(status, headers)
                return [response_body]
            break
    
    if not todo_found or index_to_remove == -1:
        response_body, status, headers = create_error_response("Todo not found", 404)
        start_response(status, headers)
        return [response_body]
    
    # Remove the todo
    del todos_db[index_to_remove]
    
    # Success - 204 No Content
    empty_response_body, status, headers = create_success_response_no_content("204 No Content")
    start_response(status, headers)
    return [empty_response_body]


def main() -> None:
    parser = argparse.ArgumentParser(description="Todo App Server")
    parser.add_argument('--port', type=int, required=True, help='Port number to listen on')
    args = parser.parse_args()
    
    try:
        httpd = make_server('0.0.0.0', args.port, server_app, server_class=ThreadedHTTPServer)
        print(f"Server running on 0.0.0.0:{args.port}")
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down server...")
        httpd.shutdown()


if __name__ == "__main__":
    main()