#!/usr/bin/env python3
import subprocess
import time
import requests
import sys
import signal

PORT = 8765
HOST = f"http://127.0.0.1:{PORT}"

def start_server():
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", str(PORT)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    time.sleep(2)
    return proc

def test_register_valid():
    print("Testing register valid user...", end=" ")
    res = requests.post(f"{HOST}/register", json={"username": "testuser", "password": "securepass123"})
    assert res.status_code == 201, f"Expected 201, got {res.status_code}: {res.text}"
    assert res.json()["username"] == "testuser"
    print("PASSED")

def test_register_invalid_username():
    print("Testing register invalid username...", end=" ")
    res = requests.post(f"{HOST}/register", json={"username": "ab", "password": "securepass123"})
    assert res.status_code == 400, f"Expected 400, got {res.status_code}"
    assert res.json()["error"] == "Invalid username"
    print("PASSED")

def test_register_short_password():
    print("Testing register short password...", end=" ")
    res = requests.post(f"{HOST}/register", json={"username": "testuser2", "password": "short"})
    assert res.status_code == 400, f"Expected 400, got {res.status_code}"
    assert res.json()["error"] == "Password too short"
    print("PASSED")

def test_register_duplicate():
    print("Testing register duplicate username...", end=" ")
    res = requests.post(f"{HOST}/register", json={"username": "testuser", "password": "securepass123"})
    assert res.status_code == 409, f"Expected 409, got {res.status_code}"
    assert res.json()["error"] == "Username already exists"
    print("PASSED")

def test_login_success():
    print("Testing login success...", end=" ")
    global session
    session = requests.Session()
    res = session.post(f"{HOST}/login", json={"username": "testuser", "password": "securepass123"})
    assert res.status_code == 200, f"Expected 200, got {res.status_code}: {res.text}"
    assert session.cookies.get("session_id") is not None, f"Cookies: {session.cookies.get_dict()}"
    print("PASSED")

def test_login_invalid():
    print("Testing login invalid credentials...", end=" ")
    res = requests.post(f"{HOST}/login", json={"username": "testuser", "password": "wrongpass"})
    assert res.status_code == 401, f"Expected 401, got {res.status_code}"
    assert res.json()["error"] == "Invalid credentials"
    print("PASSED")

def test_me_success():
    print("Testing GET /me success...", end=" ")
    res = session.get(f"{HOST}/me")
    assert res.status_code == 200, f"Expected 200, got {res.status_code}"
    assert res.json()["username"] == "testuser"
    print("PASSED")

def test_me_unauthorized():
    print("Testing GET /me unauthorized...", end=" ")
    res = requests.get(f"{HOST}/me")
    assert res.status_code == 401, f"Expected 401, got {res.status_code}"
    assert res.json()["error"] == "Authentication required"
    print("PASSED")

def test_change_password():
    print("Testing PUT /password success...", end=" ")
    res = session.put(f"{HOST}/password", json={"old_password": "securepass123", "new_password": "newpassword123"})
    assert res.status_code == 200, f"Expected 200, got {res.status_code}"
    print("PASSED")

def test_change_password_invalid_old():
    print("Testing PUT /password invalid old password...", end=" ")
    res = session.put(f"{HOST}/password", json={"old_password": "wrongpass", "new_password": "newpassword123"})
    assert res.status_code == 401, f"Expected 401, got {res.status_code}"
    assert res.json()["error"] == "Invalid credentials"
    print("PASSED")

def test_create_todo():
    print("Testing POST /todos success...", end=" ")
    res = session.post(f"{HOST}/todos", json={"title": "My Todo", "description": "Do something"})
    assert res.status_code == 201, f"Expected 201, got {res.status_code}"
    assert res.json()["title"] == "My Todo"
    assert res.json()["completed"] == False
    print("PASSED")

def test_create_todo_no_title():
    print("Testing POST /todos no title...", end=" ")
    res = session.post(f"{HOST}/todos", json={"description": "Do something"})
    assert res.status_code == 400, f"Expected 400, got {res.status_code}"
    assert res.json()["error"] == "Title is required"
    print("PASSED")

def test_get_todos():
    print("Testing GET /todos success...", end=" ")
    res = session.get(f"{HOST}/todos")
    assert res.status_code == 200, f"Expected 200, got {res.status_code}"
    assert len(res.json()) == 1
    print("PASSED")

