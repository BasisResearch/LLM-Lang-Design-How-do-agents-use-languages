#!/usr/bin/env python3
"""
Test script for the Todo App API server.

This script starts the server on a random port and runs comprehensive tests
to ensure all endpoints work correctly.
"""

import subprocess
import sys
import time
import requests
import threading
import signal
import os

def run_tests():
    """Run comprehensive integration tests against the API server."""
    BASE_URL = "http://localhost:8080"
    session = requests.Session()
    
    print("Running tests...\n")
    
    # Test 1: POST /register - Create a user
    print("Test 1: Registering a new user...")
    register_resp = session.post(
        f"{BASE_URL}/register",
        json={"username": "testuser", "password": "password123"}
    )
    assert register_resp.status_code == 201
    user_data = register_resp.json()
    assert user_data['id'] == 1
    assert user_data['username'] == 'testuser'
    print("✓ Registration successful\n")
    
    # Test 2: POST /register - Try to register with existing username
    print("Test 2: Registering with existing username...")
    register_dup_resp = session.post(
        f"{BASE_URL}/register",
        json={"username": "testuser", "password": "password456"}
    )
    assert register_dup_resp.status_code == 409
    error_data = register_dup_resp.json()
    assert error_data['error'] == 'Username already exists'
    print("✓ Duplicate username rejected correctly\n")
    
    # Test 3: POST /register - Invalid username (too short)
    print("Test 3: Invalid username (too short)...")
    register_short_resp = session.post(
        f"{BASE_URL}/register",
        json={"username": "ab", "password": "password123"}
    )
    assert register_short_resp.status_code == 400
    assert register_short_resp.json()['error'] == 'Invalid username'
    print("✓ Short username rejected correctly\n")
    
    # Test 4: POST /register - Invalid username (invalid chars)
    print("Test 4: Invalid username (special characters)...")
    register_special_resp = session.post(
        f"{BASE_URL}/register",
        json={"username": "test@user", "password": "password123"}
    )
    assert register_special_resp.status_code == 400
    assert register_special_resp.json()['error'] == 'Invalid username'
    print("✓ Special character username rejected correctly\n")
    
    # Test 5: POST /register - Password too short
    print("Test 5: Password too short...")
    register_short_pass_resp = session.post(
        f"{BASE_URL}/register",
        json={"username": "testuser2", "password": "pass"}
    )
    assert register_short_pass_resp.status_code == 400
    assert register_short_pass_resp.json()['error'] == 'Password too short'
    print("✓ Short password rejected correctly\n")
    
    # Test 6: POST /login - Successful login
    print("Test 6: Login with valid credentials...")
    login_resp = session.post(
        f"{BASE_URL}/login",
        json={"username": "testuser", "password": "password123"}
    )
    assert login_resp.status_code == 200
    login_data = login_resp.json()
    assert login_data['id'] == 1
    assert login_data['username'] == 'testuser'
    session_cookies = session.cookies.get_dict()
    assert 'session_id' in session_cookies
    print("✓ Login successful\n")
    
    # Test 7: GET /me - Authenticated user info
    print("Test 7: Get user info with valid session...")
    me_resp = session.get(f"{BASE_URL}/me")
    assert me_resp.status_code == 200
    me_data = me_resp.json()
    assert me_data['id'] == 1
    assert me_data['username'] == 'testuser'
    print("✓ User info retrieved successfully\n")
    
    # Test 8: GET /me - Without auth should fail
    print("Test 8: Get user info without auth...")
    unauth_session = requests.Session()
    unauth_me_resp = unauth_session.get(f"{BASE_URL}/me")
    assert unauth_me_resp.status_code == 401
    assert unauth_me_resp.json()['error'] == 'Authentication required'
    print("✓ Unauthorized request correctly blocked\n")
    
    # Test 9: POST /todos - Create a todo
    print("Test 9: Create a new todo...")
    todo_resp = session.post(
        f"{BASE_URL}/todos",
        json={"title": "First todo", "description": "My first important task"}
    )
    assert todo_resp.status_code == 201
    todo_data = todo_resp.json()
    assert todo_data['id'] == 1
    assert todo_data['title'] == 'First todo'
    assert todo_data['description'] == 'My first important task'
    assert todo_data['completed'] == False
    created_at = todo_data['created_at']
    updated_at = todo_data['updated_at']
    print("✓ Todo created successfully\n")
    
    # Test 10: POST /todos - Title required validation
    print("Test 10: Create todo with missing title...")
    bad_todo_resp = session.post(
        f"{BASE_URL}/todos",
        json={"description": "Missing title"}
    )
    assert bad_todo_resp.status_code == 400
    assert bad_todo_resp.json()['error'] == 'Title is required'
    print("✓ Empty/missing title correctly rejected\n")
    
    # Test 11: POST /todos - Empty title validation
    print("Test 11: Create todo with empty title...")
    empty_title_resp = session.post(
        f"{BASE_URL}/todos",
        json={"title": "", "description": "Empty title"}
    )
    assert empty_title_resp.status_code == 400
    assert empty_title_resp.json()['error'] == 'Title is required'
    print("✓ Empty title correctly rejected\n")
    
    # Test 12: GET /todos - Get all user's todos
    print("Test 12: Get all todos for user...")
    todos_resp = session.get(f"{BASE_URL}/todos")
    assert todos_resp.status_code == 200
    todos_list = todos_resp.json()
    assert len(todos_list) == 1
    assert todos_list[0]['id'] == 1
    assert todos_list[0]['title'] == 'First todo'
    print("✓ Todos list retrieved successfully\n")
    
    # Test 13: GET /todos/:id - Get specific todo
    print("Test 13: Get specific todo by ID...")
    single_todo_resp = session.get(f"{BASE_URL}/todos/1")
    assert single_todo_resp.status_code == 200
    single_todo = single_todo_resp.json()
    assert single_todo['id'] == 1
    assert single_todo['title'] == 'First todo'
    print("✓ Specific todo retrieved successfully\n")
    
    # Test 14: GET /todos/:id - Non-existent todo
    print("Test 14: Get non-existent todo...")
    nonexist_todo_resp = session.get(f"{BASE_URL}/todos/999")
    assert nonexist_todo_resp.status_code == 404
    assert nonexist_todo_resp.json()['error'] == 'Todo not found'
    print("✓ Non-existent todo correctly returns 404\n")
    
    # Test 15: PUT /password - Change password with correct old password
    print("Test 15: Change password with valid old password...")
    change_pass_resp = session.put(
        f"{BASE_URL}/password",
        json={"old_password": "password123", "new_password": "newpassword456"}
    )
    assert change_pass_resp.status_code == 200
    print("✓ Password changed successfully\n")
    
    # Test 16: PUT /password - Try with wrong old password
    print("Test 16: Change password with invalid old password...")
    bad_pass_resp = session.put(
        f"{BASE_URL}/password",
        json={"old_password": "wrongpassword", "new_password": "anotherpass"}
    )
    assert bad_pass_resp.status_code == 401
    assert bad_pass_resp.json()['error'] == 'Invalid credentials'
    print("✓ Wrong password correctly rejected\n")
    
    # Test 17: PUT /password - New password too short
    print("Test 17: Change password with short new password...")
    short_pass_resp = session.put(
        f"{BASE_URL}/password",
        json={"old_password": "newpassword456", "new_password": "short"}
    )
    assert short_pass_resp.status_code == 400
    assert short_pass_resp.json()['error'] == 'Password too short'
    print("✓ Short new password correctly rejected\n")
    
    # Test 18: Login again with new password
    print("Test 18: Login with new password...")
    session2 = requests.Session()
    new_pass_login_resp = session2.post(
        f"{BASE_URL}/login",
        json={"username": "testuser", "password": "newpassword456"}
    )
    assert new_pass_login_resp.status_code == 200
    print("✓ Login with new password successful\n")
    
    # Test 19: PUT /todos/:id - Update todo
    print("Test 19: Update a todo partially...")
    update_todo_resp = session2.put(
        f"{BASE_URL}/todos/1",
        json={"title": "Updated todo", "completed": True}
    )
    assert update_todo_resp.status_code == 200
    updated_todo = update_todo_resp.json()
    assert updated_todo['id'] == 1
    assert updated_todo['title'] == 'Updated todo'
    assert updated_todo['completed'] == True
    assert updated_todo['description'] == 'My first important task'  # Should remain unchanged
    print("✓ Todo updated successfully\n")
    
    # Test 20: PUT /todos/:id - Title required validation in update
    print("Test 20: Update todo with empty title...")
    bad_update_resp = session2.put(
        f"{BASE_URL}/todos/1",
        json={"title": ""}
    )
    assert bad_update_resp.status_code == 400
    assert bad_update_resp.json()['error'] == 'Title is required'
    print("✓ Empty title update correctly rejected\n")
    
    # Test 21: DELETE /todos/:id - Delete todo
    print("Test 21: Delete a todo...")
    delete_resp = session2.delete(f"{BASE_URL}/todos/1")
    assert delete_resp.status_code == 204
    assert delete_resp.text == ''  # No body returned
    print("✓ Todo deleted successfully\n")
    
    # Test 22: Verify todo is gone after deletion
    print("Test 22: Verify deleted todo does not exist...")
    deleted_todo_resp = session2.get(f"{BASE_URL}/todos/1")
    assert deleted_todo_resp.status_code == 404
    print("✓ Deleted todo no longer accessible\n")
    
    # Test 23: POST /logout
    print("Test 23: Logout...")
    logout_resp = session2.post(f"{BASE_URL}/logout")
    assert logout_resp.status_code == 200
    print("✓ Logout successful\n")
    
    # Test 24: Verify session invalidated after logout
    print("Test 24: Verify session invalid after logout...")
    post_logout_resp = session2.get(f"{BASE_URL}/me")
    assert post_logout_resp.status_code == 401
    print("✓ Session correctly invalidated after logout\n")
    
    # Test 25: POST /logout without authentication
    print("Test 25: Logout without authentication...")
    unauth_session2 = requests.Session()
    logout_unauth_resp = unauth_session2.post(f"{BASE_URL}/logout")
    assert logout_unauth_resp.status_code == 401
    print("✓ Logout without auth correctly returns 401\n")
    
    print("🎉 All tests passed! API implementation is working correctly.")
    

def main():
    """Run the server and tests."""
    # Use a specific test port
    port = 8080
    
    # Start the server as subprocess
    server_cmd = ["python3", "app.py", "--port", str(port)]
    print(f"Starting server with command: {' '.join(server_cmd)}")
    server_process = subprocess.Popen(server_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    
    # Give the server some time to start
    time.sleep(2)
    
    try:
        print("Waiting for server to be ready...")
        # Wait a bit more to ensure the server is ready
        tries = 0
        while tries < 20:
            try:
                resp = requests.get(f"http://localhost:{port}/", timeout=5)
                break
            except requests.exceptions.ConnectionError:
                time.sleep(0.5)
                tries += 1
        
        if tries >= 20:
            raise Exception("Server did not start in time")
        
        print(f"Server is running on port {port}. Starting tests...")
        time.sleep(1)  # Brief additional wait for full readiness
        run_tests()
        
    finally:
        # Terminate the server process
        print("\nStopping server...")
        server_process.terminate()
        try:
            server_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server_process.kill()

if __name__ == "__main__":
    main()