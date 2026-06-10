#!/usr/bin/env python3
import subprocess
import time
import urllib.request
import urllib.error
import json
import sys
import os

PORT = 8767
BASE_URL = f"http://localhost:{PORT}"

def start_server():
    proc = subprocess.Popen(
        [sys.executable, "server.py", "--port", str(PORT)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    time.sleep(2)
    return proc

def stop_server(proc):
    proc.terminate()
    proc.wait()

def req(method, path, data=None, cookies=None):
    url = f"{BASE_URL}{path}"
    headers = {"Content-Type": "application/json"}
    if cookies:
        headers["Cookie"] = "; ".join([f"{k}={v}" for k, v in cookies.items()])
    
    req_data = json.dumps(data).encode("utf-8") if data else None
    
    request = urllib.request.Request(url, data=req_data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request) as response:
            body = response.read().decode("utf-8")
            # Extract cookies from response
            resp_cookies = {}
            if "Set-Cookie" in response.headers:
                cookie_header = response.headers["Set-Cookie"]
                # Simple parsing: session_id=<value>; Path=/; HttpOnly
                parts = cookie_header.split(";")
                for part in parts:
                    part = part.strip()
                    if "=" in part:
                        k, v = part.split("=", 1)
                        resp_cookies[k.strip()] = v.strip()
            return response.status, body, resp_cookies
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        return e.code, body, {}

def main():
    print("Starting server...")
    proc = start_server()
    
    try:
        cookies = {}
        
        print("Testing /register...")
        code, body, _ = req("POST", "/register", {"username": "testuser", "password": "password123"})
        assert code == 201, f"Expected 201, got {code}: {body}"
        print("PASS: /register")
        
        print("Testing /register duplicate...")
        code, body, _ = req("POST", "/register", {"username": "testuser", "password": "password123"})
        assert code == 409, f"Expected 409, got {code}: {body}"
        print("PASS: /register duplicate")
        
        print("Testing /register invalid username...")
        code, body, _ = req("POST", "/register", {"username": "ab", "password": "password123"})
        assert code == 400, f"Expected 400, got {code}: {body}"
        print("PASS: /register invalid username")
        
        print("Testing /register short password...")
        code, body, _ = req("POST", "/register", {"username": "testuser2", "password": "short"})
        assert code == 400, f"Expected 400, got {code}: {body}"
        print("PASS: /register short password")
        
        print("Testing /login...")
        code, body, resp_cookies = req("POST", "/login", {"username": "testuser", "password": "password123"})
        assert code == 200, f"Expected 200, got {code}: {body}"
        assert "session_id" in resp_cookies, "Missing session_id cookie"
        cookies["session_id"] = resp_cookies["session_id"]
        print("PASS: /login")
        
        print("Testing /login invalid credentials...")
        code, body, _ = req("POST", "/login", {"username": "testuser", "password": "wrongpassword"})
        assert code == 401, f"Expected 401, got {code}: {body}"
        print("PASS: /login invalid credentials")
        
        print("Testing /me...")
        code, body, _ = req("GET", "/me", cookies=cookies)
        assert code == 200, f"Expected 200, got {code}: {body}"
        print("PASS: /me")
        
        print("Testing /me without auth...")
        code, body, _ = req("GET", "/me")
        assert code == 401, f"Expected 401, got {code}: {body}"
        print("PASS: /me without auth")
        
        print("Testing /password...")
        code, body, _ = req("PUT", "/password", {"old_password": "password123", "new_password": "newpassword123"}, cookies=cookies)
        assert code == 200, f"Expected 200, got {code}: {body}"
        print("PASS: /password")
        
        print("Testing /password invalid old...")
        code, body, _ = req("PUT", "/password", {"old_password": "wrong", "new_password": "newpassword123"}, cookies=cookies)
        assert code == 401, f"Expected 401, got {code}: {body}"
        print("PASS: /password invalid old")
        
        print("Testing /password short new...")
        code, body, _ = req("PUT", "/password", {"old_password": "newpassword123", "new_password": "short"}, cookies=cookies)
        assert code == 400, f"Expected 400, got {code}: {body}"
        print("PASS: /password short new")
        
        print("Testing POST /todos...")
        code, body, _ = req("POST", "/todos", {"title": "My Todo", "description": "Test desc"}, cookies=cookies)
        assert code == 201, f"Expected 201, got {code}: {body}"
        todo = json.loads(body)
        assert todo["title"] == "My Todo"
        assert todo["completed"] is False
        print("PASS: POST /todos")
        
        print("Testing POST /todos missing title...")
        code, body, _ = req("POST", "/todos", {"description": "Test desc"}, cookies=cookies)
        assert code == 400, f"Expected 400, got {code}: {body}"
        print("PASS: POST /todos missing title")
        
        print("Testing GET /todos...")
        code, body, _ = req("GET", "/todos", cookies=cookies)
        assert code == 200, f"Expected 200, got {code}: {body}"
        todos_list = json.loads(body)
        assert len(todos_list) == 1
        print("PASS: GET /todos")
        
        print("Testing GET /todos/:id...")
        code, body, _ = req("GET", "/todos/1", cookies=cookies)
        assert code == 200, f"Expected 200, got {code}: {body}"
        print("PASS: GET /todos/1")
        
        print("Testing GET /todos/:id not found...")
        code, body, _ = req("GET", "/todos/999", cookies=cookies)
        assert code == 404, f"Expected 404, got {code}: {body}"
        print("PASS: GET /todos/999")
        
        print("Testing PUT /todos/:id...")
        code, body, _ = req("PUT", "/todos/1", {"completed": True}, cookies=cookies)
        assert code == 200, f"Expected 200, got {code}: {body}"
        updated_todo = json.loads(body)
        assert updated_todo["completed"] is True
        print("PASS: PUT /todos/1")
        
        print("Testing PUT /todos/:id empty title...")
        code, body, _ = req("PUT", "/todos/1", {"title": ""}, cookies=cookies)
        assert code == 400, f"Expected 400, got {code}: {body}"
        print("PASS: PUT /todos/1 empty title")
        
        print("Testing cross-user todo access (404 not 403)...")
        # Register another user
        req("POST", "/register", {"username": "user2", "password": "password123"})
        _, _, resp_cookies = req("POST", "/login", {"username": "user2", "password": "password123"})
        cookies2 = {"session_id": resp_cookies["session_id"]}
        
        # Create a todo for user2
        code, body, _ = req("POST", "/todos", {"title": "User 2 Todo"}, cookies=cookies2)
        assert code == 201
        todo2 = json.loads(body)
        todo2_id = todo2["id"]
        
        # User 1 tries to access user 2's todo
        code, body, _ = req("GET", f"/todos/{todo2_id}", cookies=cookies)
        assert code == 404, f"Expected 404, got {code}: {body}"
        print("PASS: cross-user todo access returns 404")

        print("Testing DELETE /todos/:id...")
        code, body, _ = req("DELETE", "/todos/1", cookies=cookies)
        assert code == 204, f"Expected 204, got {code}: {body}"
        print("PASS: DELETE /todos/1")
        
        print("Testing DELETE /todos/:id not found...")
        code, body, _ = req("DELETE", "/todos/1", cookies=cookies)
        assert code == 404, f"Expected 404, got {code}: {body}"
        print("PASS: DELETE /todos/1 not found")
        
        print("Testing /logout...")
        code, body, _ = req("POST", "/logout", cookies=cookies)
        assert code == 200, f"Expected 200, got {code}: {body}"
        print("PASS: /logout")
        
        print("Testing /me after logout...")
        code, body, _ = req("GET", "/me", cookies=cookies)
        assert code == 401, f"Expected 401, got {code}: {body}"
        print("PASS: /me after logout")
        
        print("\nALL TESTS PASSED!")
        
    finally:
        print("Stopping server...")
        stop_server(proc)

if __name__ == "__main__":
    main()
