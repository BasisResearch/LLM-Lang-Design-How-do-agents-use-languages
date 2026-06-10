#!/usr/bin/env python3
"""
Test script for the Todo API server
"""
import subprocess
import time
import threading
import requests
import json
import sys
from urllib.parse import urlparse

def start_server(port):
    """Start the server in a separate thread/process."""
    proc = subprocess.Popen(['python3', 'todo_server.py', '--port', str(port)])
    # Wait a moment for the server to start up
    time.sleep(1)
    return proc

def make_request(method, url, data=None, cookies=None, expected_status=200, should_fail=False):
    """Make an HTTP request and handle expectations."""
    print(f"Making {method} request to: {url}")
    if data:
        print(f"Data: {data}")

    try:
        response = requests.request(method, url, json=data, cookies=cookies)
        print(f"Response Status: {response.status_code}, Expected: {expected_status}")
        
        # For successful scenarios, expect success unless told otherwise
        if should_fail:
            if response.status_code == expected_status:
                print("✓ Failed as expected")
                return response
            else:
                print(f"✗ Expected failure but got {response.status_code}")
                print(response.text)
                return response
                
        if response.status_code == expected_status:
            print("✓ Success!")
            try:
                res_data = response.json() if response.text else {}
                print(f"Response: {res_data}")
                return response
            except:
                print("Empty response (as expected)")
                return response
        else:
            print(f"✗ FAIL: Expected {expected_status}, got {response.status_code}")
            print(f"Response text: {response.text}")
            raise Exception(f"Status mismatch: expected {expected_status}, got {response.status_code}")
    except requests.RequestException as e:
        if should_fail:
            print(f"✓ Request failed as expected: {str(e)}")
            return None
        else:
            print(f"✗ Unexpected request exception: {str(e)}")
            return None

