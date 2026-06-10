#!/usr/bin/env python3
"""
Test script for Todo App API
"""

import subprocess
import time
import requests
import json
import os
import signal
import sys

# Configuration 
TEST_PORT = 8081
BASE_URL = f"http://localhost:{TEST_PORT}"

def start_server():
    """Start the server"""
    cmd = ["timeout", "60s", "python3", "app.py", "--port", str(TEST_PORT)]
    process = subprocess.Popen(cmd)
    # Give the server a moment to start
    time.sleep(2)
    return process

def stop_server(process):
    """Stop the server"""
    try:
        process.terminate()
        process.wait(timeout=5)  # Wait up to 5 seconds for graceful shutdown
    except subprocess.TimeoutExpired:
        # Force kill if not responding
        try:
            process.kill() 
            process.wait()
        except:
            pass  # Process already gone

def test_register():
    """Test registration functionality"""
    print("Testing registration...")
    
    # Clean slate: remove any previous test user
    try:
        response = requests.post(f"{BASE_URL}/login", 
                               json={"username": "testuser1", "password": "testpass123"})
        if response.status_code == 200:
            # Login successful - logout the existing user
            session_id = response.cookies.get('session_id')
            if session_id:
                requests.post(f"{BASE_URL}/logout", 
                            cookies={'session_id': session_id})
    except:
        pass  # Don't worry if login fails
    
    # Test successful registration
    response = requests.post(f"{BASE_URL}/register", 
                           json={"username": "testuser1", "password": "testpass123"})
    assert response.status_code == 201, f"Expected 201, got {response.status_code}"
    data = response.json()
    assert "id" in data, f"Expected 'id' in response, got {data}"
    assert "username" in data, f"Expected 'username' in response, got {data}"
    assert data["username"] == "testuser1"
    print("✓ Registration successful")

    # Test registration with invalid username (too short)
    response = requests.post(f"{BASE_URL}/register", 
                           json={"username": "ab", "password": "testpass123"})
    assert response.status_code == 400, f"Expected 400, got {response.status_code}"
    data = response.json()
    assert data["error"] == "Invalid username"
    print("✓ Registration with invalid username rejected")

    # Test registration with invalid username (invalid chars)
    response = requests.post(f"{BASE_URL}/register", 
                           json={"username": "test-user!", "password": "testpass123"})
    assert response.status_code == 400
    data = response.json()
    assert data["error"] == "Invalid username"
    print("✓ Registration with invalid chars rejected")

    # Test registration with weak password
    response = requests.post(f"{BASE_URL}/register", 
                           json={"username": "testuser2", "password": "weak"})
    assert response.status_code == 400
    data = response.json()
    assert data["error"] == "Password too short"
    print("✓ Registration with weak password rejected")

    # Test registration with duplicate username
    response = requests.post(f"{BASE_URL}/register", 
                           json={"username": "testuser1", "password": "differentpass123"})
    assert response.status_code == 409
    data = response.json()
    assert data["error"] == "Username already exists"
    print("✓ Duplicate username rejected")

def test_login():
    """Test login functionality"""
    print("\nTesting login...")
    
    # Test valid login
    response = requests.post(f"{BASE_URL}/login", 
                           json={"username": "testuser1", "password": "testpass123"})
    assert response.status_code == 200, f"Expected 200, got {response.status_code}: {response.text}"
    data = response.json()
    assert "id" in data, f"Expected 'id' in response, got {data}"
    assert "username" in data, f"Expected 'username' in response, got {data}"
    assert data["username"] == "testuser1"
    session_id = response.cookies.get('session_id')
    assert session_id is not None, "Expected session_id cookie"
    print("✓ Valid login successful")

    # Test invalid login (wrong password)
    response = requests.post(f"{BASE_URL}/login", 
                           json={"username": "testuser1", "password": "wrongpass"})
    assert response.status_code == 401
    data = response.json()
    assert data["error"] == "Invalid credentials"
    print("✓ Invalid login rejected")

    # Test invalid login (nonexistent user)
    response = requests.post(f"{BASE_URL}/login", 
                           json={"username": "nonexistent", "password": "anypass"})
    assert response.status_code == 401
    data = response.json()
    assert data["error"] == "Invalid credentials"
    print("✓ Nonexistent user login rejected")

