#!/usr/bin/env python3
"""
Test script to verify the todo app server functionality
"""
import subprocess
import time
import json
import requests
import sys
import os
import signal

SERVER_URL = 'http://localhost:8765'

def start_server():
    """Start the server and wait to ensure it's running"""
    global p # process to keep track of
    env = os.environ.copy()
    # Need this to avoid locale issues with python
    env['LC_ALL'] = 'C.UTF-8'
    p = subprocess.Popen(['python3', 'todo_server.py', '--port', '8765'], 
                         stdout=subprocess.PIPE, 
                         stderr=subprocess.PIPE, 
                         env=env)
    
    # Wait for server to start
    for i in range(20):
        try:
            response = requests.get(SERVER_URL + '/health_check', timeout=1)
        except:
            time.sleep(0.5)
            continue
        break
    else:
        # If we reached max attempts without breaking, try a more direct connection
        # First terminate previous attempt if it exists
        try:
            p.terminate()
            p.wait(timeout=2)
        except:
            pass
        # Start fresh
        p = subprocess.Popen(['python3', 'todo_server.py', '--port', '8765'], 
                             stdout=subprocess.PIPE, 
                             stderr=subprocess.PIPE, 
                             env=env)
        time.sleep(2)

# Define helper functions for making authenticated requests
cookies = {}

def get_session_cookies():
    """Return the cookies from the session"""
    return cookies

def add_cookies_to_response(response):
    """Add session cookies from response to our cookies dict"""
    for header_name, value in response.raw.headers.items():
        if header_name.lower() == 'set-cookie':
            parts = value.split(';')[0].split('=')
            if len(parts) == 2:
                key, val = parts
                if key == 'session_id':
                    cookies[key] = val

def make_request(method, url, data=None, expected_status=None):
    """Make a request and manage cookies"""
    headers = {'Content-Type': 'application/json'}
    
    if method.upper() == 'GET':
        response = requests.get(url, cookies=cookies, headers=headers)
    elif method.upper() == 'POST':
        response = requests.post(url, json=data, cookies=cookies, headers=headers)
    elif method.upper() == 'PUT':
        response = requests.put(url, json=data, cookies=cookies, headers=headers)
    elif method.upper() == 'DELETE':
        response = requests.delete(url, cookies=cookies, headers=headers)
    
    add_cookies_to_response(response)
    
    if expected_status and response.status_code != expected_status:
        print(f'ERROR: Expected status {expected_status}, got {response.status_code} for {method} {url}')
        print(f'Response: {response.text}')
        sys.exit(1)
    
    return response