def run_tests(port=8765):
    """Run integration tests against the server."""
    server_proc = start_server(port)
    base_url = f"http://localhost:{port}"
    
    try:
        cookies = {}
        
        # Test 1: POST /register - invalid username (too short)
        print("\n=== Test 1: Register with Invalid Username (Too Short) ===")
        resp = make_request('POST', f"{base_url}/register", data={"username": "ab", "password": "password123"}, expected_status=400)
        
        # Test 2: POST /register - valid registration
        print("\n=== Test 2: Register Valid User ===")
        resp = make_request('POST', f"{base_url}/register", data={"username": "testuser", "password": "password123"}, expected_status=201)
        response_data = resp.json()
        assert response_data.get('username') == 'testuser'
        assert 'id' in response_data
        user_id = response_data['id']
        print(f"Registered user with ID: {user_id}")
        
        # Test 3: POST /register - duplicate username
        print("\n=== Test 3: Register with Duplicate Username ===")
        resp = make_request('POST', f"{base_url}/register", data={"username": "testuser", "password": "password123"}, expected_status=409)
        
        # Test 4: POST /register - invalid username (with special chars)
        print("\n=== Test 4: Register with Invalid Username (Special Chars) ===")
        resp = make_request('POST', f"{base_url}/register", data={"username": "test.user", "password": "password123"}, expected_status=400)
        
        # Test 5: POST /login with invalid credentials
        print("\n=== Test 5: Login with Invalid Credentials ===")
        resp = make_request('POST', f"{base_url}/login", data={"username": "nonexistent", "password": "wrongpass"}, expected_status=401)
        
        # Test 6: POST /login with correct credentials
        print("\n=== Test 6: Login with Valid Credentials ===")
        response = requests.post(f"{base_url}/login", json={"username": "testuser", "password": "password123"})
        assert response.status_code == 200
        print("✓ Login successful")
        
        # Extract session cookie
        cookies = {'session_id': ''}
        if 'Set-Cookie' in response.headers:
            cookie_str = response.headers['Set-Cookie']
            if 'session_id=' in cookie_str:
                session_start = cookie_str.find('session_id=') + len('session_id=')
                session_end = cookie_str.find(';', session_start)
                cookies['session_id'] = cookie_str[session_start:session_end] if session_end != -1 else cookie_str[session_start:]
        elif 'session_id' in response.cookies:
            cookies['session_id'] = response.cookies['session_id']
        else:
            # If the Set-Cookie header is formatted differently, parse it directly from response
            cookie_header = response.headers.get('Set-Cookie', '')
            if 'session_id=' in cookie_header:
                session_start = cookie_header.find('session_id=') + len('session_id=')
                session_end = cookie_header.find(';', session_start)
                session_val = cookie_header[session_start:session_end] if session_end != -1 else cookie_header[session_start:].split()[0]
                cookies['session_id'] = session_val.strip()
        
        print(f"Extracted session cookie: {cookies}")
        
        # Test 7: GET /me without authentication should fail
        print("\n=== Test 7: Get user info without authentication ===")
        resp = make_request('GET', f"{base_url}/me", expected_status=401, should_fail=True)
        
        # Test 8: GET /me with authentication
        print("\n=== Test 8: Get user info with authentication ===")
        resp = make_request('GET', f"{base_url}/me", cookies=cookies, expected_status=200)
        response_data = resp.json()
        assert response_data.get('username') == 'testuser'
        assert response_data.get('id') == user_id
        
        # Test 9: PUT /password with wrong old password
        print("\n=== Test 9: Change password with wrong old password ===")
        resp = make_request('PUT', f"{base_url}/password", data={"old_password": "wrongpass", "new_password": "newverystrongpassword"}, 
                           cookies=cookies, expected_status=401, should_fail=True)
        
        # Test 10: PUT /password with too short new password
        print("\n=== Test 10: Change password with too short new password ===")
        resp = make_request('PUT', f"{base_url}/password", data={"old_password": "password123", "new_password": "short"}, 
                           cookies=cookies, expected_status=400)
        
        # Test 11: PUT /password successfully change password
        print("\n=== Test 11: Change password successfully ===")
        resp = make_request('PUT', f"{base_url}/password", data={"old_password": "password123", "new_password": "newverystrongpassword"}, 
                           cookies=cookies, expected_status=200)
        
        # Test 12: Try logging in with old password (should fail now)
        print("\n=== Test 12: Verify old password no longer works ===")
        old_login_response = requests.post(f"{base_url}/login", json={"username": "testuser", "password": "password123"})
        assert old_login_response.status_code == 401
        print("✓ Old password no longer works after change")
        
        # Test 13: Login with new password
        print("\n=== Test 13: Login with new password ===")
        new_login_response = requests.post(f"{base_url}/login", json={"username": "testuser", "password": "newverystrongpassword"})
        assert new_login_response.status_code == 200
        print("✓ New password works")
        
        # Update session cookies
        if 'Set-Cookie' in new_login_response.headers:
            cookie_str = new_login_response.headers['Set-Cookie']
            session_start = cookie_str.find('session_id=') + len('session_id=')
            session_end = cookie_str.find(';', session_start)
            new_session_id = cookie_str[session_start:session_end] if session_end != -1 else cookie_str[session_start:]
            cookies['session_id'] = new_session_id
        
        # Test 14: GET /todos should initially return empty list
        print("\n=== Test 14: Get todos (initially empty) ===")
        resp = make_request('GET', f"{base_url}/todos", cookies=cookies, expected_status=200)
        response_data = resp.json()
        assert response_data == []
        print("✓ Empty todos returned as expected")
        
        # Test 15: POST /todos - missing title
        print("\n=== Test 15: Create todo with missing title ===")
        resp = make_request('POST', f"{base_url}/todos", data={"description": "Some description"}, 
                           cookies=cookies, expected_status=400)
        
        # Test 16: POST /todos - create a todo
        print("\n=== Test 16: Create first todo ===")
        resp = make_request('POST', f"{base_url}/todos", data={"title": "First Task", "description": "My first todo item"}, 
                           cookies=cookies, expected_status=201)
        todo1 = resp.json()
        assert todo1['title'] == 'First Task'
        assert isinstance(todo1['id'], int)
        assert todo1['user_id'] == user_id
        assert not todo1['completed']
        assert 'created_at' in todo1
        assert 'updated_at' in todo1
        todo1_id = todo1['id']
        print(f"Created todo with ID: {todo1_id}")
        
        # Test 17: POST /todos - create a second todo
        print("\n=== Test 17: Create second todo ===")
        resp = make_request('POST', f"{base_url}/todos", data={"title": "Second Task", "description": ""}, 
                           cookies=cookies, expected_status=201)
        todo2 = resp.json()
        assert todo2['title'] == 'Second Task'
        todo2_id = todo2['id']
        print(f"Created todo with ID: {todo2_id}")
        
        # Test 18: GET /todos - should return both todos
        print("\n=== Test 18: Get all todos ===")
        resp = make_request('GET', f"{base_url}/todos", cookies=cookies, expected_status=200)
        response_data = resp.json()
        assert len(response_data) == 2
        titles = [t['title'] for t in response_data]
        assert 'First Task' in titles
        assert 'Second Task' in titles
        print("✓ All user's todos returned correctly")
        
        # Test 19: GET /todos/:id - get first todo
        print("\n=== Test 19: Get specific todo ===")
        resp = make_request('GET', f"{base_url}/todos/{todo1_id}", cookies=cookies, expected_status=200)
        response_data = resp.json()
        assert response_data['id'] == todo1_id
        assert response_data['title'] == 'First Task'
        print("✓ Specific todo retrieved correctly")
        
        # Test 20: GET /todos/:id - invalid todo ID
        print("\n=== Test 20: Get non-existent todo ===")
        resp = make_request('GET', f"{base_url}/todos/99999", cookies=cookies, expected_status=404)
        
        # Test 21: PUT /todos/:id - update todo title only
        print("\n=== Test 21: Partially update todo (title only) ===")
        resp = make_request('PUT', f"{base_url}/todos/{todo1_id}", 
                           data={"title": "Updated First Task"}, 
                           cookies=cookies, expected_status=200)
        updated_todo = resp.json()
        assert updated_todo['id'] == todo1_id
        assert updated_todo['title'] == 'Updated First Task'
        print("✓ Partial update worked")
        
        # Test 22: PUT /todos/:id - mark as completed
        print("\n=== Test 22: Mark todo as completed ===")
        resp = make_request('PUT', f"{base_url}/todos/{todo1_id}", 
                           data={"completed": True}, 
                           cookies=cookies, expected_status=200)
        updated_todo = resp.json()
        assert updated_todo['completed'] == True
        print("✓ Completion status updated")
        
        # Test 23: PUT /todos/:id - empty title should fail
        print("\n=== Test 23: Attempt to update title to empty string ===")
        resp = make_request('PUT', f"{base_url}/todos/{todo1_id}", 
                           data={"title": ""}, 
                           cookies=cookies, expected_status=400)
        
        # Test 24: PUT /todos/:id - non-existent todo should fail
        print("\n=== Test 24: Attempt to update non-existent todo ===")
        resp = make_request('PUT', f"{base_url}/todos/99999", 
                           data={"title": "fake"}, 
                           cookies=cookies, expected_status=404, should_fail=True)
        
        # Test 25: DELETE /todos/:id - delete first todo
        print("\n=== Test 25: Delete first todo ===")
        resp = requests.delete(f"{base_url}/todos/{todo1_id}", cookies=cookies)
        assert resp.status_code == 204
        print("✓ First todo deleted")
        
        # Test 26: Deleted todo should no longer be accessible
        print("\n=== Test 26: Try to get deleted todo ===")
        resp = make_request('GET', f"{base_url}/todos/{todo1_id}", cookies=cookies, expected_status=404)
        
        # Test 27: Logout
        print("\n=== Test 27: Logout ===")
        resp = make_request('POST', f"{base_url}/logout", cookies=cookies, expected_status=200)
        
        # Test 28: Verify logout worked by trying to access protected resource
        print("\n=== Test 28: Access protected resource after logout ===")
        resp = make_request('GET', f"{base_url}/me", cookies=cookies, expected_status=401, should_fail=True)
        
        print("\n🎉 All tests passed!")
        
    except Exception as e:
        print(f"\n❌ Test failed with error: {str(e)}")
        import traceback
        traceback.print_exc()
        server_proc.terminate()
        sys.exit(1)
    
    server_proc.terminate()

if __name__ == '__main__':
    run_tests()