def test_authentication_required_endpoints():
    """Test that protected endpoints require authentication"""
    print("\nTesting authentication required endpoints...")
    
    # Try accessing protected endpoints without cookies
    protected_endpoints = ["/me", "/password", "/todos"]
    
    # Test /me
    response = requests.get(f"{BASE_URL}/me")
    assert response.status_code == 401, f"Endpoint /me should require auth, got {response.status_code}"
    data = response.json()
    assert data["error"] == "Authentication required"
    
    # Test /password - must send correct data structure and method (PUT)
    response = requests.put(f"{BASE_URL}/password", 
                         json={"old_password": "any", "new_password": "any"})
    # This should fail with missing auth, not method not found
    assert response.status_code == 401, f"Endpoint /password should require auth, got {response.status_code}"
    data = response.json()
    assert data["error"] == "Authentication required"
    
    # Test /todos  
    response = requests.get(f"{BASE_URL}/todos")
    assert response.status_code == 401, f"Endpoint /todos should require auth, got {response.status_code}"
    data = response.json()
    assert data["error"] == "Authentication required"
    
    print("✓ Authentication required endpoints properly protected")
    
    # Log in to get a session
    login_response = requests.post(f"{BASE_URL}/login", 
                                json={"username": "testuser1", "password": "testpass123"})
    session_id = login_response.cookies.get('session_id')
    cookies = {'session_id': session_id}

    # Test accessing protected endpoints with valid session
    response = requests.get(f"{BASE_URL}/me", cookies=cookies)
    assert response.status_code == 200
    data = response.json()
    assert data["username"] == "testuser1"
    print("✓ Authenticated access allowed")

def test_password_change():
    """Test password change functionality"""
    print("\nTesting password change...")
    
    # Log in first
    login_response = requests.post(f"{BASE_URL}/login", 
                                json={"username": "testuser1", "password": "testpass123"})
    session_id = login_response.cookies.get('session_id')
    cookies = {'session_id': session_id}

    # Test changing password with correct old password
    response = requests.put(f"{BASE_URL}/password", 
                          json={"old_password": "testpass123", "new_password": "newpass456"},
                          cookies=cookies)
    assert response.status_code == 200
    print("✓ Password change successful")

    # Test that old password no longer works
    response = requests.post(f"{BASE_URL}/login", 
                           json={"username": "testuser1", "password": "testpass123"})
    assert response.status_code == 401
    print("✓ Old password no longer valid")

    # Test login with new password and change back
    response = requests.post(f"{BASE_URL}/login", 
                           json={"username": "testuser1", "password": "newpass456"})
    assert response.status_code == 200
    session2_id = response.cookies.get('session_id')
    cookies2 = {'session_id': session2_id}

    response = requests.put(f"{BASE_URL}/password", 
                          json={"old_password": "newpass456", "new_password": "testpass123"},
                          cookies=cookies2)
    assert response.status_code == 200
    print("✓ Password reverted successfully")

def test_todos():
    """Test todos functionality"""
    print("\nTesting todos...")
    
    # Log in 
    login_response = requests.post(f"{BASE_URL}/login", 
                                json={"username": "testuser1", "password": "testpass123"})
    session_id = login_response.cookies.get('session_id')
    cookies = {'session_id': session_id}

    # Test creating a todo
    response = requests.post(f"{BASE_URL}/todos", 
                           json={"title": "Test Todo", "description": "This is a test todo"},
                           cookies=cookies)
    assert response.status_code == 201
    todo_data = response.json()
    assert todo_data["title"] == "Test Todo"
    assert todo_data["description"] == "This is a test todo"
    assert todo_data["completed"] is False  # Default false
    todo_id = todo_data["id"]
    print("✓ Todo creation successful")

    # Test creating a todo with empty title (should fail)
    response = requests.post(f"{BASE_URL}/todos", 
                           json={"title": "", "description": "Should fail"},
                           cookies=cookies)
    assert response.status_code == 400
    assert response.json()["error"] == "Title is required"
    print("✓ Empty title validation works")

    # Test getting todos
    response = requests.get(f"{BASE_URL}/todos", cookies=cookies)
    assert response.status_code == 200
    todos = response.json()
    assert len(todos) >= 1
    found = False
    for todo in todos:
        if todo["id"] == todo_id:
            assert todo["title"] == "Test Todo"
            found = True
            break
    assert found, "Created todo should be in the list"
    print("✓ Get todos successful")

    # Test getting a specific todo
    response = requests.get(f"{BASE_URL}/todos/{todo_id}", cookies=cookies)
    assert response.status_code == 200
    fetched_todo = response.json()
    assert fetched_todo["id"] == todo_id
    assert fetched_todo["title"] == "Test Todo"
    print("✓ Get single todo successful")

    # Test updating todo partially
    response = requests.put(f"{BASE_URL}/todos/{todo_id}", 
                          json={"completed": True, "description": "Updated description"},
                          cookies=cookies)
    assert response.status_code == 200
    updated_data = response.json()
    assert updated_data["id"] == todo_id
    assert updated_data["completed"] is True
    assert updated_data["description"] == "Updated description"
    print("✓ Partial todo update successful")

    # Test updating with empty title (should fail)
    response = requests.put(f"{BASE_URL}/todos/{todo_id}",
                          json={"title": ""},
                          cookies=cookies)
    assert response.status_code == 400
    assert response.json()["error"] == "Title is required"
    print("✓ Update with empty title validation works")

    # Create another todo to test multi-user isolation later
    response = requests.post(f"{BASE_URL}/todos", 
                           json={"title": "Second Todo", "description": "Another test todo"},
                           cookies=cookies)
    assert response.status_code == 201
    second_todo_id = response.json()["id"]

    # Test deletion
    response = requests.delete(f"{BASE_URL}/todos/{todo_id}", cookies=cookies)
    assert response.status_code == 204
    print("✓ Todo deletion successful")

    # Test that deleted todo is gone
    response = requests.get(f"{BASE_URL}/todos/{todo_id}", cookies=cookies)
    assert response.status_code == 404
    assert response.json()["error"] == "Todo not found"
    print("✓ Deleted todo no longer exists")

