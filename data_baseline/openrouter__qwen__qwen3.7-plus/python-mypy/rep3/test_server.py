import subprocess
import time
import json
import sys
from typing import Tuple, Optional, Any, Dict, Union
import urllib.request
import urllib.error

def run_test() -> None:
    port: int = 8765
    # Start server
    proc: subprocess.Popen[bytes] = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", str(port)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    time.sleep(2) # Wait for server to start

    def make_request(method: str, path: str, data: Optional[Dict[str, Any]] = None, cookies: str = "") -> Tuple[int, Optional[Dict[str, Any]]]:
        url: str = f"http://localhost:{port}{path}"
        headers: Dict[str, str] = {"Content-Type": "application/json"}
        if cookies:
            headers["Cookie"] = cookies
        
        req = urllib.request.Request(url, method=method, headers=headers)
        if data is not None:
            req.data = json.dumps(data).encode('utf-8')
        
        try:
            with urllib.request.urlopen(req) as response:
                body: str = response.read().decode('utf-8')
                return response.status, json.loads(body) if body else None
        except urllib.error.HTTPError as e:
            body = e.read().decode('utf-8')
            return e.code, json.loads(body) if body else None

    try:
        # Test 1: Register
        status, body = make_request("POST", "/register", {"username": "testuser", "password": "password123"})
        assert status == 201, f"Register failed: {status} {body}"
        assert isinstance(body, dict)
        assert body["id"] == 1
        assert body["username"] == "testuser"

        # Test 2: Register invalid username
        status, body = make_request("POST", "/register", {"username": "ab", "password": "password123"})
        assert status == 400, f"Invalid username failed: {status} {body}"
        assert body == {"error": "Invalid username"}

        # Test 3: Register short password
        status, body = make_request("POST", "/register", {"username": "testuser2", "password": "short"})
        assert status == 400, f"Short password failed: {status} {body}"
        assert body == {"error": "Password too short"}

        # Test 4: Register duplicate
        status, body = make_request("POST", "/register", {"username": "testuser", "password": "password123"})
        assert status == 409, f"Duplicate failed: {status} {body}"
        assert body == {"error": "Username already exists"}

        # Test 5: Login
        req = urllib.request.Request(f"http://localhost:{port}/login", method="POST", data=json.dumps({"username": "testuser", "password": "password123"}).encode('utf-8'), headers={"Content-Type": "application/json"})
        try:
            resp = urllib.request.urlopen(req)
            status = resp.status
            body = json.loads(resp.read().decode('utf-8'))
            cookie_header: Optional[str] = resp.getheader('Set-Cookie')
            assert status == 200, f"Login failed: {status}"
            assert isinstance(body, dict)
            assert body["username"] == "testuser"
            assert cookie_header and "session_id=" in cookie_header and "HttpOnly" in cookie_header, f"Cookie header missing or invalid: {cookie_header}"
            session_cookie: str = cookie_header.split(';')[0] # e.g., "session_id=abc"
        except urllib.error.HTTPError as e:
            assert False, f"Login failed: {e.code} {e.read().decode('utf-8')}"

        # Test 6: Login invalid
        status, body = make_request("POST", "/login", {"username": "testuser", "password": "wrong"})
        assert status == 401
        assert body == {"error": "Invalid credentials"}

        # Test 7: Get /me
        status, body = make_request("GET", "/me", cookies=session_cookie)
        assert status == 200
        assert isinstance(body, dict)
        assert body["username"] == "testuser"

        # Test 8: Get /me without auth
        status, body = make_request("GET", "/me")
        assert status == 401
        assert body == {"error": "Authentication required"}

        # Test 9: Update password
        status, body = make_request("PUT", "/password", {"old_password": "password123", "new_password": "newpassword123"}, cookies=session_cookie)
        assert status == 200
        assert body == {}

        # Test 10: Update password wrong old
        status, body = make_request("PUT", "/password", {"old_password": "wrong", "new_password": "newpassword123"}, cookies=session_cookie)
        assert status == 401
        assert body == {"error": "Invalid credentials"}

        # Test 11: Update password short new
        status, body = make_request("PUT", "/password", {"old_password": "newpassword123", "new_password": "short"}, cookies=session_cookie)
        assert status == 400
        assert body == {"error": "Password too short"}

        # Test 12: Create todo
        status, body = make_request("POST", "/todos", {"title": "My Todo", "description": "Do this"}, cookies=session_cookie)
        assert status == 201
        assert isinstance(body, dict)
        assert body["title"] == "My Todo"
        assert body["description"] == "Do this"
        assert body["completed"] is False
        todo_id: int = body["id"]

        # Test 13: Create todo missing title
        status, body = make_request("POST", "/todos", {"description": "Do this"}, cookies=session_cookie)
        assert status == 400
        assert body == {"error": "Title is required"}

        # Test 14: Create todo empty title
        status, body = make_request("POST", "/todos", {"title": "", "description": "Do this"}, cookies=session_cookie)
        assert status == 400
        assert body == {"error": "Title is required"}

        # Test 15: Get todos
        status, body = make_request("GET", "/todos", cookies=session_cookie)
        assert status == 200
        assert isinstance(body, list)
        assert len(body) == 1
        assert body[0]["title"] == "My Todo"

        # Test 16: Get specific todo
        status, body = make_request("GET", f"/todos/{todo_id}", cookies=session_cookie)
        assert status == 200
        assert isinstance(body, dict)
        assert body["title"] == "My Todo"

        # Test 17: Get specific todo not found
        status, body = make_request("GET", "/todos/999", cookies=session_cookie)
        assert status == 404
        assert body == {"error": "Todo not found"}

        # Test 18: Update todo
        status, body = make_request("PUT", f"/todos/{todo_id}", {"completed": True}, cookies=session_cookie)
        assert status == 200
        assert isinstance(body, dict)
        assert body["completed"] is True
        assert "updated_at" in body

        # Test 19: Update todo empty title
        status, body = make_request("PUT", f"/todos/{todo_id}", {"title": ""}, cookies=session_cookie)
        assert status == 400
        assert body == {"error": "Title is required"}

        # Test 20: Delete todo
        req = urllib.request.Request(f"http://localhost:{port}/todos/{todo_id}", method="DELETE", headers={"Cookie": session_cookie})
        try:
            resp = urllib.request.urlopen(req)
            assert resp.status == 204
        except urllib.error.HTTPError as e:
            assert False, f"Delete failed: {e.code}"

        # Test 21: Delete todo not found
        req = urllib.request.Request(f"http://localhost:{port}/todos/{todo_id}", method="DELETE", headers={"Cookie": session_cookie})
        try:
            resp = urllib.request.urlopen(req)
            assert False, "Should have failed"
        except urllib.error.HTTPError as e:
            assert e.code == 404
            body = json.loads(e.read().decode('utf-8'))
            assert body == {"error": "Todo not found"}

        # Test 22: Logout
        status, body = make_request("POST", "/logout", cookies=session_cookie)
        assert status == 200
        assert body == {}

        # Test 23: Get /me after logout
        status, body = make_request("GET", "/me", cookies=session_cookie)
        assert status == 401
        assert body == {"error": "Authentication required"}

        # Test 24: Register second user
        status, body = make_request("POST", "/register", {"username": "user2", "password": "password123"})
        assert status == 201
        
        # Test 25: Login second user
        req = urllib.request.Request(f"http://localhost:{port}/login", method="POST", data=json.dumps({"username": "user2", "password": "password123"}).encode('utf-8'), headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req)
        cookie_header = resp.getheader('Set-Cookie')
        assert cookie_header is not None
        session_cookie_2: str = cookie_header.split(';')[0]

        # Login testuser again
        req = urllib.request.Request(f"http://localhost:{port}/login", method="POST", data=json.dumps({"username": "testuser", "password": "newpassword123"}).encode('utf-8'), headers={"Content-Type": "application/json"})
        resp = urllib.request.urlopen(req)
        cookie_header = resp.getheader('Set-Cookie')
        assert cookie_header is not None
        session_cookie_1: str = cookie_header.split(';')[0]
        
        # Create todo for user 1
        status, body = make_request("POST", "/todos", {"title": "User 1 Todo"}, cookies=session_cookie_1)
        assert status == 201
        assert isinstance(body, dict)
        new_todo_id: int = body["id"]
        
        # Test 27: Second user tries to get first user's todo
        status, body = make_request("GET", f"/todos/{new_todo_id}", cookies=session_cookie_2)
        assert status == 404
        assert body == {"error": "Todo not found"}

        # Test 28: Second user tries to update first user's todo
        status, body = make_request("PUT", f"/todos/{new_todo_id}", {"title": "Hacked"}, cookies=session_cookie_2)
        assert status == 404
        assert body == {"error": "Todo not found"}

        # Test 29: Second user tries to delete first user's todo
        req = urllib.request.Request(f"http://localhost:{port}/todos/{new_todo_id}", method="DELETE", headers={"Cookie": session_cookie_2})
        try:
            resp = urllib.request.urlopen(req)
            assert False, "Should have failed"
        except urllib.error.HTTPError as e:
            assert e.code == 404
            body = json.loads(e.read().decode('utf-8'))
            assert body == {"error": "Todo not found"}

        print("All tests passed!")
    finally:
        proc.terminate()
        proc.wait()

if __name__ == "__main__":
    run_test()
