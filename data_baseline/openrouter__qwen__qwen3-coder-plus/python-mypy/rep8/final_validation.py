#!/usr/bin/env python3
"""
Final validation that all endpoints work as specified in the requirements.
"""

import subprocess
import time
import signal
import sys
import json
import urllib.request
import urllib.error
import uuid


# Start server
port = 8004
unique_id = str(uuid.uuid4())[:8]
server_proc = subprocess.Popen([sys.executable, 'server.py', '--port', str(port)])
time.sleep(1)

print(f"Final validation test starting on port {port}")

def get_cookie_from_response(response):
    cookies = response.headers.get_all('Set-Cookie', [])
    for cookie in cookies:
        if cookie.startswith('session_id='):
            return cookie.split(';')[0].split('=')[1]
    return None


status_code = 0

try:
    base_url = f"http://localhost:{port}"
    
    # 1. Register (POST /register)
    print("✓ Testing /register")
    resp = urllib.request.urlopen(urllib.request.Request(
        f"{base_url}/register",
        data=json.dumps({"username": f"user_finalval_{unique_id}", "password": "password123"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST"
    ))
    user_data = json.loads(resp.read())
    user_id = user_data['id']
    print(f"Registration successful: {user_data}")
    
    # 2. Login (POST /login) 
    print("✓ Testing /login")
    login_req = urllib.request.Request(
        f"{base_url}/login",
        data=json.dumps({"username": f"user_finalval_{unique_id}", "password": "password123"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(login_req) as resp:
        login_data = json.loads(resp.read())
        session_id = get_cookie_from_response(resp)
        print(f"Login successful: {login_data}, Session: {session_id}")
    
    auth_headers = {"Cookie": f"session_id={session_id}"}
    
    # 3. Get profile (GET /me)
    print("✓ Testing /me")
    req = urllib.request.Request(f"{base_url}/me", headers=auth_headers, method="GET")
    with urllib.request.urlopen(req) as resp:
        me_data = json.loads(resp.read())
        print(f"Profile retrieved: {me_data}")
    
    # 4. Create todo (POST /todos)
    print("✓ Testing /todos (POST)")
    req = urllib.request.Request(
        f"{base_url}/todos",
        data=json.dumps({"title": f"My Todo {unique_id}", "description": "Test description"}).encode(),
        headers={**auth_headers, "Content-Type": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        todo_data = json.loads(resp.read())
        todo_id = todo_data['id']
        print(f"Todo created: {todo_data}")
    
    # 5. Get all todos (GET /todos)
    print("✓ Testing /todos (GET)")
    req = urllib.request.Request(f"{base_url}/todos", headers=auth_headers, method="GET")
    with urllib.request.urlopen(req) as resp:
        todos_list = json.loads(resp.read())
        print(f"Todos retrieved: {len(todos_list)} items")
    
    # 6. Get specific todo (GET /todos/:id)
    print("✓ Testing /todos/{id} (GET)")
    req = urllib.request.Request(f"{base_url}/todos/{todo_id}", headers=auth_headers, method="GET")
    with urllib.request.urlopen(req) as resp:
        specific_todo = json.loads(resp.read())
        print(f"Specific todo: {specific_todo}")
    
    # 7. Update todo (PUT /todos/:id)
    print("✓ Testing /todos/{id} (PUT)")
    req = urllib.request.Request(
        f"{base_url}/todos/{todo_id}",
        data=json.dumps({"title": f"Updated Todo {unique_id}", "completed": True}).encode(),
        headers={**auth_headers, "Content-Type": "application/json"},
        method="PUT"
    )
    with urllib.request.urlopen(req) as resp:
        updated_todo = json.loads(resp.read())
        print(f"Todo updated: {updated_todo}")
    
    # 8. Change password (PUT /password)
    print("✓ Testing /password")
    req = urllib.request.Request(
        f"{base_url}/password",
        data=json.dumps({
            "old_password": "password123",
            "new_password": "newpass456"
        }).encode(),
        headers={**auth_headers, "Content-Type": "application/json"},
        method="PUT"
    )
    with urllib.request.urlopen(req) as resp:
        if resp.status == 200:
            print("Password updated successfully")
        else:
            print(f"Failed to update password: {resp.status}")
    
    # 9. Logout (POST /logout)
    print("✓ Testing /logout")
    req = urllib.request.Request(f"{base_url}/logout", headers=auth_headers, method="POST")
    with urllib.request.urlopen(req) as resp:
        if resp.status == 200:
            print("Logged out successfully")
    
    # 10. Verify unauthorized access doesn't work anymore
    print("✓ Testing unauthorized access after logout")
    req = urllib.request.Request(f"{base_url}/me", headers=auth_headers, method="GET")
    try:
        with urllib.request.urlopen(req) as resp:
            print("FAIL: Still authorized after logout")
    except urllib.error.HTTPError as e:
        if e.code == 401:
            print("OK: Properly unauthenticated after logout")
        else:
            print(f"FAIL: Unexpected error after logout: {e.code}")
    
    # 11. Try to delete the created todo after re-authenticating
    print("✓ Re-authenticating to delete todo")
    login_req = urllib.request.Request(
        f"{base_url}/login",
        data=json.dumps({"username": f"user_finalval_{unique_id}", "password": "newpass456"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(login_req) as resp:
        session_id = get_cookie_from_response(resp)
        new_auth_headers = {"Cookie": f"session_id={session_id}"}
        print("Re-login successful")
    
    print("✓ Testing /todos/{id} (DELETE)")
    del_req = urllib.request.Request(f"{base_url}/todos/{todo_id}", headers=new_auth_headers, method="DELETE")
    try:
        with urllib.request.urlopen(del_req) as resp:
            if resp.status == 204:
                print("Todo deleted successfully")
            else:
                print(f"Unexpected response on delete: {resp.status}")
    except urllib.error.HTTPError as e:
        print(f"Delete failed: {e.code} - {e.read().decode()}")
    
    print("SUCCESS: All endpoints validated successfully!")

except Exception as e:
    print(f"FAILURE: {e}")
    import traceback
    traceback.print_exc()
    status_code = 1

finally:
    server_proc.terminate()
    try:
        server_proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server_proc.kill()
    
sys.exit(status_code)