def test_todos_isolation():
    """Test that one user cannot access another user's todos"""
    print("\nTesting user isolation...")
    
    # Register second user
    response = requests.post(f"{BASE_URL}/register", 
                           json={"username": "testuser2", "password": "testpass456"})
    assert response.status_code == 201

    # Log in as first user
    login_resp1 = requests.post(f"{BASE_URL}/login", 
                              json={"username": "testuser1", "password": "testpass123"})
    session1_id = login_resp1.cookies.get('session_id')
    assert session1_id is not None
    cookies1 = {'session_id': session1_id}

    # Log in as second user
    login_resp2 = requests.post(f"{BASE_URL}/login", 
                              json={"username": "testuser2", "password": "testpass456"})
    session2_id = login_resp2.cookies.get('session_id')
    assert session2_id is not None
    cookies2 = {'session_id': session2_id}

    # First user creates a private todo
    response = requests.post(f"{BASE_URL}/todos", 
                           json={"title": "Private Todo", "description": "This belongs to user1"},
                           cookies=cookies1)
    assert response.status_code == 201
    private_todo_id = response.json()["id"]

    # Second user should not be able to view first user's todo
    # (should get 404 instead of 403 to prevent enumeration)
    response = requests.get(f"{BASE_URL}/todos/{private_todo_id}", cookies=cookies2)
    assert response.status_code == 404, f"Expected 404 for cross-user access, got {response.status_code}"
    error_msg = response.json()["error"]
    assert error_msg == "Todo not found"
    print("✓ User data properly isolated")

    # Logout both users
    requests.post(f"{BASE_URL}/logout", cookies=cookies1)
    requests.post(f"{BASE_URL}/logout", cookies=cookies2)

def test_logout():
    """Test logout functionality"""
    print("\nTesting logout...")
    
    # Log in
    login_response = requests.post(f"{BASE_URL}/login",
                                json={"username": "testuser1", "password": "testpass123"})
    session_id = login_response.cookies.get('session_id')
    cookies = {'session_id': session_id}
    
    # Verify authenticated access works before logout
    response = requests.get(f"{BASE_URL}/me", cookies=cookies)
    assert response.status_code == 200
    
    # Logout
    response = requests.post(f"{BASE_URL}/logout", cookies=cookies)
    assert response.status_code == 200, f"Expected 200, got {response.status_code}"
    
    # Verify the session cookie no longer provides auth
    response = requests.get(f"{BASE_URL}/me", cookies=cookies)
    assert response.status_code == 401
    print("✓ Logout successful")

def run_all_tests():
    """Run all tests"""
    print("Starting Todo App API tests...\n")
    
    # Start server
    server_process = start_server()
    
    try:
        # Run tests
        test_register()
        test_login()
        test_authentication_required_endpoints()
        test_password_change()
        test_todos()
        test_todos_isolation()
        test_logout()

        print("\n✓ All tests passed!")
        return True
    except Exception as e:
        print(f"\n✗ Test failed: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        stop_server(server_process)

if __name__ == "__main__":
    result = run_all_tests()
    sys.exit(0 if result else 1)