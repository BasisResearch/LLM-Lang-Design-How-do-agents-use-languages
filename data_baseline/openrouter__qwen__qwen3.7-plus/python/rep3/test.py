#!/usr/bin/env python3
import subprocess
import time
import requests
import sys
import os

PORT = 5051
BASE_URL = f"http://localhost:{PORT}"

def start_server():
    env = os.environ.copy()
    proc = subprocess.Popen([sys.executable, "server.py", "--port", str(PORT)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    
    # Wait for server to be ready
    for _ in range(20):
        try:
            requests.get(f"{BASE_URL}/me", timeout=1)
            break
        except requests.exceptions.RequestException:
            time.sleep(0.5)
    else:
        print("Server failed to start")
        proc.terminate()
        sys.exit(1)
        
    return proc

def test_server():
    print("Starting tests...")
    
    # Test register invalid username
    r = requests.post(f"{BASE_URL}/register", json={"username": "ab", "password": "password123"})
    assert r.status_code == 400 and r.json()["error"] == "Invalid username", f"Failed: {r.status_code} {r.text}"
    print("PASS: register invalid username")
    
    # Test register invalid password
    r = requests.post(f"{BASE_URL}/register", json={"username": "testuser", "password": "short"})
    assert r.status_code == 400 and r.json()["error"] == "Password too short", f"Failed: {r.status_code} {r.text}"
    print("PASS: register invalid password")
    
    # Test valid register
    r = requests.post(f"{BASE_URL}/register", json={"username": "testuser", "password": "password123"})
    assert r.status_code == 201, f"Failed: {r.status_code} {r.text}"
    assert r.json()["id"] == 1 and r.json()["username"] == "testuser"
    print("PASS: register valid")
    
    # Test duplicate username
    r = requests.post(f"{BASE_URL}/register", json={"username": "testuser", "password": "password123"})
    assert r.status_code == 409 and r.json()["error"] == "Username already exists", f"Failed: {r.status_code} {r.text}"
    print("PASS: register duplicate")
    
    # Test login invalid
    r = requests.post(f"{BASE_URL}/login", json={"username": "testuser", "password": "wrongpass"})
    assert r.status_code == 401 and r.json()["error"] == "Invalid credentials", f"Failed: {r.status_code} {r.text}"
    print("PASS: login invalid")
    
    # Test valid login
    r = requests.post(f"{BASE_URL}/login", json={"username": "testuser", "password": "password123"})
    assert r.status_code == 200, f"Failed: {r.status_code} {r.text}"
    assert "session_id" in r.cookies
    token = r.cookies["session_id"]
    print(f"PASS: login valid, token: {token}")
    
    # Test auth required
    r = requests.get(f"{BASE_URL}/me")
    assert r.status_code == 401 and r.json()["error"] == "Authentication required", f"Failed: {r.status_code} {r.text}"
    print("PASS: me no auth")
    
    # Test me valid
    r = requests.get(f"{BASE_URL}/me", cookies={"session_id": token})
    assert r.status_code == 200 and r.json()["username"] == "testuser", f"Failed: {r.status_code} {r.text}"
    print("PASS: me valid")
    
    # Test password invalid old
    r = requests.put(f"{BASE_URL}/password", json={"old_password": "wrong", "new_password": "newpassword123"}, cookies={"session_id": token})
    assert r.status_code == 401 and r.json()["error"] == "Invalid credentials", f"Failed: {r.status_code} {r.text}"
    print("PASS: password invalid old")
    
    # Test password invalid new
    r = requests.put(f"{BASE_URL}/password", json={"old_password": "password123", "new_password": "short"}, cookies={"session_id": token})
    assert r.status_code == 400 and r.json()["error"] == "Password too short", f"Failed: {r.status_code} {r.text}"
    print("PASS: password invalid new")
    
    # Test password valid
    r = requests.put(f"{BASE_URL}/password", json={"old_password": "password123", "new_password": "newpassword123"}, cookies={"session_id": token})
    assert r.status_code == 200, f"Failed: {r.status_code} {r.text}"
    print("PASS: password valid")
    
    # Re-login with new password
    r = requests.post(f"{BASE_URL}/login", json={"username": "testuser", "password": "newpassword123"})
    assert r.status_code == 200
    token = r.cookies["session_id"]
    print("PASS: login with new password")
    
    # Test todos get empty
    r = requests.get(f"{BASE_URL}/todos", cookies={"session_id": token})
    assert r.status_code == 200 and r.json() == [], f"Failed: {r.status_code} {r.text}"
    print("PASS: todos get empty")
    
    # Test todos post missing title
    r = requests.post(f"{BASE_URL}/todos", json={"description": "test"}, cookies={"session_id": token})
    assert r.status_code == 400 and r.json()["error"] == "Title is required", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos post missing title")
    
    # Test todos post empty title
    r = requests.post(f"{BASE_URL}/todos", json={"title": "", "description": "test"}, cookies={"session_id": token})
    assert r.status_code == 400 and r.json()["error"] == "Title is required", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos post empty title")
    
    # Test todos post valid
    r = requests.post(f"{BASE_URL}/todos", json={"title": "First Todo", "description": "This is a test"}, cookies={"session_id": token})
    assert r.status_code == 201, f"Failed: {r.status_code} {r.text}"
    todo = r.json()
    assert todo["title"] == "First Todo" and todo["completed"] is False and todo["id"] == 1
    todo_id = todo["id"]
    print(f"PASS: todos post valid, id: {todo_id}")
    
    # Test todos get by id
    r = requests.get(f"{BASE_URL}/todos/{todo_id}", cookies={"session_id": token})
    assert r.status_code == 200 and r.json()["title"] == "First Todo", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos get by id")
    
    # Test todos get non-existent
    r = requests.get(f"{BASE_URL}/todos/9999", cookies={"session_id": token})
    assert r.status_code == 404 and r.json()["error"] == "Todo not found", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos get non-existent")
    
    # Test todos put empty title
    r = requests.put(f"{BASE_URL}/todos/{todo_id}", json={"title": ""}, cookies={"session_id": token})
    assert r.status_code == 400 and r.json()["error"] == "Title is required", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos put empty title")
    
    # Test todos put valid
    r = requests.put(f"{BASE_URL}/todos/{todo_id}", json={"title": "Updated Todo", "completed": True}, cookies={"session_id": token})
    assert r.status_code == 200, f"Failed: {r.status_code} {r.text}"
    todo = r.json()
    assert todo["title"] == "Updated Todo" and todo["completed"] is True and "updated_at" in todo
    print("PASS: todos put valid")
    
    # Test todos get after update
    r = requests.get(f"{BASE_URL}/todos", cookies={"session_id": token})
    assert r.status_code == 200 and r.json()[0]["title"] == "Updated Todo", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos get after update")
    
    # Test todos delete
    r = requests.delete(f"{BASE_URL}/todos/{todo_id}", cookies={"session_id": token})
    assert r.status_code == 204, f"Failed: {r.status_code} {r.text}"
    print("PASS: todos delete")
    
    # Test todos get after delete
    r = requests.get(f"{BASE_URL}/todos/{todo_id}", cookies={"session_id": token})
    assert r.status_code == 404 and r.json()["error"] == "Todo not found", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos get after delete")
    
    # Test logout
    r = requests.post(f"{BASE_URL}/logout", cookies={"session_id": token})
    assert r.status_code == 200 and r.json() == {}, f"Failed: {r.status_code} {r.text}"
    print("PASS: logout")
    
    # Test me after logout
    r = requests.get(f"{BASE_URL}/me", cookies={"session_id": token})
    assert r.status_code == 401 and r.json()["error"] == "Authentication required", f"Failed: {r.status_code} {r.text}"
    print("PASS: me after logout")
    
    # Test Todo Isolation (Different User)
    requests.post(f"{BASE_URL}/register", json={"username": "user2", "password": "password123"})
    r = requests.post(f"{BASE_URL}/login", json={"username": "user2", "password": "password123"})
    token2 = r.cookies["session_id"]
    
    r = requests.post(f"{BASE_URL}/todos", json={"title": "User 2 Todo"}, cookies={"session_id": token2})
    todo_id_2 = r.json()["id"]
    
    r = requests.post(f"{BASE_URL}/login", json={"username": "testuser", "password": "newpassword123"})
    token1 = r.cookies["session_id"]
    
    r = requests.get(f"{BASE_URL}/todos/{todo_id_2}", cookies={"session_id": token1})
    assert r.status_code == 404 and r.json()["error"] == "Todo not found", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos get other user's todo returns 404")
    
    r = requests.put(f"{BASE_URL}/todos/{todo_id_2}", json={"title": "Hacked"}, cookies={"session_id": token1})
    assert r.status_code == 404 and r.json()["error"] == "Todo not found", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos put other user's todo returns 404")
    
    r = requests.delete(f"{BASE_URL}/todos/{todo_id_2}", cookies={"session_id": token1})
    assert r.status_code == 404 and r.json()["error"] == "Todo not found", f"Failed: {r.status_code} {r.text}"
    print("PASS: todos delete other user's todo returns 404")
    
    print("=== All tests passed! ===")

if __name__ == "__main__":
    proc = start_server()
    try:
        test_server()
    finally:
        proc.terminate()
        proc.wait()