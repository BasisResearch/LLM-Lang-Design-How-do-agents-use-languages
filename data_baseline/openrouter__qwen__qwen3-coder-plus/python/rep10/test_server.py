#!/usr/bin/env python3
import subprocess
import time
import requests
import json
import threading
import os

def start_server(port=8001):
    """Start the server in a separate process"""
    server_process = subprocess.Popen(['python3', 'app.py', '--port', str(port)])
    
    # Give the server a moment to start
    time.sleep(2)
    return server_process

def stop_server(process):
    """Stop the server process"""
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()

def test_register(server_port=8001):
    print("Testing POST /register...")
    
    # Test successful registration
    response = requests.post(f'http://localhost:{server_port}/register', 
                           json={'username': 'testuser', 'password': 'password123'})
    assert response.status_code == 201
    user_data = response.json()
    assert 'id' in user_data and 'username' in user_data
    assert user_data['username'] == 'testuser'
    print("✓ Registration successful")

    # Test registration with existing username
    response = requests.post(f'http://localhost:{server_port}/register', 
                           json={'username': 'testuser', 'password': 'password123'})
    assert response.status_code == 409
    assert 'error' in response.json()
    print("✓ Duplicate username rejected")

    # Test invalid username
    response = requests.post(f'http://localhost:{server_port}/register', 
                           json={'username': 'ab', 'password': 'password123'})
    assert response.status_code == 400
    print("✓ Invalid username rejected")

    # Test too short password
    response = requests.post(f'http://localhost:{server_port}/register', 
                           json={'username': 'validuser', 'password': 'pass'})
    assert response.status_code == 400
    print("✓ Short password rejected")

def test_login(server_port=8001):
    print("Testing POST /login...")
    
    # Test successful login
    response = requests.post(f'http://localhost:{server_port}/login', 
                           json={'username': 'testuser', 'password': 'password123'})
    assert response.status_code == 200
    user_data = response.json()
    assert 'id' in user_data and 'username' in user_data
    assert user_data['username'] == 'testuser'
    cookies = {'session_id': response.cookies['session_id']}
    print("✓ Login successful")
    
    # Test invalid credentials
    response = requests.post(f'http://localhost:{server_port}/login', 
                           json={'username': 'testuser', 'password': 'wrongpass'})
    assert response.status_code == 401
    print("✓ Invalid credentials rejected")
    
    return cookies

def test_auth_required_endpoints(server_port=8001):
    print("Testing auth-requiring endpoints without authentication...")
    
    # Try protected endpoints without auth
    response = requests.get(f'http://localhost:{server_port}/me')
    assert response.status_code == 401
    print("✓ GET /me without auth properly 401s")
    
    response = requests.put(f'http://localhost:{server_port}/password', json={'old_password': 'old', 'new_password': 'newpass'})
    assert response.status_code == 401
    print("✓ PUT /password without auth properly 401s")
    
    response = requests.get(f'http://localhost:{server_port}/todos')
    assert response.status_code == 401
    print("✓ GET /todos without auth properly 401s")

def test_authenticated_operations(cookies, server_port=8001):
    print("Testing operations with authentication...")

    # Test GET /me
    response = requests.get(f'http://localhost:{server_port}/me', cookies=cookies)
    assert response.status_code == 200
    user_data = response.json()
    assert user_data['username'] == 'testuser'
    print("✓ GET /me works with auth")

    # Test creating a todo
    response = requests.post(f'http://localhost:{server_port}/todos', 
                            cookies=cookies,
                            json={'title': 'My First Todo', 'description': 'A simple task'})
    assert response.status_code == 201
    todo_data = response.json()
    assert 'id' in todo_data and todo_data['title'] == 'My First Todo'
    assert not todo_data['completed']  # Should default to false
    todo_id = todo_data['id']
    print("✓ Creating todo successful")

    # Test creating a todo with empty title (should fail)
    response = requests.post(f'http://localhost:{server_port}/todos', 
                            cookies=cookies,
                            json={'title': '', 'description': 'No title'})
    assert response.status_code == 400
    print("✓ Empty title in todo creation properly rejected")

    # Test GET /todos
    response = requests.get(f'http://localhost:{server_port}/todos', cookies=cookies)
    assert response.status_code == 200
    todos = response.json()
    assert len(todos) == 1
    assert todos[0]['title'] == 'My First Todo'
    print("✓ GET /todos lists the created todo")

    # Test GET /todos/:id
    response = requests.get(f'http://localhost:{server_port}/todos/{todo_id}', cookies=cookies)
    assert response.status_code == 200
    fetched_todo = response.json()
    assert fetched_todo['title'] == 'My First Todo'
    print("✓ GET /todos/{id} retrieves the correct todo")

    # Test non-existent TODO access
    response = requests.get(f'http://localhost:{server_port}/todos/9999', cookies=cookies)
    assert response.status_code == 404
    print("✓ Access to non-existent todo properly 404s")

    # Test PUT /todos/:id (update)
    response = requests.put(f'http://localhost:{server_port}/todos/{todo_id}', 
                           cookies=cookies,
                           json={'completed': True})
    assert response.status_code == 200
    updated_todo = response.json()
    assert updated_todo['completed'] == True
    print("✓ Partial update (completion) successful")

    # Another update - change title
    response = requests.put(f'http://localhost:{server_port}/todos/{todo_id}', 
                           cookies=cookies,
                           json={'title': 'Updated Todo Title'})
    assert response.status_code == 200
    updated_todo = response.json()
    assert updated_todo['title'] == 'Updated Todo Title'
    assert updated_todo['completed'] == True  # Still completed from before
    print("✓ Partial update (title) successful")

    # Test attempting to update with empty title
    response = requests.put(f'http://localhost:{server_port}/todos/{todo_id}', 
                           cookies=cookies,
                           json={'title': ''})
    assert response.status_code == 400
    print("✓ Attempted update with empty title properly rejected")

    # Test POST /logout
    response = requests.post(f'http://localhost:{server_port}/logout', cookies=cookies)
    assert response.status_code == 200
    print("✓ Logout successful")

    # Now the session is expired, should fail
    response = requests.get(f'http://localhost:{server_port}/me', cookies=cookies)
    assert response.status_code == 401
    print("✓ Auth tokens invalidated after logout")

