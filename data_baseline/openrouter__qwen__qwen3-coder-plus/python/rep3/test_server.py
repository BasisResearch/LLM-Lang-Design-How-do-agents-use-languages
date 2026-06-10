#!/usr/bin/env python3
"""
Test script for the Todo app server.
This script tests all endpoints to ensure they're functioning properly.
"""

import subprocess
import time
import requests
import json
import os
import signal


def wait_for_server(url, timeout=30):
    """Wait for server to be ready."""
    start_time = time.time() 
    while time.time() - start_time < timeout:
        try:
            response = requests.get(f"http://localhost:8000/me", allow_redirects=False)
            # Server might return 401 (not 404) if it's running
            if response.status_code in [200, 401]:
                return True
        except requests.exceptions.ConnectionError:
            pass
        time.sleep(0.5)
    return False


def reset_cookies(session, initial_cookies=None):
    """Helper to keep existing session cookies but add new ones."""
    if initial_cookies is None:
        initial_cookies = {}
    
    # Copy over existing cookies from session
    for cookie in session.cookies:
        initial_cookies[cookie.name] = cookie.value
    session.cookies.clear()
    session.cookies.update(initial_cookies)
    return session


def main():
    print("Starting Todo App server tests...")
    
    # Start the server
    process = subprocess.Popen(['python3', 'server.py', '--port', '8000'])
    
    # Wait for server to be reachable
    print("Waiting for server to start...")
    if not wait_for_server("http://localhost:8000"):
        print("ERROR: Server failed to start")
        process.terminate()
        return
    
    print("Server is running!")
    
    # Create a session to maintain cookies
    session = requests.Session()
    
    print("\n=== Testing REGISTER Endpoint ===")
    # Test register new user
    res = session.post("http://localhost:8000/register", 
                      json={"username": "testuser", "password": "password123"})
    assert res.status_code == 201
    assert res.json()["username"] == "testuser"
    print("✓ Register successful")
    
    # Test register with invalid username (too short)
    res = session.post("http://localhost:8000/register", 
                      json={"username": "ab", "password": "password123"})
    assert res.status_code == 400
    assert "Invalid username" in res.json()["error"]
    print("✓ Invalid username validation works")
    
    # Test register with invalid username (invalid characters)
    res = session.post("http://localhost:8000/register", 
                      json={"username": "test@user", "password": "password123"})
    assert res.status_code == 400
    assert "Invalid username" in res.json()["error"]
    print("✓ Invalid character username validation works")
    
    # Test register with duplicate username
    res = session.post("http://localhost:8000/register", 
                      json={"username": "testuser", "password": "password123"})
    assert res.status_code == 409
    assert "Username already exists" in res.json()["error"]
    print("✓ Duplicate username validation works")
    
    # Test register with short password
    res = session.post("http://localhost:8000/register", 
                      json={"username": "testuser2", "password": "pass"})
    assert res.status_code == 400
    assert "Password too short" in res.json()["error"]
    print("✓ Short password validation works")
    
    print("\n=== Testing LOGIN Endpoint ===")
    # Clear session to test new login properly
    session.cookies.clear()
    # Test successful login
    res = session.post("http://localhost:8000/login", 
                      json={"username": "testuser", "password": "password123"})
    assert res.status_code == 200
    assert res.json()["username"] == "testuser"
    assert "session_id" in [c.name for c in session.cookies]
    print("✓ Login successful")
    
    # Test incorrect login
    session.cookies.clear()  # Clear session to start fresh
    s = requests.Session()
    res = s.post("http://localhost:8000/login", 
                 json={"username": "testuser", "password": "wrongpassword"})
    assert res.status_code == 401
    assert "Invalid credentials" in res.json()["error"]
    print("✓ Incorrect login validation works")
    
    # Test non-existent user login
    res = s.post("http://localhost:8000/login", 
                 json={"username": "nonexistent", "password": "password123"})
    assert res.status_code == 401
    assert "Invalid credentials" in res.json()["error"]
    print("✓ Non-existent user login validation works")
    
    print("\n=== Testing PROTECTED ENDPOINTS without Auth ===")
    # Now test authenticated endpoints WITHOUT proper auth
    noauth_session = requests.Session()
    
    # Get me without auth
    res = noauth_session.get("http://localhost:8000/me")
    assert res.status_code == 401
    assert "Authentication required" in res.json()["error"]
    print("✓ Get '/me' without auth correctly returns 401")
    
    # Create todo without auth
    res = noauth_session.post("http://localhost:8000/todos", 
                             json={"title": "Test todo", "description": "A test todo"})
    assert res.status_code == 401
    assert "Authentication required" in res.json()["error"]
    print("✓ Create '/todos' without auth correctly returns 401")
    
    print("\n=== Testing ME Endpoint ===")
    # Test Get Me
    res = session.get("http://localhost:8000/me")
    assert res.status_code == 200
    assert res.json()["username"] == "testuser"
    print("✓ Get '/me' successful")
    
    print("\n=== Testing TODO Endpoints ===")
    # Create first todo
    res = session.post("http://localhost:8000/todos", 
                       json={"title": "First todo", "description": "My first task"})
    assert res.status_code == 201
    assert res.json()["title"] == "First todo"
    todo1_id = res.json()["id"]
    print("✓ Created first todo")
    
    # Create another todo
    res = session.post("http://localhost:8000/todos", 
                       json={"title": "Second todo", "description": ""})
    assert res.status_code == 201
    assert res.json()["title"] == "Second todo"
    assert res.json()["description"] == ""
    todo2_id = res.json()["id"]
    print("✓ Created second todo")
    
    # Create todo without title (should fail)
    res = session.post("http://localhost:8000/todos", 
                       json={"description": "todo without title"})
    assert res.status_code == 400
    assert "Title is required" in res.json()["error"]
    print("✓ Validation of missing title works")
    
    # Get all todos
    res = session.get("http://localhost:8000/todos")
    assert res.status_code == 200
    todos = res.json()
    assert len(todos) == 2
    assert todos[0]["id"] <= todos[1]["id"]  # Ensure correct ordering by ID
    print("✓ Get all todos successful")
    
    # Get specific todo
    res = session.get(f"http://localhost:8000/todos/{todo1_id}")
    assert res.status_code == 200
    assert res.json()["id"] == todo1_id
    assert res.json()["title"] == "First todo"
    print("✓ Get specific todo successful")
    
    # Test get non-existent todo
    res = session.get("http://localhost:8000/todos/9999")
    assert res.status_code == 404
    assert "Todo not found" in res.json()["error"]
    print("✓ Get non-existent todo returns 404")
    
    # Update todo partially
    res = session.put(f"http://localhost:8000/todos/{todo1_id}", 
                     json={"completed": True})
    assert res.status_code == 200
    assert res.json()["completed"] == True
    print("✓ Partially update todo successful")
    
    # Verify update worked
    res = session.get(f"http://localhost:8000/todos/{todo1_id}")
    assert res.json()["completed"] == True
    print("✓ Updated state confirmed")
    
    # Test invalid update (empty title)
    res = session.put(f"http://localhost:8000/todos/{todo1_id}", 
                     json={"title": ""})
    assert res.status_code == 400
    assert "Title is required" in res.json()["error"]
    print("✓ Update with empty title validation works")
    
    # Test updating another property
    res = session.put(f"http://localhost:8000/todos/{todo1_id}", 
                     json={"title": "Updated first todo", "description": "Updated description"})
    assert res.status_code == 200
    assert res.json()["title"] == "Updated first todo"
    assert res.json()["description"] == "Updated description"
    print("✓ Full update todo successful")
    
    # Try to access another user's todo (after creating one for that user)
    # For our simple case, we'll test that the same user can't access non-existent todo of someone else's ID space
    # but instead let's confirm user isolation via a different approach
    # First logout
    res = session.post("http://localhost:8000/logout")
    assert res.status_code == 200
    print("✓ Logout successful")
    
    # Clear cookies between sessions
    session.cookies.clear()
    
    # Now register another user
    res = session.post("http://localhost:8000/register", 
                      json={"username": "otheruser", "password": "password123"})
    assert res.status_code == 201
    print("✓ Other user registration successful")
    
    # Login with other user
    res = session.post("http://localhost:8000/login", 
                      json={"username": "otheruser", "password": "password123"})
    assert res.status_code == 200
    print("✓ Other user login successful")
    
    # Try to access the first user's todo using the other user's session
    res = session.get(f"http://localhost:8000/todos/{todo1_id}")
    # This should return 404 because the other user doesn't own this todo
    assert res.status_code == 404
    assert "Todo not found" in res.json()["error"]
    print("✓ Unauthorized access to other user's todo returns 404")
    
    # Create a todo as the other user
    res = session.post("http://localhost:8000/todos", 
                       json={"title": "Other user todo", "description": "Owned by other user"})
    assert res.status_code == 201
    todo_other_id = res.json()["id"]
    print("✓ Created a todo for other user")
    
    # Update the other user's todo
    res = session.put(f"http://localhost:8000/todos/{todo_other_id}", 
                     json={"title": "Updated other's todo", "completed": True})
    assert res.status_code == 200
    assert res.json()["title"] == "Updated other's todo"
    assert res.json()["completed"] == True
    print("✓ Other user can update their own todo")
    
    print("\n=== Testing PASSWORD Change ===")
    # Test change password with old password verification
    res = session.put("http://localhost:8000/password", 
                     json={"old_password": "password123", 
                           "new_password": "newpassword456"})
    assert res.status_code == 200
    print("✓ Password change successful")
    
    # Logout first
    res = session.post("http://localhost:8000/logout")
    assert res.status_code == 200
    
    # Now try logging in with new password
    session.cookies.clear()
    res = session.post("http://localhost:8000/login", 
                      json={"username": "otheruser", "password": "newpassword456"})
    assert res.status_code == 200
    print("✓ Login with new password successful")
    
    # Try changing password with wrong old password
    res = session.put("http://localhost:8000/password", 
                     json={"old_password": "wrongpassword", 
                           "new_password": "anotherpassword"})
    assert res.status_code == 401
    assert "Invalid credentials" in res.json()["error"]
    print("✓ Password change with wrong current password fails")
    
    # Try changing to short password
    res = session.put("http://localhost:8000/password", 
                     json={"old_password": "newpassword456", 
                           "new_password": "short"})
    assert res.status_code == 400
    assert "Password too short" in res.json()["error"]
    print("✓ Password change to short password fails")
    
    print("\n=== Testing DELETE Todo ===")
    # Create a todo to delete
    res = session.post("http://localhost:8000/todos", 
                       json={"title": "ToDelete todo", "description": "Will be deleted"})
    assert res.status_code == 201
    delete_todo_id = res.json()["id"]
    
    # Delete that todo
    res = session.delete(f"http://localhost:8000/todos/{delete_todo_id}")
    assert res.status_code == 204  # 204 means no content per spec
    print("✓ Delete todo successful")
    
    # Confirm deletion
    res = session.get(f"http://localhost:8000/todos/{delete_todo_id}")
    assert res.status_code == 404
    print("✓ Deleted todo confirmed gone")
    
    # Try to delete non-existent todo
    res = session.delete("http://localhost:8000/todos/9999")
    assert res.status_code == 404
    print("✓ Delete non-existent todo returns 404")
    
    print("\n=== Final Validation: All Core Functionality Works ===")
    
    # Shutdown server
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
    
    print("\n✓ ALL TESTS PASSED! Server implementation is working correctly.")


if __name__ == "__main__":
    main()