#!/usr/bin/env python3
"""
Comprehensive test for the Todo App server that uses unique user names per run.
"""

import subprocess
import time
import signal
import os
import sys
import uuid 
from typing import Dict, Any
import json
import http.client
import urllib.request
import urllib.error


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


def run_comprehensive_test() -> bool:
    """Run comprehensive tests against the server."""
    port = 8003  # Use a unique port
    unique_suffix = str(uuid.uuid4())[:8]  # Just a short identifier for uniqueness 
    username = f'testuser_{unique_suffix}'
    initial_password = 'initialPass123'
    new_password = 'updatedPass456'
    
    print(f'Starting server on port {port} with unique user {username}...')
    
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
                    'username': username,
                    'password': initial_password
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                user_result = json.loads(response.read())
                assert user_result['username'] == username
                user_id = user_result['id']
                print('✓ Registration successful')
        except Exception as e:
            print(f'✗ Registration failed: {e}')
            return False

        # Test that we can log in with the registered username/password
        print('Testing login...')
        session_cookies: Dict[str, str] = {}
        try:
            req = urllib.request.Request(
                f'http://{host}:{port}/login',
                data=json.dumps({
                    'username': username,
                    'password': initial_password
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                login_result = json.loads(response.read())
                assert login_result['username'] == username
                assert login_result['id'] == user_id
                
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

        # Test access to protected endpoint with auth
        print("Testing authenticated access to profile...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}'}
            req = urllib.request.Request(
                f'http://{host}:{port}/me',
                headers=headers,
                method='GET'
            )
            with urllib.request.urlopen(req) as response:
                me_result = json.loads(response.read())
                assert me_result['username'] == username
                assert me_result['id'] == user_id
                print('✓ Authenticated access to /me successful')
        except Exception as e:
            print(f'✗ Authenticated access to /me failed: {e}')
            return False

        # Test creating a todo
        print("Testing todo creation...")
        todo_id = None
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}', 'Content-Type': 'application/json'}
            req = urllib.request.Request(
                f'http://{host}:{port}/todos',
                data=json.dumps({
                    'title': f'Buy groceries {unique_suffix}',
                    'description': f'Get milk, bread, and eggs for {username}'
                }).encode(),
                headers=headers,
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                todo_result = json.loads(response.read())
                assert todo_result['title'] == f'Buy groceries {unique_suffix}'
                assert todo_result['description'] == f'Get milk, bread, and eggs for {username}'
                todo_id = todo_result['id']
                print('✓ Todo creation successful')
        except Exception as e:
            print(f'✗ Todo creation failed: {e}')
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
                assert todo_result['title'] == f'Buy groceries {unique_suffix}'
                print('✓ Specific todo retrieval successful')
        except Exception as e:
            print(f'✗ Specific todo retrieval failed: {e}')
            return False
            
        # Test listing todos (should return the created todo)
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
                assert todos_result[0]['title'] == f'Buy groceries {unique_suffix}'
                print('✓ Todo listing successful')
        except Exception as e:
            print(f'✗ Todo listing failed: {e}')
            return False

        # Test partial todo update (only mark as completed)
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
                assert updated_result['title'] == f'Buy groceries {unique_suffix}'  # Title unchanged
                assert updated_result['completed'] is True
                assert updated_result['updated_at'] != updated_result['created_at']
                print('✓ Partial todo update successful')
        except Exception as e:
            print(f'✗ Partial todo update failed: {e}')
            return False

        # Test full todo update
        print("Testing full todo update...")
        try:
            headers = {'Cookie': f'session_id={session_cookies["session_id"]}', 'Content-Type': 'application/json'}
            full_update_data = {
                'title': f'Updated groceries task {unique_suffix}',
                'description': f'New detailed description for {username}',
                'completed': False
            }
            req = urllib.request.Request(
                f'http://{host}:{port}/todos/{todo_id}',
                data=json.dumps(full_update_data).encode(),
                headers=headers,
                method='PUT'
            )
            with urllib.request.urlopen(req) as response:
                updated_result = json.loads(response.read())
                assert updated_result['id'] == todo_id
                assert updated_result['title'] == f'Updated groceries task {unique_suffix}'
                assert updated_result['description'] == f'New detailed description for {username}'
                assert updated_result['completed'] is False
                assert updated_result['updated_at'] != updated_result['created_at']
                print('✓ Full todo update successful')
        except Exception as e:
            print(f'✗ Full todo update failed: {e}')
            return False

        # Test changing password
        print("Testing password change...")
        old_session_for_verification = session_cookies["session_id"]
        try:
            headers = {'Cookie': f'session_id={old_session_for_verification}', 'Content-Type': 'application/json'}
            req = urllib.request.Request(
                f'http://{host}:{port}/password',
                data=json.dumps({
                    'old_password': initial_password,
                    'new_password': new_password
                }).encode(),
                headers=headers,
                method='PUT'
            )
            with urllib.request.urlopen(req) as response:
                if response.status != 200:
                    print(f'✗ Password change should have succeeded but got code {response.status}')
                    return False
                print('✓ Password change successful')
                
                # The old session should still be valid since password change doesn't affect open sessions
                headers_verify = {'Cookie': f'session_id={old_session_for_verification}'}
                verify_req = urllib.request.Request(
                    f'http://{host}:{port}/me',
                    headers=headers_verify,
                    method='GET'
                )
                with urllib.request.urlopen(verify_req) as verify_response:
                    verify_result = json.loads(verify_response.read())
                    assert verify_result['username'] == username
                    print('✓ Old session still valid after password change')
                    
        except Exception as e:
            print(f'✗ Password change failed: {e}')
            return False

        print("Testing logout with original session...")
        try:
            headers = {'Cookie': f'session_id={old_session_for_verification}'}
            req = urllib.request.Request(
                f'http://{host}:{port}/logout',
                headers=headers,
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                assert response.status == 200
                print('✓ Logout successful')
                
                # Session should no longer be valid after logout
                verify_headers = {'Cookie': f'session_id={old_session_for_verification}'}
                verify_req = urllib.request.Request(
                    f'http://{host}:{port}/me',
                    headers=verify_headers,
                    method='GET'
                )
                try:
                    with urllib.request.urlopen(verify_req) as verify_response:
                        print(f'✗ Session should be invalid after logout, but got {verify_response.status}')
                        return False
                except urllib.error.HTTPError as verify_e:
                    if verify_e.code == 401:
                        print('✓ Session properly invalidated after logout')
                    else:
                        print(f'✗ Wrong error after logout: {verify_e.code}')
                        return False
        except Exception as e:
            print(f'✗ Logout failed: {e}')
            return False

        # Now log in with new credentials to do final verification 
        print("Testing login with new password after logout...")
        try:
            req = urllib.request.Request(
                f'http://{host}:{port}/login',
                data=json.dumps({
                    'username': username,
                    'password': new_password
                }).encode(),
                headers={'Content-Type': 'application/json'},
                method='POST'
            )
            with urllib.request.urlopen(req) as response:
                login_result = json.loads(response.read())
                assert login_result['username'] == username
                assert login_result['id'] == user_id
                
                # Extract new session cookie
                cookies = response.headers.get_all('Set-Cookie', [])
                new_session_id = None
                for cookie in cookies:
                    if cookie.startswith('session_id='):
                        new_session_id = cookie.split(';')[0].split('=')[1]
                        break
                
                if new_session_id:
                    print('✓ New password login successful')
                    
                    # Verify our todo still exists with correct data via new session
                    verify_headers = {'Cookie': f'session_id={new_session_id}'}
                    verify_req = urllib.request.Request(
                        f'http://{host}:{port}/todos/{todo_id}',
                        headers=verify_headers,
                        method='GET'
                    )
                    with urllib.request.urlopen(verify_req) as verify_response:
                        verify_result = json.loads(verify_response.read())
                        assert verify_result['id'] == todo_id
                        assert verify_result['title'] == f'Updated groceries task {unique_suffix}'
                        print('✓ Todo still accessible and unmodified via new session')
                else:
                    print('✗ Failed to get new session after login')
                    return False
        except Exception as e:
            print(f'✗ New password login failed: {e}')
            return False

        # Final test: Delete the todo and verify it's gone
        print("Testing todo deletion...")
        new_session_for_delete = new_session_id  # Use the latest session
        try:
            headers = {'Cookie': f'session_id={new_session_for_delete}'}
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
                
                # Verify todo is gone
                headers_check = {'Cookie': f'session_id={new_session_for_delete}'}
                check_req = urllib.request.Request(
                    f'http://{host}:{port}/todos/{todo_id}',
                    headers=headers_check,
                    method='GET'
                )
                try:
                    with urllib.request.urlopen(check_req) as check_response:
                        print(f'✗ Deleted todo should be inaccessible but got: {check_response.status}')
                        return False
                except urllib.error.HTTPError as check_e:
                    if check_e.code == 404:
                        print('✓ Deleted todo properly inaccessible')
                    else:
                        print(f'✗ Wrong error code for deleted todo: {check_e.code}')
                        return False
        except Exception as e:
            print(f'✗ Todo deletion failed: {e}')
            return False

        print('All comprehensive tests passed!')
        return True

    finally:
        # Stop the server process
        print('Terminating server process...')
        try:
            server_process.terminate()
            server_process.wait(timeout=5)  # Wait up to 5 seconds
        except subprocess.TimeoutExpired:
            print('Server did not terminate gracefully, killing...')
            server_process.kill()
            server_process.wait()  # Wait for the process to finish dying after forced termination


if __name__ == "__main__":
    success = run_comprehensive_test()
    if not success:
        print("Tests failed!")
        sys.exit(1)
    else:
        print("All tests passed!")
        sys.exit(0)