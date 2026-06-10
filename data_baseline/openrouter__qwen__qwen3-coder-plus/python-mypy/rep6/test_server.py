#!/usr/bin/env python3
"""
Test script for the Todo API Server.
Tests all endpoints with curl to verify the server works as specified.
"""
import subprocess
import time
import signal
import os
import sys
import json

def start_test_server(port: int = 8000) -> subprocess.Popen:
    """Start the server in background"""
    # Save current working directory
    original_cwd = os.getcwd()
    
    # Start the server process
    server_process = subprocess.Popen([sys.executable, "./server.py", "--port", str(port)])
    
    # Let the server start up  
    time.sleep(3)  # Increased wait time
    
    return server_process

def get_cookie_set_by_header(header_line: str) -> str:
    """Extract session_id from Set-Cookie header line."""
    if 'set-cookie:' in header_line.lower():
        cookie_part = header_line.split('Set-Cookie:', 1)[1].split(';')[0].strip()
        if '=' in cookie_part:
            key, value = cookie_part.split('=', 1)
            if key.strip() == 'session_id':
                return value.strip()
    return ""

def extract_session_id_from_response(curl_stdout: str, curl_stderr: str) -> str:
    """
    Extract session_id from the curl response including both stdout and stderr.
    This handles the verbose output format from curl."""
    combined_output = curl_stdout + "\n" + curl_stderr
    
    for line in combined_output.splitlines():
        # Look for the Set-Cookie header from the server response (in verbose mode)
        if 'Set-Cookie:' in line or 'set-cookie:' in line:
            cookie_part = line.split(':', 1)[1].strip()
            # The whole part might look like: session_id=abc123; Path=/; HttpOnly
            # So we split by semicolon and then take the first part containing the equals
            for cookie_pair in cookie_part.split(';'):
                cookie_pair = cookie_pair.strip()
                if 'session_id=' in cookie_pair and '=' in cookie_pair:
                    return cookie_pair.split('=')[1].strip()
    
    # If not found in Set-Cookie header (verbose output), check if it's in regular output
    try:
        response = json.loads(curl_stdout)
        # If we got JSON back, this likely means the header wasn't captured properly
        # We'd expect Set-Cookie to be handled by curl automatically if we weren't inspecting headers directly
    except:
        pass
        
    return ""

