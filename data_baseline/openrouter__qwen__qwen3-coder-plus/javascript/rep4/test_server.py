#!/usr/bin/env python3

import subprocess
import time
import json
import urllib.request
import urllib.error
import urllib.parse
from http.cookies import SimpleCookie
import signal
import sys
import os

def make_request(method, url, data=None, headers=None, cookies=None):
    """Helper function to make HTTP requests"""
    if data and isinstance(data, dict):
        data = json.dumps(data).encode('utf-8')
        if headers is None:
            headers = {}
        headers['Content-Type'] = 'application/json'
    
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    
    # Add cookies to request if provided
    if cookies:
        cookie_header = "; ".join([f"{k}={v}" for k, v in cookies.items()])
        req.add_header('Cookie', cookie_header)
    
    try:
        response = urllib.request.urlopen(req)
        response_body = response.read().decode('utf-8')
        return response.status, json.loads(response_body) if response_body.strip() else {}, response.headers.get('Set-Cookie')
    except urllib.error.HTTPError as e:
        response_body = e.read().decode('utf-8')
        try:
            error_json = json.loads(response_body) if response_body.strip() else {'error': f'HTTP {e.code}'}
        except json.JSONDecodeError:
            error_json = {'error': f'Response body: {response_body}'}
        return e.code, error_json, e.headers.get('Set-Cookie') if hasattr(e, 'headers') else None

