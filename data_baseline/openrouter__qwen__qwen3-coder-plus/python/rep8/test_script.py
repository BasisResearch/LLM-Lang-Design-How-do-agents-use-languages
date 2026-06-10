#!/usr/bin/env python3
"""
Test script for Todo App API server
Verifies all endpoints work correctly
"""

import subprocess
import time
import signal
import requests
import json
import threading


def run_test():
    base_url = "http://localhost:8765"
    print(f"Testing server at {base_url}")
    
    # Test POST /register
    print("Testing /register endpoint...")
    
    # Register a new user
    register_resp = requests.post(
        f"{base_url}/register",
        json={"username": "testuser", "password": "secure123"}
    )
    assert register_resp.status_code == 201, f"Expected 201, got {register_resp.status_code}: {register_resp.text}"
    
    data = register_resp.json()
    assert "id" in data
    assert data["username"] == "testuser"
    print("✓ Register successful")
    
    # Try registering duplicate username
    dup_resp = requests.post(
        f"{base_url}/register",
        json={"username": "testuser", "password": "otherpass"}
    )
    assert dup_resp.status_code == 409, f"Expected 409, got {dup_resp.status_code}: {dup_resp.text}"
    print("✓ Duplicate username properly rejected")
    
    # Test login
    print("Testing /login endpoint...")
    login_resp = requests.post(
        f"{base_url}/login",
        json={"username": "testuser", "password": "secure123"}
    )
    assert login_resp.status_code == 200, f"Expected 200, got {login_resp.status_code}: {login_resp.text}"
    assert "session_id" in login_resp.cookies
    print("✓ Login successful")
    
    # Get session cookie for future requests
    session = requests.Session()
    session.cookies.update(login_resp.cookies)
    
    # Test GET /me
    print("Testing /me endpoint...")
    me_resp = session.get(f"{base_url}/me")
    assert me_resp.status_code == 200, f"Expected 200, got {me_resp.status_code}: {me_resp.text}"
    me_data = me_resp.json()
    assert me_data["username"] == "testuser"
    print("✓ Me endpoint successful")
    
    # Test access without auth
    print("Testing auth requirement...")
    unauth_resp = requests.get(f"{base_url}/me")
    assert unauth_resp.status_code == 401, f"Expected 401, got {unauth_resp.status_code}: {unauth_resp.text}"
    print("✓ Authentication properly required")
    
    # Test PUT /password
    print("Testing /password endpoint...")
    pass_resp = session.put(
        f"{base_url}/password",
        json={"old_password": "secure123", "new_password": "newpassword123"}
    )
    assert pass_resp.status_code == 200, f"Expected 200, got {pass_resp.status_code}: {pass_resp.text}"
    print("✓ Password change successful")
    
    # Test logging in with new password
    login_new_resp = requests.post(
        f"{base_url}/login",
        json={"username": "testuser", "password": "newpassword123"}
    )
    assert login_new_resp.status_code == 200, f"Expected 200, got {login_new_resp.status_code}: {login_new_resp.text}"
    print("✓ Login with new password successful")
    
    # Refresh session with new login
    new_session = requests.Session()
    new_session.cookies.update(login_new_resp.cookies)
    
    # Test POST /todos
    print("Testing /todos endpoint (creation)...")
    todo_resp = new_session.post(
        f"{base_url}/todos",
        json={"title": "Test Todo", "description": "A sample todo item"}
    )
    assert todo_resp.status_code == 201, f"Expected 201, got {todo_resp.status_code}: {todo_resp.text}"
    todo_data = todo_resp.json()
    assert "id" in todo_data
    assert todo_data["title"] == "Test Todo"
    assert todo_data["completed"] is False
    assert "created_at" in todo_data
    assert "updated_at" in todo_data
    print("✓ Todo creation successful")
    
    # Save the created todo ID
    todo_id = todo_data["id"]
    
    # Test GET /todos (list)
    print("Testing /todos endpoint (list)...")
    todos_resp = new_session.get(f"{base_url}/todos")
    assert todos_resp.status_code == 200, f"Expected 200, got {todos_resp.status_code}: {todos_resp.text}"
    todos_list = todos_resp.json()
    assert len(todos_list) == 1
    assert todos_list[0]["id"] == todo_id
    print("✓ Todo listing successful")
    
    # Test GET /todos/:id
    print("Testing /todos/{id} endpoint...")
    single_todo_resp = new_session.get(f"{base_url}/todos/{todo_id}")
    assert single_todo_resp.status_code == 200, f"Expected 200, got {single_todo_resp.status_code}: {single_todo_resp.text}"
    single_todo = single_todo_resp.json()
    assert single_todo["id"] == todo_id
    assert single_todo["title"] == "Test Todo"
    print("✓ Get specific todo successful")
    
    # Test unauthorized access to someone else's todo (if existed)
    # First create a different user
    reg_resp2 = requests.post(
        f"{base_url}/register",
        json={"username": "differentuser", "password": "diffpass123"}
    )
    assert reg_resp2.status_code == 201, f"Expected 201, got {reg_resp2.status_code}: {reg_resp2.text}"
    
    # Login as different user
    diff_login = requests.post(
        f"{base_url}/login",
        json={"username": "differentuser", "password": "diffpass123"}
    )
    diff_session = requests.Session()
    diff_session.cookies.update(diff_login.cookies)
    assert diff_login.status_code == 200, f"Expected 200, got {diff_login.status_code}: {diff_login.text}"
    
    # Try to access user1's todo
    forbidden_resp = diff_session.get(f"{base_url}/todos/{todo_id}")
    assert forbidden_resp.status_code == 404, f"Expected 404, got {forbidden_resp.status_code}: {forbidden_resp.text}"
    print("✓ Different user cannot access others' todos")
    
    # Now update the todo
    print("Testing /todos/{id} endpoint (update)...")
    update_resp = new_session.put(
        f"{base_url}/todos/{todo_id}",
        json={"title": "Updated Title", "completed": True}
    )
    assert update_resp.status_code == 200, f"Expected 200, got {update_resp.status_code}: {update_resp.text}"
    updated_todo = update_resp.json()
    assert updated_todo["title"] == "Updated Title"
    assert updated_todo["completed"] is True
    # The timestamps should differ slightly due to updates
    print("✓ Todo update successful")
    
    # Test validation error (empty title)
    bad_update_resp = new_session.put(
        f"{base_url}/todos/{todo_id}",
        json={"title": ""}
    )
    assert bad_update_resp.status_code == 400, f"Expected 400, got {bad_update_resp.status_code}: {bad_update_resp.text}"
    print("✓ Empty title validation works")
    
    # Test DELETE /todos/:id
    print("Testing DELETE /todos/{id} endpoint...")
    delete_resp = new_session.delete(f"{base_url}/todos/{todo_id}")
    assert delete_resp.status_code == 204, f"Expected 204, got {delete_resp.status_code}: {delete_resp.text}"
    
    # Confirm the todo is gone
    get_deleted_resp = new_session.get(f"{base_url}/todos/{todo_id}")
    assert get_deleted_resp.status_code == 404, f"Expected 404, got {get_deleted_resp.status_code}: {get_deleted_resp.text}"
    print("✓ Todo deletion successful")
    
    # Test logout
    print("Testing /logout endpoint...")
    logout_resp = new_session.post(f"{base_url}/logout")
    assert logout_resp.status_code == 200, f"Expected 200, got {logout_resp.status_code}: {logout_resp.text}"
    
    # Confirm log out worked by trying to access protected resource
    logged_out_resp = new_session.get(f"{base_url}/me")
    assert logged_out_resp.status_code == 401, f"Expected 401 after logout, got {logged_out_resp.status_code}: {logged_out_resp.text}"
    print("✓ Logout successful")
    
    # Test edge cases
    
    # Register with invalid username
    bad_reg_resp = requests.post(
        f"{base_url}/register",
        json={"username": "ab", "password": "password123"}
    )
    assert bad_reg_resp.status_code == 400, f"Expected 400, got {bad_reg_resp.status_code}: {bad_reg_resp.text}"
    
    bad_reg_resp2 = requests.post(
        f"{base_url}/register",
        json={"username": "validname", "password": "short"}
    )
    assert bad_reg_resp2.status_code == 400, f"Expected 400, got {bad_reg_resp2.status_code}: {bad_reg_resp2.text}"
    print("✓ Validation of inputs correct")
    
    print("All tests passed! ✅")


def start_server():
    # Start the server as a subprocess
    proc = subprocess.Popen(['python3', 'server.py', '--port', '8765'])
    # Wait for a moment to allow the server to start
    time.sleep(2)
    return proc


if __name__ == "__main__":
    print("Starting test script...")
    
    # Start the server process
    server_process = start_server()
    
    try:
        # Give the server a moment to start up
        time.sleep(2)
        print("Server started. Running tests...")
        
        # Wait a bit more for the server to be ready
        time.sleep(1)
        
        # Run the test
        run_test()
        
        print("\n🎉 All tests passed! Server is working correctly.")
    
    except Exception as e:
        print(f"\n❌ Test failed with error: {e}")
        raise
    
    finally:
        # Cleanly shut down the server
        print("\nShutting down server...")
        server_process.terminate()
        server_process.wait()
        print("Server terminated.")