def test_all_endpoints(port: int = 8000) -> bool:
    """Run all endpoint tests"""
    base_url = f"http://localhost:{port}"
    
    print("Testing registration endpoint...")
    # Test POST /register 
    result = subprocess.run([
        'curl', '-X', 'POST', 
        f'{base_url}/register',
        '-H', 'Content-Type: application/json',
        '-d', '{"username": "testuser", "password": "password123"}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0, f"Register failed: {result.stderr}"
    register_resp = json.loads(result.stdout)
    assert register_resp['username'] == 'testuser'
    print("✓ Registration successful")
    
    print("Testing duplicate username registration...")
    # Test duplicate username
    result = subprocess.run([
        'curl', '-X', 'POST', 
        f'{base_url}/register',
        '-H', 'Content-Type: application/json',
        '-d', '{"username": "testuser", "password": "password123"}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    error_resp = json.loads(result.stdout)
    assert 'error' in error_resp
    assert 'already exists' in error_resp['error']
    print("✓ Duplicate username properly rejected")
    
    print("Testing login...")
    # Test POST /login (first with verbose mode to capture Set-Cookie)
    result = subprocess.run([
        'curl', '-X', 'POST', 
        f'{base_url}/login',
        '-H', 'Content-Type: application/json',
        '-d', '{"username": "testuser", "password": "password123"}',
        '-v'  # To see headers including cookies
    ], capture_output=True, text=True)
    
    assert result.returncode == 0, f"Login failed: {result.stderr}"
    # Extract session_id from either output
    session_id = extract_session_id_from_response(result.stdout, result.stderr)
    assert session_id != "", f"No session_id found in login response.\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}\n"
    print(f"✓ Login successful, got session_id: {session_id[:16]}...")
    
    # Create a cookie for future requests
    cookie = f"session_id={session_id}"
    
    print("Testing /me endpoint...")
    # Test GET /me
    result = subprocess.run([
        'curl', '-X', 'GET', 
        f'{base_url}/me',
        '-H', f'Cookie: {cookie}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    user_info = json.loads(result.stdout)
    assert user_info['username'] == 'testuser'
    print("✓ /me endpoint working")
    
    print("Testing unauthenticated access...")
    # Test unauthenticated access to protected endpoint
    result = subprocess.run([
        'curl', '-X', 'GET', 
        f'{base_url}/me'
        # No cookie
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    error_resp = json.loads(result.stdout)
    assert 'error' in error_resp
    # Case-insensitive matching since server returns exact string
    assert 'authentication required' in error_resp['error'].lower()
    print("✓ Authentication properly required")
    
    print("Testing empty todos list...")
    # Test GET /todos for empty list
    result = subprocess.run([
        'curl', '-X', 'GET', 
        f'{base_url}/todos',
        '-H', f'Cookie: {cookie}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    todos = json.loads(result.stdout)
    assert isinstance(todos, list)
    assert len(todos) == 0
    print("✓ Empty todos list returned")
    
    print("Testing todo creation...")
    # Test POST /todos
    result = subprocess.run([
        'curl', '-X', 'POST', 
        f'{base_url}/todos',
        '-H', f'Cookie: {cookie}',
        '-H', 'Content-Type: application/json',
        '-d', '{"title": "First Todo", "description": "My first task"}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    new_todo = json.loads(result.stdout)
    assert new_todo['title'] == 'First Todo'
    assert new_todo['description'] == 'My first task'
    assert new_todo['completed'] is False
    todo_id = new_todo['id']
    print(f"✓ Todo created with ID {todo_id}")
    
    print("Testing todo retrieval...")
    # Test GET /todos/{id}
    result = subprocess.run([
        'curl', '-X', 'GET', 
        f'{base_url}/todos/{todo_id}',
        '-H', f'Cookie: {cookie}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    retrieved_todo = json.loads(result.stdout)
    assert retrieved_todo['id'] == todo_id
    assert retrieved_todo['title'] == 'First Todo'
    print("✓ Individual todo retrieval working")
    
    print("Testing todos list after creation...")
    # Test GET /todos list again
    result = subprocess.run([
        'curl', '-X', 'GET', 
        f'{base_url}/todos',
        '-H', f'Cookie: {cookie}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    todos = json.loads(result.stdout)
    assert len(todos) == 1
    assert todos[0]['id'] == todo_id
    print("✓ Todos list showing newly created todo")
    
    print("Testing todo update...")
    # Test PUT /todos/{id} partial update
    result = subprocess.run([
        'curl', '-X', 'PUT', 
        f'{base_url}/todos/{todo_id}',
        '-H', f'Cookie: {cookie}',
        '-H', 'Content-Type: application/json',
        '-d', '{"completed": true, "description": "Updated task"}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    updated_todo = json.loads(result.stdout)
    assert updated_todo['id'] == todo_id
    assert updated_todo['completed'] is True
    assert updated_todo['description'] == 'Updated task'
    print("✓ Todo update working")
    
    print("Testing todo update without authentication...")
    # Test trying to update another user's todo (should fail) 
    # First register another user
    result = subprocess.run([
        'curl', '-X', 'POST', 
        f'{base_url}/register',
        '-H', 'Content-Type: application/json',
        '-d', '{"username": "otheruser", "password": "password123"}'
    ], capture_output=True, text=True)
    assert result.returncode == 0
    print("✓ Created secondary user")
    
    # Login as other user
    result = subprocess.run([
        'curl', '-X', 'POST', 
        f'{base_url}/login',
        '-H', 'Content-Type: application/json',
        '-d', '{"username": "otheruser", "password": "password123"}',
        '-v'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    other_session_id = extract_session_id_from_response(result.stdout, result.stderr)
    assert other_session_id != ""
    other_cookie = f"session_id={other_session_id}"
    print("✓ Logged in as different user")
    
    # Try to update the first user's todo with second user's session
    result = subprocess.run([
        'curl', '-X', 'PUT', 
        f'{base_url}/todos/{todo_id}',
        '-H', f'Cookie: {other_cookie}',
        '-H', 'Content-Type: application/json',
        '-d', '{"title": "Hacked Todo"}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    error_resp = json.loads(result.stdout)
    assert 'error' in error_resp
    assert 'not found' in error_resp['error'].lower()  # Should be 404, not 403 for security
    print("✓ Properly prevented cross-user todo update")
    
    print("Testing todo deletion...")
    # Go back to original user and delete the todo
    result = subprocess.run([
        'curl', '-X', 'DELETE', 
        f'{base_url}/todos/{todo_id}',
        '-H', f'Cookie: {cookie}'
    ], capture_output=True, text=True)
    
    # For DELETE operations that return 204, check HTTP code and that stdout is empty
    # We can't directly verify 204 via curl's output easily, but if it returns no errors, 
    # assume it worked. We can verify it's gone by trying to get it again:
    
    # Verify todo is deleted by trying to get it
    result = subprocess.run([
        'curl', '-X', 'GET', 
        f'{base_url}/todos/{todo_id}',
        '-H', f'Cookie: {cookie}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    error_resp = json.loads(result.stdout)
    assert 'error' in error_resp
    assert 'not found' in error_resp['error'].lower()
    print("✓ Todo deletion working - verified todo no longer exists")
    
    print("Testing password change...")
    # Test PUT /password (using a cookie from a fresh login of the original user)
    result = subprocess.run([
        'curl', '-X', 'POST', 
        f'{base_url}/login',
        '-H', 'Content-Type: application/json',
        '-d', '{"username": "testuser", "password": "password123"}',
        '-v'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    session_id = extract_session_id_from_response(result.stdout, result.stderr)
    assert session_id != ""
    cookie = f"session_id={session_id}"
    
    result = subprocess.run([
        'curl', '-X', 'PUT', 
        f'{base_url}/password',
        '-H', f'Cookie: {cookie}',
        '-H', 'Content-Type: application/json',
        '-d', '{"old_password": "password123", "new_password": "newpassword123"}'
    ], capture_output=True, text=True)
    
    # Password change should give 200 and an empty response, not necessarily JSON
    # Status can be checked differently with: 
    if result.returncode == 0:
        # Expected: either empty response or empty JSON object
        if result.stdout.strip() in ["{}", ""]:
            print("✓ Password change working")
        else:
            try:
                parsed_output = json.loads(result.stdout) if result.stdout.strip() else {}
                if "error" in parsed_output:
                    print(f"❌ Password change failed: {parsed_output['error']}")
                    return False
            except json.JSONDecodeError:
                print(f"❌ Unexpected response from password change: {result.stdout}")
                return False
    else:
        print(f"❌ Password change command failed: {result.stderr}")
        return False
    
    print("Testing logout...")
    # Test POST /logout
    result = subprocess.run([
        'curl', '-X', 'POST', 
        f'{base_url}/logout',
        '-H', f'Cookie: {cookie}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    # May return empty JSON or actual JSON
    try:
        response = json.loads(result.stdout) if result.stdout.strip() else {}
        if 'error' not in response or response == {}:  # Success case
             print("✓ Logout working")
        else:
            print(f"❌ Logout failed: {response.get('error', 'Unknown error')}")
            return False
    except json.JSONDecodeError:
        print(f"❌ Invalid JSON in logout response: {result.stdout}")
        return False
    
    print("Testing expired session...")
    # After logout, try accessing protected resource with old session
    result = subprocess.run([
        'curl', '-X', 'GET', 
        f'{base_url}/me',
        '-H', f'Cookie: {cookie}'
    ], capture_output=True, text=True)
    
    assert result.returncode == 0
    error_resp = json.loads(result.stdout)
    assert 'error' in error_resp
    assert 'authentication required' in error_resp['error'].lower()
    print("✓ Expired session properly rejected")
    
    print("\n🎉 All tests passed!")
    return True

def main():
    print("Starting Todo API Server Test Suite...")
    
    # Start the server
    print("Starting server...")
    server_process = start_test_server(8002)  # Use different port to avoid conflicts
    
    try:
        # Run tests
        success = test_all_endpoints(8002)
        
        if success:
            print("\n✅ All tests completed successfully!")
        else:
            print("\n❌ Some tests failed!")
            sys.exit(1)
    except Exception as e:
        print(f"❌ Test failed with exception: {str(e)}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
    finally:
        # Stop the server
        print("\nStopping server...")
        server_process.terminate()
        try:
            server_process.wait(timeout=5)  # Wait up to 5 seconds for clean shutdown
        except subprocess.TimeoutExpired:
            # Force kill if not shutting down cleanly
            server_process.kill()
        print("Server stopped.")

if __name__ == '__main__':
    main()