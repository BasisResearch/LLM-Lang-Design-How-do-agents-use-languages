import subprocess
import time
import json
import urllib.request
import urllib.error
import sys

PORT = 8889
BASE_URL = f"http://localhost:{PORT}"

def start_server():
    proc = subprocess.Popen([sys.executable, "server.py", "--port", str(PORT)])
    time.sleep(2)
    return proc

def make_request(method, path, data=None, cookies=None):
    url = f"{BASE_URL}{path}"
    headers = {"Content-Type": "application/json"}
    if cookies:
        headers["Cookie"] = "; ".join([f"{k}={v}" for k, v in cookies.items()])
    
    req = urllib.request.Request(url, method=method, headers=headers)
    if data is not None:
        req.data = json.dumps(data).encode('utf-8')
    
    cookies_out = {}
    try:
        with urllib.request.urlopen(req) as response:
            body = response.read().decode('utf-8')
            set_cookie = response.headers.get('Set-Cookie')
            if set_cookie:
                parts = set_cookie.split(';')[0].split('=')
                if len(parts) == 2:
                    cookies_out[parts[0]] = parts[1]
            parsed_body = json.loads(body) if body.strip() else None
            return response.status, parsed_body, cookies_out
    except urllib.error.HTTPError as e:
        body = e.read().decode('utf-8')
        parsed_body = json.loads(body) if body.strip() else None
        return e.code, parsed_body, cookies_out

def test():
    proc = start_server()
    try:
        print("Testing POST /register")
        status, body, cookies = make_request("POST", "/register", {"username": "user1", "password": "password123"})
        assert status == 201, f"Expected 201, got {status}: {body}"
        assert body["id"] == 1
        assert body["username"] == "user1"

        status, body, _ = make_request("POST", "/register", {"username": "ab", "password": "password123"})
        assert status == 400 and body["error"] == "Invalid username", f"Expected 400, got {status}: {body}"

        status, body, _ = make_request("POST", "/register", {"username": "user2", "password": "short"})
        assert status == 400 and body["error"] == "Password too short", f"Expected 400, got {status}: {body}"

        status, body, _ = make_request("POST", "/register", {"username": "user1", "password": "password123"})
        assert status == 409 and body["error"] == "Username already exists", f"Expected 409, got {status}: {body}"

        print("Testing POST /login")
        status, body, _ = make_request("POST", "/login", {"username": "user1", "password": "wrongpass"})
        assert status == 401 and body["error"] == "Invalid credentials", f"Expected 401, got {status}: {body}"

        status, body, cookies = make_request("POST", "/login", {"username": "user1", "password": "password123"})
        assert status == 200 and "session_id" in cookies, f"Expected 200 with cookie, got {status}: {body}"
        session_cookie = cookies

        print("Testing GET /me")
        status, body, _ = make_request("GET", "/me", cookies=session_cookie)
        assert status == 200 and body["username"] == "user1", f"Expected 200, got {status}: {body}"

        print("Testing PUT /password")
        status, body, _ = make_request("PUT", "/password", {"old_password": "wrong", "new_password": "password456"}, cookies=session_cookie)
        assert status == 401 and body["error"] == "Invalid credentials", f"Expected 401, got {status}: {body}"

        status, body, _ = make_request("PUT", "/password", {"old_password": "password123", "new_password": "short"}, cookies=session_cookie)
        assert status == 400 and body["error"] == "Password too short", f"Expected 400, got {status}: {body}"

        status, body, _ = make_request("PUT", "/password", {"old_password": "password123", "new_password": "password456"}, cookies=session_cookie)
        assert status == 200, f"Expected 200, got {status}: {body}"

        status, body, cookies = make_request("POST", "/login", {"username": "user1", "password": "password456"})
        assert status == 200, f"Expected 200, got {status}: {body}"
        session_cookie = cookies

        print("Testing POST /logout")
        status, body, _ = make_request("POST", "/logout", cookies=session_cookie)
        assert status == 200, f"Expected 200, got {status}: {body}"

        status, body, _ = make_request("GET", "/me", cookies=session_cookie)
        assert status == 401 and body["error"] == "Authentication required", f"Expected 401, got {status}: {body}"

        print("Logging in again for todo tests")
        status, body, cookies = make_request("POST", "/login", {"username": "user1", "password": "password456"})
        session_cookie = cookies

        print("Testing POST /todos")
        status, body, _ = make_request("POST", "/todos", {"description": "no title"}, cookies=session_cookie)
        assert status == 400 and body["error"] == "Title is required", f"Expected 400, got {status}: {body}"

        status, body, _ = make_request("POST", "/todos", {"title": ""}, cookies=session_cookie)
        assert status == 400 and body["error"] == "Title is required", f"Expected 400, got {status}: {body}"

        status, body, _ = make_request("POST", "/todos", {"title": "My first todo", "description": "Do this thing"}, cookies=session_cookie)
        assert status == 201 and body["title"] == "My first todo" and body["completed"] == False, f"Expected 201, got {status}: {body}"
        todo_id = body["id"]

        print("Testing GET /todos")
        status, body, _ = make_request("GET", "/todos", cookies=session_cookie)
        assert status == 200 and len(body) == 1 and body[0]["id"] == todo_id, f"Expected 200, got {status}: {body}"

        print("Testing GET /todos/:id")
        status, body, _ = make_request("GET", f"/todos/{todo_id}", cookies=session_cookie)
        assert status == 200 and body["id"] == todo_id, f"Expected 200, got {status}: {body}"

        print("Testing PUT /todos/:id")
        status, body, _ = make_request("PUT", f"/todos/{todo_id}", {"completed": True}, cookies=session_cookie)
        assert status == 200 and body["completed"] == True, f"Expected 200, got {status}: {body}"

        status, body, _ = make_request("PUT", f"/todos/{todo_id}", {"title": "  "}, cookies=session_cookie)
        assert status == 400 and body["error"] == "Title is required", f"Expected 400, got {status}: {body}"

        print("Testing 404 for other users' todos")
        make_request("POST", "/register", {"username": "user2", "password": "password123"})
        status, body, cookies2 = make_request("POST", "/login", {"username": "user2", "password": "password123"})
        
        status, body, _ = make_request("GET", f"/todos/{todo_id}", cookies=cookies2)
        assert status == 404 and body["error"] == "Todo not found", f"Expected 404, got {status}: {body}"

        status, body, _ = make_request("PUT", f"/todos/{todo_id}", {"completed": False}, cookies=cookies2)
        assert status == 404 and body["error"] == "Todo not found", f"Expected 404, got {status}: {body}"

        status, body, _ = make_request("DELETE", f"/todos/{todo_id}", cookies=cookies2)
        assert status == 404 and body["error"] == "Todo not found", f"Expected 404, got {status}: {body}"

        print("Testing DELETE /todos/:id")
        status, body, _ = make_request("DELETE", f"/todos/{todo_id}", cookies=session_cookie)
        assert status == 204 and body is None, f"Expected 204, got {status}: {body}"

        status, body, _ = make_request("GET", f"/todos/{todo_id}", cookies=session_cookie)
        assert status == 404 and body["error"] == "Todo not found", f"Expected 404, got {status}: {body}"

        print("\nAll tests passed successfully!")
    except AssertionError as e:
        print(f"\nTest failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
    finally:
        proc.terminate()
        proc.wait()

if __name__ == "__main__":
    test()