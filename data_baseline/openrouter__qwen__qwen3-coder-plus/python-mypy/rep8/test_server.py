#!/usr/bin/env python3
"""
Test script for the Todo App server.

This script starts the server in a separate thread and then exercises
all endpoints with curl-like calls to verify functionality.
"""

import subprocess
import time
import signal
import os
import sys
from typing import Dict, Any
import json
import http.client
import urllib.request


def wait_for_port(port: int, host: str = 'localhost', timeout: float = 5.0) -> None:
    """Wait until a port becomes available."""
    import socket
    import time
    start_time = time.time()
    while True:
        try:
            with socket.create_connection((host, port), timeout=timeout):
                break
        except OSError:
            if time.time() - start_time >= timeout:
                raise TimeoutError(f'Port {port} did not become open within {timeout}s')
            time.sleep(0.1)


def run_tests() -> bool:
    """Run all tests against the server."""
    port = 8001  # Use a different port for testing
    
    print(f'Starting server on port {port}')
    
    # Start the server process
    server_process = subprocess.Popen([
        sys.executable, 'server.py', '--port', str(port)
    ])
    
    try:
        # Wait for server to be ready
        wait_for_port(port)
        print('Server is running and accepting connections.')
        
        host = 'localhost'
        
        print('Testing registration...')
        # Test registration
        try:
            req = urllib.request.Request(
                f'http://{host}:{port}/register',
                data=json.dumps({
                    'username': 'testuser',
                    'password': 'password123'
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                user_result = json.loads(response.read())
                assert user_result['username'] == 'testuser'
                user_id = user_result['id']
                print('✓ Registration successful')
        except Exception as e:
            print(f'✗ Registration failed: {e}')
            return False
        
        print('Testing duplicate username registration...')
        # Test duplicate username registration
        try:
            req = urllib.request.Request(
                f'http://{host}:{port}/register',
                data=json.dumps({
                    'username': 'testuser',
                    'password': 'password123'
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                print(f'✗ Duplicate registration should have failed but got code {response.code}')
                return False
        except urllib.error.HTTPError as e:
            if e.code == 409:
                print('✓ Duplicate registration correctly failed')
            else:
                print(f'✗ Wrong error code for duplicate registration: {e.code}')
                return False
        except Exception as e:
            print(f'✗ Unexpected error during duplicate registration test: {e}')
            return False
        
        print('Testing validation for registration...')
        # Test registration with invalid username
        try:
            req = urllib.request.Request(
                f'http://{host}:{port}/register',
                data=json.dumps({
                    'username': 'ab',  # Too short
                    'password': 'password123'
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                print(f'✗ Short username registration should have failed but got code {response.code}')
                return False
        except urllib.error.HTTPError as e:
            if e.code == 400:
                print('✓ Short username registration correctly failed')
            else:
                print(f'✗ Wrong error code for short username: {e.code}')
                return False
        except Exception as e:
            print(f'✗ Unexpected error during short username test: {e}')
            return False
        
        # Test registration with bad characters in username
        try:
            req = urllib.request.Request(
                f'http://{host}:{port}/register',
                data=json.dumps({
                    'username': 'bad-user!',  # Invalid characters
                    'password': 'password123'
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                print(f'✗ Bad char username registration should have failed but got code {response.code}')
                return False
        except urllib.error.HTTPError as e:
            if e.code == 400:
                print('✓ Bad character username registration correctly failed')
            else:
                print(f'✗ Wrong error code for bad character username: {e.code}')
                return False
        except Exception as e:
            print(f'✗ Unexpected error during bad char username test: {e}')
            return False
        
        # Test login
        print('Testing login...')
        session_cookies: Dict[str, str] = {}
        try:
            req = urllib.request.Request(
                f'http://{host}:{port}/login',
                data=json.dumps({
                    'username': 'testuser',
                    'password': 'password123'
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                login_result = json.loads(response.read())
                assert login_result['username'] == 'testuser'
                
                # Extract session cookie from response headers
                cookies = response.headers.get_all('Set-Cookie', [])
                for cookie in cookies:
                    if cookie.startswith('session_id='):
                        session_id = cookie.split(';')[0].split('=')[1]
                        session_cookies['session_id'] = session_id
                        break
                
                print('✓ Login successful')
        except Exception as e:
            print(f'✗ Login failed: {e}')
            return False
        
        # Test access without auth to protected endpoint
        print("Testing unauthorized access...")
        try:
            req = urllib.request.Request(
                f'http://{host}:{port}/me',
                method='GET'
            )
            with urllib.request.urlopen(req) as response:
                print(f'✗ Unauthenticated access should have failed but got code {response.code}')
                return False
        except urllib.error.HTTPError as e:
            if e.code == 401:
                print('✓ Unauthenticated access correctly failed')
            else:
                print(f'✗ Wrong error code for unauthenticated access: {e.code}')
                return False
        except Exception as e:
            print(f'✗ Unexpected error during unauth test: {e}')
            return False
        
        # Test access with auth to protected endpoint
        print("Testing authorized access...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}'}
            req = urllib.request.Request(
                f'http://{host}:{port}/me',
                headers=headers,
                method='GET'
            )
            with urllib.request.urlopen(req) as response:
                me_result = json.loads(response.read())
                assert me_result['username'] == 'testuser'
                print('✓ Authenticated access successful')
        except Exception as e:
            print(f'✗ Authenticated access failed: {e}')
            return False
        
        # Test creating a todo
        print("Testing todo creation...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}', 'Content-Type': 'application/json'}
            req = urllib.request.Request(
                f'http://{host}:{port}/todos',
                data=json.dumps({
                    'title': 'Buy milk',
                    'description': 'Get 2% milk from the grocery store'
                }).encode(),
                headers=headers,
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                todo_result = json.loads(response.read())
                assert todo_result['title'] == 'Buy milk'
                assert todo_result['description'] == 'Get 2% milk from the grocery store'
                todo_id = todo_result['id']
                print('✓ Todo creation successful')
        except Exception as e:
            print(f'✗ Todo creation failed: {e}')
            return False
        
        # Test creating a todo with empty title
        print("Testing todo creation with empty title...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}', 'Content-Type': 'application/json'}
            req = urllib.request.Request(
                f'http://{host}:{port}/todos',
                data=json.dumps({
                    'title': '',
                    'description': 'This should fail'
                }).encode(),
                headers=headers,
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                print(f'✗ Empty title todo should have failed but got code {response.code}')
                return False
        except urllib.error.HTTPError as e:
            if e.code == 400:
                print('✓ Empty title todo creation correctly failed')
            else:
                print(f'✗ Wrong error code for empty title: {e.code}')
                return False
        except Exception as e:
            print(f'✗ Unexpected error during empty title test: {e}')
            return False
        
        # Test getting all todos
        print("Testing listing todos...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}'}
            req = urllib.request.Request(
                f'http://{host}:{port}/todos',
                headers=headers,
                method='GET'
            )
            with urllib.request.urlopen(req) as response:
                todos_result = json.loads(response.read())
                assert len(todos_result) == 1
                assert todos_result[0]['title'] == 'Buy milk'
                print('✓ Todo listing successful')
        except Exception as e:
            print(f'✗ Todo listing failed: {e}')
            return False
        
        # Test retrieving specific todo
        print("Testing specific todo retrieval...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}'}
            req = urllib.request.Request(
                f'http://{host}:{port}/todos/{todo_id}',
                headers=headers,
                method='GET'
            )
            with urllib.request.urlopen(req) as response:
                todo_result = json.loads(response.read())
                assert todo_result['id'] == todo_id
                assert todo_result['title'] == 'Buy milk'
                print('✓ Specific todo retrieval successful')
        except Exception as e:
            print(f'✗ Specific todo retrieval failed: {e}')
            return False
        
        # Test updating the todo partially
        print("Testing partial todo update...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}', 'Content-Type': 'application/json'}
            req = urllib.request.Request(
                f'http://{host}:{port}/todos/{todo_id}',
                data=json.dumps({
                    'completed': True
                }).encode(),
                headers=headers,
                method='PUT'
            )
            with urllib.request.urlopen(req) as response:
                updated_result = json.loads(response.read())
                assert updated_result['id'] == todo_id
                assert updated_result['title'] == 'Buy milk'
                assert updated_result['completed'] is True
                print('✓ Partial todo update successful')
        except Exception as e:
            print(f'✗ Partial todo update failed: {e}')
            return False
        
        # Test updating the todo fully
        print("Testing full todo update...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}', 'Content-Type': 'application/json'}
            req = urllib.request.Request(
                f'http://{host}:{port}/todos/{todo_id}',
                data=json.dumps({
                    'title': 'Buy almond milk',
                    'description': 'Get unsweetened almond milk',
                    'completed': False
                }).encode(),
                headers=headers,
                method='PUT'
            )
            with urllib.request.urlopen(req) as response:
                updated_result = json.loads(response.read())
                assert updated_result['id'] == todo_id
                assert updated_result['title'] == 'Buy almond milk'
                assert updated_result['description'] == 'Get unsweetened almond milk'
                assert updated_result['completed'] is False
                assert updated_result['updated_at'] != updated_result['created_at']  # Should differ
                print('✓ Full todo update successful')
        except Exception as e:
            print(f'✗ Full todo update failed: {e}')
            return False
        
        # Test changing a password
        print("Testing password change...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}', 'Content-Type': 'application/json'}
            req = urllib.request.Request(
                f'http://{host}:{port}/password',
                data=json.dumps({
                    'old_password': 'password123',
                    'new_password': 'newpassword123'
                }).encode(),
                headers=headers,
                method='PUT'
            )
            with urllib.request.urlopen(req) as response:
                if response.status != 200:
                    print(f'✗ Password change should have succeeded but got code {response.status}')
                    return False
                print('✓ Password change successful')
        except Exception as e:
            print(f'✗ Password change failed: {e}')
            return False
        
        # Test changing password to one that's too short
        print("Testing short password change...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}', 'Content-Type': 'application/json'}
            req = urllib.request.Request(
                f'http://{host}:{port}/password',
                data=json.dumps({
                    'old_password': 'newpassword123',
                    'new_password': 'short'
                }).encode(),
                headers=headers,
                method='PUT'
            )
            with urllib.request.urlopen(req) as response:
                print(f'✗ Short password change should have failed but got code {response.status}')
                return False
        except urllib.error.HTTPError as e:
            if e.code == 400:
                print('✓ Short password change correctly failed')
            else:
                print(f'✗ Wrong error code for short password: {e.code}')
                return False
        except Exception as e:
            print(f'✗ Unexpected error during short password test: {e}')
            return False
        
        # Test login with new password
        print("Testing login with new password...")
        try:
            new_session_cookies: Dict[str, str] = {}
            req = urllib.request.Request(
                f'http://{host}:{port}/login',
                data=json.dumps({
                    'username': 'testuser',
                    'password': 'newpassword123'
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                login_result = json.loads(response.read())
                assert login_result['username'] == 'testuser'
                
                # Extract session cookie from response headers
                cookies = response.headers.get_all('Set-Cookie', [])
                for cookie in cookies:
                    if cookie.startswith('session_id='):
                        session_id = cookie.split(';')[0].split('=')[1]
                        new_session_cookies['session_id'] = session_id
                        break
                
                print('✓ New password login successful')
        except Exception as e:
            print(f'✗ New password login failed: {e}')
            return False
        
        # Test logout
        print("Testing logout...")
        try:
            headers = {'Cookie': f'session_id={new_session_cookies["session_id"]}'}
            req = urllib.request.Request(
                f'http://{host}:{port}/logout',
                headers=headers,
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                assert response.status == 200
                print('✓ Logout successful')
        except Exception as e:
            print(f'✗ Logout failed: {e}')
            return False
        
        # Test accessing data after logout
        print("Testing access after logout...")
        try:
            headers = {'Cookie': f'session_id={new_session_cookies["session_id"]}'}  # Using previous session
            req = urllib.request.Request(
                f'http://{host}:{port}/me',
                headers=headers,
                method='GET'
            )
            with urllib.request.urlopen(req) as response:
                print(f'✗ Access after logout should have failed but got code {response.code}')
                return False
        except urllib.error.HTTPError as e:
            if e.code == 401:
                print('✓ Access after logout correctly failed')
            else:
                print(f'✗ Wrong error code for post-logout access: {e.code}')
                return False
        except Exception as e:
            print(f'✗ Unexpected error during post-logout test: {e}')
            return False
        
        # Log back in after logout to delete the todo
        print("Logging back in to clean up...")
        try:
            new_req = urllib.request.Request(
                f'http://{host}:{port}/login',
                data=json.dumps({
                    'username': 'testuser',
                    'password': 'newpassword123'
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            new_cookies: Dict[str, str] = {}
            with urllib.request.urlopen(new_req) as response:
                cookies = response.headers.get_all('Set-Cookie', [])
                for cookie in cookies:
                    if cookie.startswith('session_id='):
                        session_id = cookie.split(';')[0].split('=')[1]
                        new_cookies['session_id'] = session_id
                        break
        except Exception as e:
            print(f'✗ Cleanup login failed: {e}')
            return False
        
        # Test deleting the todo
        print("Testing todo deletion...")
        try:
            headers = {'Cookie': f'session_id={new_cookies["session_id"]}'}
            req = urllib.request.Request(
                f'http://{host}:{port}/todos/{todo_id}',
                headers=headers,
                method='DELETE'
            )
            with urllib.request.urlopen(req) as response:
                if response.status != 204:
                    print(f'✗ Todo deletion should return 204 but got: {response.status}')
                    return False
                print('✓ Todo deletion successful')
        except Exception as e:
            print(f'✗ Todo deletion failed: {e}')
            return False
        
        # Verify todo is gone
        print("Verifying todo is gone...")
        try:
            headers = {'Cookie': f'session_id={new_cookies["session_id"]}'}
            req = urllib.request.Request(
                f'http://{host}:{port}/todos/{todo_id}',
                headers=headers,
                method='GET'
            )
            with urllib.request.urlopen(req) as response:
                print(f'✗ Deleted todo access should have failed but got code {response.code}')
                return False
        except urllib.error.HTTPError as e:
            if e.code == 404:
                print('✓ Deleted todo properly inaccessible')
            else:
                print(f'✗ Wrong error code for deleted todo access: {e.code}')
                return False
        except Exception as e:
            print(f'✗ Unexpected error when verifying todo deletion: {e}')
            return False
        
        print('All tests passed!')
        return True
    
    finally:
        # Stop the server process
        print('Stopping server...')
        # First try graceful shutdown
        server_process.send_signal(signal.SIGTERM)
        try:
            server_process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            # Force kill if graceful shutdown takes too long
            server_process.kill()
            server_process.wait()


if __name__ == "__main__":
    success = run_tests()
    if not success:
        sys.exit(1)
    sys.exit(0)