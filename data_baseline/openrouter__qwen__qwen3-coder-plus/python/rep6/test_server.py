#!/usr/bin/env python3
"""
Test script for the Todo App API Server
Validates all endpoints work correctly.
"""

import subprocess
import time
import requests
import json
import threading
import os
import signal
import sys
import tempfile


class ServerTester:
    def __init__(self, port=8765):
        self.port = port
        self.url = f'http://localhost:{port}'
        self.session = requests.Session()
        self.process = None
    
    def start_server(self):
        """Start the server in background."""
        print("Starting server...")
        self.process = subprocess.Popen(
            [sys.executable, 'server.py', '--port', str(self.port)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        time.sleep(1)  # Allow server to start
    
    def stop_server(self):
        """Stop the running server."""
        if self.process:
            print("\nStopping server...")
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
    
    def test_endpoint(self, method, path, expected_status, data=None, cookies=None, desc=""):
        """Test a single endpoint."""
        url = self.url + path
        
        print(f"Testing: {method} {path} - {desc}", end="")
        
        try:
            if method.upper() == 'GET':
                response = self.session.get(url, cookies=cookies)
            elif method.upper() == 'POST':
                response = self.session.post(url, json=data, cookies=cookies)
            elif method.upper() == 'PUT':
                response = self.session.put(url, json=data, cookies=cookies)
            elif method.upper() == 'DELETE':
                response = self.session.delete(url, cookies=cookies)
            
            if response.status_code == expected_status:
                print(f" ✓ ({response.status_code})")
                return True
            else:
                print(f" ✗ Expected {expected_status}, got {response.status_code}: {response.text}")
                return False
        except Exception as e:
            print(f" ✗ Exception: {str(e)}")
            return False

    def get_session_cookie(self):
        """Extract session cookie from session history."""
        for req in self.session.cookies:
            if req.name == 'session_id':
                return req.value
        return None

    def test_all_endpoints(self):
        """Run all tests for the API."""
        success_count = 0
        total_count = 0

        # Test 1: Register a new user
        total_count += 1
        if self.test_endpoint('POST', '/register', 201, 
                              data={"username": "testuser", "password": "strongpass"}, 
                              desc="New user registration"):
            success_count += 1

        # Test 2: Register user with short username - should fail (400)
        total_count += 1
        if self.test_endpoint('POST', '/register', 400, 
                              data={"username": "ab", "password": "strongpass"}, 
                              desc="Short username validation"):
            success_count += 1

        # Test 3: Register user with invalid username - should fail (400)
        total_count += 1
        if self.test_endpoint('POST', '/register', 400, 
                              data={"username": "test@invalid", "password": "strongpass"}, 
                              desc="Invalid username validation"):
            success_count += 1

        # Test 4: Register user with short password - should fail (400)
        total_count += 1
        if self.test_endpoint('POST', '/register', 400, 
                              data={"username": "validuser", "password": "short"}, 
                              desc="Short password validation"):
            success_count += 1

        # Test 5: Login with registered user
        total_count += 1
        login_resp = self.session.post(f'{self.url}/login', json={"username": "testuser", "password": "strongpass"})
        if login_resp.status_code == 200:
            print(f"Testing: POST /login - User login ✓ ({login_resp.status_code})")
            success_count += 1
        else:
            print(f"Testing: POST /login - User login ✗ (Expected 200, got {login_resp.status_code}): {login_resp.text}")

        # Test 6: Try login with wrong password - should fail (401)
        total_count += 1
        if self.test_endpoint('POST', '/login', 401, 
                              data={"username": "testuser", "password": "wrongpass"}, 
                              desc="Invalid credentials validation"):
            success_count += 1

        # Get session cookies after login
        session_cookie = self.get_session_cookie()
        cookies_with_session = {"session_id": session_cookie} if session_cookie else {}

        # Test 7: Try authenticated endpoint without session - should fail (401)
        total_count += 1
        if self.test_endpoint('GET', '/me', 401, 
                              desc="Unauthenticated access to protected resource"):
            success_count += 1

        # Test 8: Access /me endpoint with valid session
        total_count += 1
        me_url = '/me'
        print(f"Testing: GET {me_url} - Access user information", end="")
        me_response = self.session.get(f'{self.url}{me_url}', cookies=cookies_with_session)
        if me_response.status_code == 200:
            print(f" ✓ ({me_response.status_code})")
            success_count += 1
        else:
            print(f" ✗ Expected 200, got {me_response.status_code}: {me_response.text}")

        # Test 9: Change password with correct old password
        total_count += 1
        change_pass_resp = self.session.put(f'{self.url}/password', 
                                          json={"old_password": "strongpass", "new_password": "newstrongpass"},
                                          cookies=cookies_with_session)
        if change_pass_resp.status_code == 200:
            print(f"Testing: PUT /password - Change password ✓ ({change_pass_resp.status_code})")
            success_count += 1
        else:
            print(f"Testing: PUT /password - Change password ✗ (Expected 200, got {change_pass_resp.status_code}): {change_pass_resp.text}")

        # Test 10: Try to change password with wrong old password - should fail (401)
        total_count += 1
        if self.test_endpoint('PUT', '/password', 401,
                              data={"old_password": "wrongpass", "new_password": "anotherpass"},
                              cookies=cookies_with_session, 
                              desc="Change password with wrong old password"):
            success_count += 1

        # Test 11: After changing password, login with old password should fail (401)
        total_count += 1
        if self.test_endpoint('POST', '/login', 401, 
                              data={"username": "testuser", "password": "strongpass"}, 
                              desc="Login with old password after change"):
            success_count += 1

        # Test 12: Login with new password should succeed
        total_count += 1
        login_new = self.session.post(f'{self.url}/login', json={"username": "testuser", "password": "newstrongpass"})
        if login_new.status_code == 200:
            session_cookie = self.get_session_cookie()
            cookies_with_session = {"session_id": session_cookie} if session_cookie else {}
            print(f"Testing: POST /login - Login with new password ✓ ({login_new.status_code})")
            success_count += 1
        else:
            print(f"Testing: POST /login - Login with new password ✗ (Expected 200, got {login_new.status_code}): {login_new.text}")

        # Now we have a valid session with the new password for subsequent tests

        # Test 13: Get todos list (should be empty initially)
        total_count += 1
        todos_resp = self.session.get(f'{self.url}/todos', cookies=cookies_with_session)
        if todos_resp.status_code == 200 and isinstance(todos_resp.json(), list):
            print(f"Testing: GET /todos - Get todos list ✓ ({todos_resp.status_code})")
            success_count += 1
        else:
            print(f"Testing: GET /todos - Get todos list ✗ (Expected 200 with array): {todos_resp.text}")

        # Test 14: Create a new todo
        total_count += 1
        create_resp = self.session.post(f'{self.url}/todos', 
                                       json={"title": "Buy milk", "description": "Go buy milk from store"},
                                       cookies=cookies_with_session)
        if create_resp.status_code == 201:
            print(f"Testing: POST /todos - Create new todo ✓ ({create_resp.status_code})")
            created_todo = create_resp.json()
            todo_id = created_todo['id']
            success_count += 1
        else:
            print(f"Testing: POST /todos - Create new todo ✗ (Expected 201, got {create_resp.status_code}): {create_resp.text}")

        # Test 15: Try to create todo without title - should fail (400)
        total_count += 1
        if self.test_endpoint('POST', '/todos', 400,
                              data={"title": "", "description": "Some description"},
                              cookies=cookies_with_session, 
                              desc="Create todo with empty title"):
            success_count += 1

        # Test 16: Get the specific todo we just created
        total_count += 1
        if self.test_endpoint('GET', f'/todos/{todo_id}', 200,
                              cookies=cookies_with_session, 
                              desc="Get specific todo"):
            success_count += 1

        # Test 17: Try to get a non-existant todo - should fail (404)
        total_count += 1
        if self.test_endpoint('GET', '/todos/99999', 404, 
                             cookies=cookies_with_session, 
                             desc="Get non-existent todo"):
            success_count += 1

        # Test 18: Update the todo partially
        total_count += 1
        put_resp = self.session.put(f'{self.url}/todos/{todo_id}',
                                   json={"completed": True},
                                   cookies=cookies_with_session)
        if put_resp.status_code == 200 and put_resp.json()['completed'] == True:
            print(f"Testing: PUT /todos/{todo_id} - Partially update todo ✓ ({put_resp.status_code})")
            success_count += 1
        else:
            print(f"Testing: PUT /todos/{todo_id} - Partially update todo ✗: {put_resp.text}")

        # Test 19: Update todo with empty title - should fail (400)
        total_count += 1
        if self.test_endpoint('PUT', f'/todos/{todo_id}', 400,
                              data={"title": ""},
                              cookies=cookies_with_session,
                              desc="Update todo with empty title"):
            success_count += 1

        # Test 20: Delete the todo
        total_count += 1
        delete_resp = self.session.delete(f'{self.url}/todos/{todo_id}', cookies=cookies_with_session)
        if delete_resp.status_code == 204:
            print(f"Testing: DELETE /todos/{todo_id} - Delete todo ✓ ({delete_resp.status_code})")
            success_count += 1
        else:
            print(f"Testing: DELETE /todos/{todo_id} - Delete todo ✗ (Expected 204, got {delete_resp.status_code})")

        # Test 21: Try to delete non-existent todo - should fail (404)
        total_count += 1
        if self.test_endpoint('DELETE', '/todos/99999', 404,
                             cookies=cookies_with_session, 
                             desc="Delete non-existent todo"):
            success_count += 1

        # Test 22: Logout
        total_count += 1
        logout_resp = self.session.post(f'{self.url}/logout', cookies=cookies_with_session)
        if logout_resp.status_code == 200:
            print(f"Testing: POST /logout - Logout ✓ ({logout_resp.status_code})")
            success_count += 1
        else:
            print(f"Testing: POST /logout - Logout ✗ (Expected 200, got {logout_resp.status_code}): {logout_resp.text}")

        # Test 23: Try to access protected resource after logging out - should fail (401)
        total_count += 1
        if self.test_endpoint('GET', '/me', 401, 
                             cookies=cookies_with_session,
                             desc="Access protected resource after logout"):
            success_count += 1

        print(f"\nTest results: {success_count}/{total_count} passed")
        return success_count == total_count


def main():
    tester = ServerTester(8765)
    
    try:
        tester.start_server()
        
        all_passed = tester.test_all_endpoints()
        
        if all_passed:
            print("\n🎉 All tests passed! 🎉")
            return 0
        else:
            print("\n❌ Some tests failed!")
            return 1
            
    finally:
        tester.stop_server()


if __name__ == "__main__":
    exit(main())