def test_change_password(cookies_after_reauth, server_port=8001):
    print("Testing PUT /password...")
    
    # Re-authenticate to get a fresh session
    auth_response = requests.post(f'http://localhost:{server_port}/login',
                                json={'username': 'testuser', 'password': 'password123'})
    assert auth_response.status_code == 200
    fresh_cookies = {'session_id': auth_response.cookies['session_id']}

    # Test changing password
    response = requests.put(f'http://localhost:{server_port}/password',
                           cookies=fresh_cookies,
                           json={'old_password': 'password123', 'new_password': 'newpassword456'})
    assert response.status_code == 200
    print("✓ Password successfully changed")

    # Test with wrong old password
    response = requests.put(f'http://localhost:{server_port}/password',
                           cookies=fresh_cookies,
                           json={'old_password': 'wrongpass', 'new_password': 'anotherpass789'})
    assert response.status_code == 401
    print("✓ Wrong old password properly rejected")

    # Login with new password should work
    response = requests.post(f'http://localhost:{server_port}/login',
                           json={'username': 'testuser', 'password': 'newpassword456'})
    assert response.status_code == 200
    new_session_cookies = {'session_id': response.cookies['session_id']}
    print("✓ New password accepted during login")

def test_delete_todo(cookies_after_reauth, server_port=8001):
    print("Testing DELETE /todos/:id...")
    
    # Re-authenticate with updated password
    auth_response = requests.post(f'http://localhost:{server_port}/login',
                                json={'username': 'testuser', 'password': 'newpassword456'})
    assert auth_response.status_code == 200
    fresh_cookies = {'session_id': auth_response.cookies['session_id']}
    
    # Create a todo
    response = requests.post(f'http://localhost:{server_port}/todos', 
                            cookies=fresh_cookies,
                            json={'title': 'Todo To Delete', 'description': 'Will be deleted'})
    assert response.status_code == 201
    todo_to_delete = response.json()
    todo_id = todo_to_delete['id']
    
    # Verify it exists
    response = requests.get(f'http://localhost:{server_port}/todos/{todo_id}', cookies=fresh_cookies)
    assert response.status_code == 200
    
    # Delete it
    response = requests.delete(f'http://localhost:{server_port}/todos/{todo_id}', cookies=fresh_cookies)
    assert response.status_code == 204
    
    # Verify it's gone
    response = requests.get(f'http://localhost:{server_port}/todos/{todo_id}', cookies=fresh_cookies)
    assert response.status_code == 404
    print("✓ Todo deletion successful")

def run_all_tests():
    print("Starting server tests...\n")
    TEST_PORT = 8001
    server_process = start_server(TEST_PORT)
    
    try:
        # Test 1: Registration
        test_register(TEST_PORT)
        print()
        
        # Test 2: Login functionality  
        session_cookies = test_login(TEST_PORT)
        print()
        
        # Test 3: Authentication enforcement
        test_auth_required_endpoints(TEST_PORT)
        print()
        
        # Test 4: Authenticated operations
        test_authenticated_operations(session_cookies, TEST_PORT)
        print()
        
        # Test 5: Password changes
        test_change_password(session_cookies, TEST_PORT)
        print()
        
        # Test 6: Deleting todos
        test_delete_todo(session_cookies, TEST_PORT)
        print()
        
        print("🎉 ALL TESTS PASSED!")
        
    finally:
        stop_server(server_process)

if __name__ == '__main__':
    run_all_tests()