def test_endpoints():
    """Test all endpoints"""
    base_url = 'http://localhost:3000'
    cookies = {}

    print("Testing POST /register")
    status, data, cookie = make_request(
        'POST',
        f'{base_url}/register',
        {'username': 'testuser', 'password': 'password123'}
    )
    assert status == 201, f'Expected 201, got {status}. Response: {data}'
    assert 'id' in data and 'username' in data
    print(f'✓ Registration successful: {data}')
    
    print("\nTesting POST /register with existing username (should fail)")
    status, data, _ = make_request(
        'POST',
        f'{base_url}/register',
        {'username': 'testuser', 'password': 'password123'}
    )
    assert status == 409, f'Expected 409, got {status}. Response: {data}'
    assert 'error' in data and 'already exists' in data['error']
    print('✓ Duplicate registration correctly rejected')

    print("\nTesting POST /login")
    status, data, cookie = make_request(
        'POST',
        f'{base_url}/login',
        {'username': 'testuser', 'password': 'password123'}
    )
    assert status == 200, f'Expected 200, got {status}. Response: {data}'
    assert 'id' in data and 'username' in data
    print(f'✓ Login successful: {data}')
    
    # Extract session cookie
    if cookie:
        parsed_cookie = SimpleCookie()
        parsed_cookie.load(cookie)
        session_id = parsed_cookie['session_id'].value
        cookies['session_id'] = session_id

    print("\nTesting GET /me")
    status, data, _ = make_request('GET', f'{base_url}/me', cookies=cookies)
    assert status == 200, f'Expected 200, got {status}. Response: {data}'
    assert 'id' in data and data['id'] == 1
    assert 'username' in data and data['username'] == 'testuser'
    print(f'✓ Get user details successful: {data}')

    print("\nTesting POST /todos")
    status, data, _ = make_request(
        'POST',
        f'{base_url}/todos',
        {'title': 'First Task', 'description': 'This is my first task'},
        cookies=cookies
    )
    assert status == 201, f'Expected 201, got {status}. Response: {data}'
    assert 'id' in data and 'title' in data and 'description' in data
    assert data['title'] == 'First Task'
    assert data['description'] == 'This is my first task'
    assert 'created_at' in data and 'updated_at' in data
    assert data['completed'] is False
    todo_id = data['id']
    print(f'✓ Create todo successful: {data}')

    print(f"\nTesting GET /todos/{todo_id}")
    status, data, _ = make_request('GET', f'{base_url}/todos/{todo_id}', cookies=cookies)
    assert status == 200, f'Expected 200, got {status}. Response: {data}'
    assert data['id'] == todo_id
    print(f'✓ Get specific todo successful: {data}')

    print(f"\nTesting PUT /todos/{todo_id}")
    status, data, _ = make_request(
        'PUT',
        f'{base_url}/todos/{todo_id}',
        {'title': 'Updated Task', 'completed': True},
        cookies=cookies
    )
    assert status == 200, f'Expected 200, got {status}. Response: {data}'
    assert data['title'] == 'Updated Task'
    assert data['completed'] is True
    print(f'✓ Update todo successful: {data}')

    print(f"\nTesting PUT /todos/{todo_id} with invalid empty title")
    status, data, _ = make_request(
        'PUT',
        f'{base_url}/todos/{todo_id}',
        {'title': ''},
        cookies=cookies
    )
    assert status == 400, f'Expected 400, got {status}. Response: {data}'
    assert 'error' in data and 'required' in data['error']
    print('✓ Empty title correctly rejected during update')

    print("\nTesting GET /todos")
    status, data, _ = make_request('GET', f'{base_url}/todos', cookies=cookies)
    assert status == 200, f'Expected 200, got {status}. Response: {data}'
    assert len(data) >= 1, f'Expected at least 1 todo, got {len(data)}'
    assert any(t['id'] == todo_id for t in data), 'Expected specific todo in list'
    print(f'✓ Get all todos successful: {len(data)} todos retrieved')

    print("\nTesting GET /todos without authentication (should fail)")
    status, data, _ = make_request('GET', f'{base_url}/todos')
    assert status == 401, f'Expected 401, got {status}. Response: {data}'
    assert 'error' in data and 'Authentication required' in data['error']
    print('✓ Unauthorized access correctly denied')

    print("\nTesting PUT /password")
    status, data, _ = make_request(
        'PUT',
        f'{base_url}/password',
        {'old_password': 'password123', 'new_password': 'newpassword456'},
        cookies=cookies
    )
    assert status == 200, f'Expected 200, got {status}. Response: {data}'
    print('✓ Password change successful')

    print("\nTesting /logout")
    status, data, _ = make_request('POST', f'{base_url}/logout', cookies=cookies)
    assert status == 200, f'Expected 200, got {status}. Response: {data}'
    print('✓ Logout successful')

    print("\nTesting operations after logout (should fail)")
    status, data, _ = make_request('GET', f'{base_url}/me', cookies=cookies)
    assert status == 401, f'Expected 401, got {status}. Response: {data}'
    assert 'error' in data and 'Authentication required' in data['error']
    print('✓ Access after logout correctly denied')

    print("\nTesting login with new password")
    status, data, cookie = make_request(
        'POST',
        f'{base_url}/login',
        {'username': 'testuser', 'password': 'newpassword456'}
    )
    assert status == 200, f'Expected 200, got {status}. Response: {data}'
    print(f'✓ Login with new password successful: {data}')
    
    # Update cookies for subsequent requests
    if cookie:
        parsed_cookie = SimpleCookie()
        parsed_cookie.load(cookie)
        session_id = parsed_cookie['session_id'].value
        cookies['session_id'] = session_id

    print(f"\nTesting DELETE /todos/{todo_id}")
    status, data, _ = make_request('DELETE', f'{base_url}/todos/{todo_id}', cookies=cookies)
    assert status == 204, f'Expected 204, got {status}'
    print('✓ Delete todo successful')

    print(f"\nTesting GET /todos/{todo_id} after deletion (should fail)")
    status, data, _ = make_request('GET', f'{base_url}/todos/{todo_id}', cookies=cookies)
    assert status == 404, f'Expected 404, got {status}. Response: {data}'
    assert 'error' in data and 'not found' in data['error']
    print('✓ Deleted todo correctly returns 404')

    print("\nTesting register edge cases")
    # Test invalid username
    status, data, _ = make_request(
        'POST',
        f'{base_url}/register',
        {'username': 'ab', 'password': 'password123'}  # Too short
    )
    assert status == 400, f'Expected 400, got {status}. Response: {data}'
    print('✓ Short username correctly rejected')

    # Test invalid characters in username
    status, data, _ = make_request(
        'POST',
        f'{base_url}/register',
        {'username': 'user@name', 'password': 'password123'}  # Invalid chars
    )
    assert status == 400, f'Expected 400, got {status}. Response: {data}'
    print('✓ Invalid characters in username correctly rejected')

    # Test short password
    status, data, _ = make_request(
        'POST',
        f'{base_url}/register',
        {'username': 'validuser', 'password': 'short'}  # Too short
    )
    assert status == 400, f'Expected 400, got {status}. Response: {data}'
    print('✓ Short password correctly rejected')
    
    # Test missing fields
    status, data, _ = make_request(
        'POST',
        f'{base_url}/register',
        {'password': 'password123'}
    )
    assert status == 400, f'Expected 400, got {status}. Response: {data}'
    print('✓ Missing username correctly rejected')

    # Test wrong credentials
    status, data, _ = make_request(
        'POST',
        f'{base_url}/login',
        {'username': 'nonexistent', 'password': 'wrongpass'}
    )
    assert status == 401, f'Expected 401, got {status}. Response: {data}'
    print('✓ Wrong credentials correctly rejected')

    print("\nTesting POST /todos with missing/empty title")
    status, data, _ = make_request(
        'POST',
        f'{base_url}/todos',
        {'description': 'No title provided'},
        cookies=cookies
    )
    assert status == 400, f'Expected 400, got {status}. Response: {data}'
    assert 'error' in data and 'required' in data['error']
    print('✓ Missing title in POST /todos correctly rejected')

    status, data, _ = make_request(
        'POST',
        f'{base_url}/todos',
        {'title': '', 'description': 'Empty title provided'},
        cookies=cookies
    )
    assert status == 400, f'Expected 400, got {status}. Response: {data}'
    assert 'error' in data and 'required' in data['error']
    print('✓ Empty title in POST /todos correctly rejected')

    status, data, _ = make_request(
        'PUT',
        f'{base_url}/password',
        {'old_password': 'wrongpassword', 'new_password': 'newpass123'},
        cookies=cookies
    )
    assert status == 401, f'Expected 401, got {status}. Response: {data}'
    print('✓ Wrong old password in PUT /password correctly rejected')

    print('\n🎉 All tests passed!')

def main():
    print('Starting test server...')
    # Start the server in the background
    server_process = subprocess.Popen(['./run.sh', '--port', '3000'])
    
    # Wait for the server to start
    time.sleep(2)
    
    try:
        test_endpoints()
        print('\n✅ All tests completed successfully!')
    except Exception as e:
        print(f'\n❌ Test failed: {e}')
        sys.exit(1)
    finally:
        # Kill the server
        print('Stopping server...')
        try:
            server_process.send_signal(signal.SIGTERM)
            server_process.wait(timeout=5)  # Wait up to 5 seconds for clean shutdown
        except subprocess.TimeoutExpired:
            print('Server did not terminate, killing forcefully...')
            server_process.kill()
        
if __name__ == '__main__':
    main()