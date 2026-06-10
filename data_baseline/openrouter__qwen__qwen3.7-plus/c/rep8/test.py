#!/usr/bin/env python3
import subprocess
import sys
import time
import urllib.request
import urllib.error
import json
import os
import signal

PORT = 8765

# Start server
server_proc = subprocess.Popen(['./server', '--port', str(PORT)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
time.sleep(1)

def cleanup():
    server_proc.terminate()
    server_proc.wait()

import atexit
atexit.register(cleanup)

def catch_sig(sig, frame):
    cleanup()
    sys.exit(0)

signal.signal(signal.SIGINT, catch_sig)
signal.signal(signal.SIGTERM, catch_sig)

BASE_URL = f"http://127.0.0.1:{PORT}"

def req(method, path, data=None, cookies=None):
    url = BASE_URL + path
    headers = {'Content-Type': 'application/json'}
    if cookies:
        headers['Cookie'] = cookies
    body = json.dumps(data).encode('utf-8') if data else None
    
    try:
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        with urllib.request.urlopen(request) as response:
            resp_body = response.read().decode('utf-8')
            resp_code = response.getcode()
            resp_cookies = response.headers.get('Set-Cookie', '')
            return resp_code, resp_body, resp_cookies
    except urllib.error.HTTPError as e:
        resp_body = e.read().decode('utf-8') if e.fp else ''
        resp_cookies = e.headers.get('Set-Cookie', '')
        return e.code, resp_body, resp_cookies

def test(name, condition, msg=""):
    if condition:
        print(f"PASS: {name}")
    else:
        print(f"FAIL: {name} - {msg}")
        sys.exit(1)

cookies = ""

print("Testing /register...")
code, body, c = req("POST", "/register", {"username": "testuser", "password": "password123"})
test("/register", code == 201 and '"username":"testuser"' in body, f"Got {code}, {body}")

print("Testing /register duplicate...")
code, body, c = req("POST", "/register", {"username": "testuser", "password": "password123"})
test("/register duplicate", code == 409 and '"error":"Username already exists"' in body, f"Got {code}, {body}")

print("Testing /register invalid username (too short)...")
code, body, c = req("POST", "/register", {"username": "ab", "password": "password12"})
test("/register invalid username", code == 400, f"Got {code}, {body}")

print("Testing /register invalid username (bad chars)...")
code, body, c = req("POST", "/register", {"username": "test-user", "password": "password12"})
test("/register invalid username bad chars", code == 400, f"Got {code}, {body}")

print("Testing /register short password...")
code, body, c = req("POST", "/register", {"username": "testuser2", "password": "short"})
test("/register short password", code == 400, f"Got {code}, {body}")

print("Testing /login...")
code, body, c = req("POST", "/login", {"username": "testuser", "password": "password123"})
test("/login", code == 200 and "session_id=" in c, f"Got {code}, {body}, cookies: {c}")
if "session_id=" in c:
    cookies = c.split(';')[0]

print("Testing /login invalid...")
code, body, c = req("POST", "/login", {"username": "testuser", "password": "wrongpassword"})
test("/login invalid", code == 401 and '"error":"Invalid credentials"' in body, f"Got {code}, {body}")

print("Testing /me...")
code, body, c = req("GET", "/me", cookies=cookies)
test("/me", code == 200 and '"username":"testuser"' in body, f"Got {code}, {body}")

print("Testing /me unauthenticated...")
code, body, c = req("GET", "/me")
test("/me unauthenticated", code == 401 and '"error":"Authentication required"' in body, f"Got {code}, {body}")

print("Testing /password...")
code, body, c = req("PUT", "/password", {"old_password": "password123", "new_password": "newpassword123"}, cookies=cookies)
test("/password", code == 200, f"Got {code}, {body}")

print("Testing /password invalid old...")
code, body, c = req("PUT", "/password", {"old_password": "wrong", "new_password": "newpassword123"}, cookies=cookies)
test("/password invalid old", code == 401 and '"error":"Invalid credentials"' in body, f"Got {code}, {body}")

print("Testing /password short new...")
code, body, c = req("PUT", "/password", {"old_password": "newpassword123", "new_password": "short"}, cookies=cookies)
test("/password short new", code == 400 and '"error":"Password too short"' in body, f"Got {code}, {body}")

print("Re-login after password change...")
code, body, c = req("POST", "/login", {"username": "testuser", "password": "newpassword123"})
test("re-login", code == 200, f"Got {code}, {body}")
if "session_id=" in c:
    cookies = c.split(';')[0]

print("Testing POST /todos...")
code, body, c = req("POST", "/todos", {"title": "My First Todo", "description": "This is a description"}, cookies=cookies)
test("POST /todos", code == 201 and '"title":"My First Todo"' in body, f"Got {code}, {body}")
todo_id = json.loads(body)["id"]

print("Testing POST /todos missing title...")
code, body, c = req("POST", "/todos", {"description": "No title"}, cookies=cookies)
test("POST /todos missing title", code == 400 and '"error":"Title is required"' in body, f"Got {code}, {body}")

print("Testing POST /todos empty title...")
code, body, c = req("POST", "/todos", {"title": ""}, cookies=cookies)
test("POST /todos empty title", code == 400 and '"error":"Title is required"' in body, f"Got {code}, {body}")

print("Testing GET /todos...")
code, body, c = req("GET", "/todos", cookies=cookies)
test("GET /todos", code == 200 and '"title":"My First Todo"' in body, f"Got {code}, {body}")

print("Testing GET /todos/:id...")
code, body, c = req("GET", f"/todos/{todo_id}", cookies=cookies)
test("GET /todos/:id", code == 200 and f'"id":{todo_id}' in body, f"Got {code}, {body}")

print("Testing GET /todos/:id not found...")
code, body, c = req("GET", "/todos/99999", cookies=cookies)
test("GET /todos/:id not found", code == 404 and '"error":"Todo not found"' in body, f"Got {code}, {body}")

print("Testing PUT /todos/:id...")
code, body, c = req("PUT", f"/todos/{todo_id}", {"title": "Updated Title", "completed": True}, cookies=cookies)
test("PUT /todos/:id", code == 200 and '"title":"Updated Title"' in body and '"completed":true' in body, f"Got {code}, {body}")

print("Testing PUT /todos/:id empty title...")
code, body, c = req("PUT", f"/todos/{todo_id}", {"title": ""}, cookies=cookies)
test("PUT /todos/:id empty title", code == 400 and '"error":"Title is required"' in body, f"Got {code}, {body}")

print("Testing DELETE /todos/:id...")
code, body, c = req("DELETE", f"/todos/{todo_id}", cookies=cookies)
test("DELETE /todos/:id", code == 204, f"Got {code}, {body}")

print("Testing DELETE /todos/:id not found (after delete)...")
code, body, c = req("DELETE", f"/todos/{todo_id}", cookies=cookies)
test("DELETE /todos/:id not found", code == 404 and '"error":"Todo not found"' in body, f"Got {code}, {body}")

print("Testing /logout...")
code, body, c = req("POST", "/logout", cookies=cookies)
test("/logout", code == 200, f"Got {code}, {body}")

print("Testing /me after logout...")
code, body, c = req("GET", "/me", cookies=cookies)
test("/me after logout", code == 401 and '"error":"Authentication required"' in body, f"Got {code}, {body}")

print("Testing ID enumeration prevention (other user's todo)...")
# Create second user
req("POST", "/register", {"username": "user2", "password": "password123"})
code, body, c = req("POST", "/login", {"username": "user2", "password": "password123"})
cookies2 = c.split(';')[0] if "session_id=" in c else ""

# user2 tries to access todo 1 (belongs to testuser)
code, body, c = req("GET", "/todos/1", cookies=cookies2)
test("ID enumeration prevention", code == 404 and '"error":"Todo not found"' in body, f"Got {code}, {body}")

print("")
print("=========================================")
print("ALL TESTS PASSED!")
print("=========================================")

cleanup()
sys.exit(0)