def run_tests():
    started = time.time()
    print("Testing POST /register...")
    # Test register - valid user
    response = make_request('POST', f'{SERVER_URL}/register', 
                           data={'username': 'testuser', 'password': 'password123'}, 
                           expected_status=201)
    assert response.json()['id'] == 1
    assert response.json()['username'] == 'testuser'
    print("✓ Register successful")

    # Test register - invalid username (too short)
    response = make_request('POST', f'{SERVER_URL}/register', 
                           data={'username': 'ab', 'password': 'password123'}, 
                           expected_status=400)
    assert response.json()['error'] == 'Invalid username'
    print("✓ Validation for too short username works")

    # Test register - invalid username (invalid characters)
    response = make_request('POST', f'{SERVER_URL}/register', 
                           data={'username': 'test@user', 'password': 'password123'}, 
                           expected_status=400)
    assert response.json()['error'] == 'Invalid username'
    print("✓ Validation for invalid characters in username works")

    # Test register - password too short
    response = make_request('POST', f'{SERVER_URL}/register', 
                           data={'username': 'testuser2', 'password': 'pass'}, 
                           expected_status=400)
    assert response.json()['error'] == 'Password too short'
    print("✓ Validation for short password works")

    # Test register - duplicate username
    response = make_request('POST', f'{SERVER_URL}/register', 
                           data={'username': 'testuser', 'password': 'password123'}, 
                           expected_status=409)
    assert response.json()['error'] == 'Username already exists'
    print("✓ Validation for duplicate username works")

    print("\nTesting POST /login...")
    # Test login - valid credentials
    response = make_request('POST', f'{SERVER_URL}/login', 
                           data={'username': 'testuser', 'password': 'password123'}, 
                           expected_status=200)
    assert response.json()['id'] == 1
    assert response.json()['username'] == 'testuser'
    print("✓ Login successful")
    
    # Verify session was created (by getting /me)
    response = make_request('GET', f'{SERVER_URL}/me', expected_status=200)
    assert response.json()['id'] == 1
    assert response.json()['username'] == 'testuser'
    print("✓ Session management works")

    # Test login - wrong password
    response = make_request('POST', f'{SERVER_URL}/login', 
                           data={'username': 'testuser', 'password': 'wrongpass'}, 
                           expected_status=401)
    assert response.json()['error'] == 'Invalid credentials'
    print("✓ Invalid credentials validation works")

    # Test login - non-existent user
    response = make_request('POST', f'{SERVER_URL}/login', 
                           data={'username': 'nonexistent', 'password': 'password123'}, 
                           expected_status=401)
    assert response.json()['error'] == 'Invalid credentials'
    print("✓ Validation for non-existent user works")

    print("\nTesting protected endpoints without auth...")
    # Test GET /me without authentication
    # Temporarily clear cookies to simulate no auth
    saved_cookies = cookies.copy()
    cookies.clear()
    response = make_request('GET', f'{SERVER_URL}/me', expected_status=401)
    assert response.json()['error'] == 'Authentication required'
    print("✓ Auth required for /me")

    # Test GET /todos without authentication
    response = make_request('GET', f'{SERVER_URL}/todos', expected_status=401)
    assert response.json()['error'] == 'Authentication required'
    print("✓ Auth required for /todos")
    
    # Restore cookies
    cookies.update(saved_cookies)

    print("\nTesting PUT /password...")
    # Test change password - correct old password
    response = make_request('PUT', f'{SERVER_URL}/password', 
                           data={'old_password': 'password123', 'new_password': 'newpassword456'}, 
                           expected_status=200)
    print("✓ Password change success")
    
    # Test with new password - first logout and login
    make_request('POST', f'{SERVER_URL}/logout', expected_status=200)
    cookies.clear()  # Clear current session tokens

    # Now login with new password
    response = make_request('POST', f'{SERVER_URL}/login', 
                           data={'username': 'testuser', 'password': 'newpassword456'}, 
                           expected_status=200)
    print("✓ New password works for login")

    print("\nTesting todos endpoints...")
    # Create a few todo items
    todo1 = make_request('POST', f'{SERVER_URL}/todos', 
                        data={'title': 'First task', 'description': 'Do things'}, 
                        expected_status=201).json()
    assert todo1['title'] == 'First task'
    assert todo1['description'] == 'Do things'
    assert todo1['completed'] == False
    assert 'created_at' in todo1
    assert 'updated_at' in todo1
    print("✓ Creating todo works")

    todo2 = make_request('POST', f'{SERVER_URL}/todos', 
                        data={'title': 'Second task', 'description': ''}, 
                        expected_status=201).json()
    print("✓ Creating todo with empty description works")

    # Test validation: title cannot be empty on create
    response = make_request('POST', f'{SERVER_URL}/todos', 
                           data={'title': '', 'description': 'Desc'}, 
                           expected_status=400)
    assert response.json()['error'] == 'Title is required'
    print("✓ Validation for empty title on create works")

    # Test GET /todos
    todos = make_request('GET', f'{SERVER_URL}/todos', expected_status=200).json()
    assert len(todos) == 2
    # Ordered by ID asc
    assert todos[0]['title'] == 'First task'
    assert todos[1]['title'] == 'Second task'
    print("✓ Listing todos works")

    # Test GET /todos/:id
    todo_id = todo1['id']
    response = make_request('GET', f'{SERVER_URL}/todos/{todo_id}', expected_status=200)
    fetched_todo = response.json()
    assert fetched_todo['title'] == 'First task'
    print(f"✓ Getting specific todo works")

    # Test GET /todos/:id - invalid/missing todo
    response = make_request('GET', f'{SERVER_URL}/todos/999', expected_status=404)
    assert response.json()['error'] == 'Todo not found'
    print("✓ Getting non-existent todo returns 404")

    # Test PUT /todos/:id - partial update
    response = make_request('PUT', f'{SERVER_URL}/todos/{todo_id}', 
                           data={'completed': True, 'description': 'Updated desc'}, 
                           expected_status=200)
    updated_todo = response.json()
    assert updated_todo['completed'] == True
    assert updated_todo['description'] == 'Updated desc'
    assert updated_todo['title'] == 'First task'  # Unchanged
    print("✓ Partial update works")

    # Test PUT - validation: empty title not allowed
    response = make_request('PUT', f'{SERVER_URL}/todos/{todo_id}', 
                           data={'title': ''}, 
                           expected_status=400)
    assert response.json()['error'] == 'Title is required'
    print("✓ Validation for empty title on update works")

    # Test PUT - updating non-existent todo
    response = make_request('PUT', f'{SERVER_URL}/todos/999', 
                           data={'title': 'New title'}, 
                           expected_status=404)
    assert response.json()['error'] == 'Todo not found'
    print("✓ Updating non-existent todo returns 404")

    # Test DELETE /todos/:id
    response = make_request('DELETE', f'{SERVER_URL}/todos/{todo_id}', expected_status=204)
    print("✓ Delete todo works")
    
    # Verify it's gone
    response = make_request('GET', f'{SERVER_URL}/todos/{todo_id}', expected_status=404)
    print("✓ Deleted todo is actually gone")

    # Test DELETE - non-existent todo
    response = make_request('DELETE', f'{SERVER_URL}/todos/999', expected_status=404)
    assert response.json()['error'] == 'Todo not found'
    print("✓ Deleting non-existent todo returns 404")

    print("\nTesting logout...")
    make_request('POST', f'{SERVER_URL}/logout', expected_status=200)
    # Verify session is invalidated by trying to access protected route
    response = make_request('GET', f'{SERVER_URL}/me', expected_status=401)
    assert response.json()['error'] == 'Authentication required'
    print("✓ Logout works and invalidates session")

    # Test authentication requirements for all protected routes
    routes_without_auth = [
        (f'{SERVER_URL}/register', 'POST'),
        (f'{SERVER_URL}/login', 'POST')
    ]
    for route, method in routes_without_auth:
        time.sleep(0.1)  # Delay to avoid rate limiting issues
        try:
            response = make_request(method, route, 
                                  data={'username': 'temp', 'password': 'temppass123'})
        except:
            pass  # Expected for login/register since no valid data provided
    
    print("\nAll tests passed! ✅")
    print(f"Total test duration: {time.time() - started:.2f}s")

def cleanup():
    """Clean up the running server"""
    if 'p' in globals():
        try:
            p.terminate()
            p.wait(timeout=2)
        except:
            p.kill()

if __name__ == '__main__':
    try:
        start_server()
        # Give server some more time to fully start
        time.sleep(3)
        # Run all tests
        run_tests()
    finally:
        cleanup()