def test_get_todo():
    print("Testing GET /todos/1 success...", end=" ")
    res = session.get(f"{HOST}/todos/1")
    assert res.status_code == 200, f"Expected 200, got {res.status_code}"
    assert res.json()["title"] == "My Todo"
    print("PASSED")

def test_get_todo_not_found():
    print("Testing GET /todos/999 not found...", end=" ")
    res = session.get(f"{HOST}/todos/999")
    assert res.status_code == 404, f"Expected 404, got {res.status_code}"
    assert res.json()["error"] == "Todo not found"
    print("PASSED")

def test_update_todo():
    print("Testing PUT /todos/1 success...", end=" ")
    res = session.put(f"{HOST}/todos/1", json={"title": "Updated Title", "completed": True})
    assert res.status_code == 200, f"Expected 200, got {res.status_code}"
    assert res.json()["title"] == "Updated Title"
    assert res.json()["completed"] == True
    print("PASSED")

def test_update_todo_empty_title():
    print("Testing PUT /todos/1 empty title...", end=" ")
    res = session.put(f"{HOST}/todos/1", json={"title": ""})
    assert res.status_code == 400, f"Expected 400, got {res.status_code}"
    assert res.json()["error"] == "Title is required"
    print("PASSED")

def test_delete_todo():
    print("Testing DELETE /todos/1 success...", end=" ")
    res = session.delete(f"{HOST}/todos/1")
    assert res.status_code == 204, f"Expected 204, got {res.status_code}"
    assert res.text == ""
    print("PASSED")

def test_logout():
    print("Testing POST /logout success...", end=" ")
    res = session.post(f"{HOST}/logout")
    assert res.status_code == 200, f"Expected 200, got {res.status_code}"
    print("PASSED")

def test_todo_after_logout():
    print("Testing GET /todos after logout (should be 401)...", end=" ")
    res = session.get(f"{HOST}/todos")
    assert res.status_code == 401, f"Expected 401, got {res.status_code}"
    assert res.json()["error"] == "Authentication required"
    print("PASSED")

def test_cross_user_todo_not_found():
    print("Testing cross-user todo not found...", end=" ")
    # user 1 creates a todo
    s1 = requests.Session()
    s1.post(f"{HOST}/login", json={"username": "testuser", "password": "newpassword123"})
    res1 = s1.post(f"{HOST}/todos", json={"title": "User 1 Todo"})
    todo_id = res1.json()["id"]
    
    # user 2 logs in
    s2 = requests.Session()
    s2.post(f"{HOST}/login", json={"username": "testuser3", "password": "securepass123"})
    
    # user 2 tries to get user 1's todo, MUST be 404
    res = s2.get(f"{HOST}/todos/{todo_id}")
    assert res.status_code == 404, f"Expected 404 to prevent enumeration, got {res.status_code}"
    assert res.json()["error"] == "Todo not found"
    
    # user 2 tries to update user 1's todo, MUST be 404
    res = s2.put(f"{HOST}/todos/{todo_id}", json={"title": "Hacked"})
    assert res.status_code == 404, f"Expected 404, got {res.status_code}"
    
    # user 2 tries to delete user 1's todo, MUST be 404
    res = s2.delete(f"{HOST}/todos/{todo_id}")
    assert res.status_code == 404, f"Expected 404, got {res.status_code}"
    print("PASSED")

if __name__ == "__main__":
    print("Starting server...")
    proc = start_server()
    
    try:
        # Setup: register second user first
        requests.post(f"{HOST}/register", json={"username": "testuser3", "password": "securepass123"})
        
        test_register_valid()
        test_register_invalid_username()
        test_register_short_password()
        test_register_duplicate()
        test_login_success()
        test_login_invalid()
        test_me_success()
        test_me_unauthorized()
        test_change_password()
        test_change_password_invalid_old()
        test_create_todo()
        test_create_todo_no_title()
        test_get_todos()
        test_get_todo()
        test_get_todo_not_found()
        test_update_todo()
        test_update_todo_empty_title()
        test_delete_todo()
        test_logout()
        test_todo_after_logout()
        test_cross_user_todo_not_found()
        print("\nAll tests passed!")
    finally:
        proc.terminate()
        proc.wait()
