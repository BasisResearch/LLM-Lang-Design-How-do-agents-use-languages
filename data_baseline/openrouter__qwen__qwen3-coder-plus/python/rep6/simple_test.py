#!/usr/bin/env python3
"""
Simple direct test using curl to verify all API endpoints
"""

import subprocess
import sys
import time
import signal
import os
import tempfile
import json


def run_command(cmd, expect_success=True):
    """Run a shell command and return (stdout, status_code) tuple or (error_message, None) on fail"""  
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10) 
        # Extract status code from the end of output if using curl with -w
        stdout = result.stdout
        status_code = None
        
        if cmd.startswith('curl'):
            # Check if using -w flag to append status code
            if '-w ' in cmd and len(stdout) >= 3:
                # Extract last 3 characters as potential status code
                suffix = stdout[-3:]
                if suffix.isdigit():
                    status_code = int(suffix)
                    stdout = stdout[:-3]  # Remove status code from output 
                    
        if result.returncode != 0:
            return f"Command failed with exit code {result.returncode}. Error: {result.stderr}", -1
        return stdout, status_code
    except subprocess.TimeoutExpired:
        return "Command timed out", -1


def test_implementation():
    PORT = 8765
    BASE_URL = f"http://localhost:{PORT}"
    
    # Start the server in background
    print("Starting server...")
    server_process = subprocess.Popen([
        sys.executable, "server.py", "--port", str(PORT)
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    
    # Wait a bit for server to bind
    time.sleep(2)
    
    try:
        print("Running tests...")
        
        # 1. Test registration
        stdout, status_code = run_command(
            f'curl -s -w "201" -X POST {BASE_URL}/register '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"username": "testuser123", "password": "testpassword"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Registration - Command error: {stdout}")
            return False
        if status_code != 201 or '"id"' not in stdout:
            print(f"FAIL: Registration - Expected 201, got {status_code} with response: {stdout}")
            return False
        print("✓ Registration works")
        
        # 2. Test invalid username during registration
        stdout, status_code = run_command(
            f'curl -s -w "400" -X POST {BASE_URL}/register '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"username": "ab", "password": "testpassword"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Invalid username - Command error: {stdout}")
            return False
        if status_code != 400 or "Invalid username" not in stdout:
            print(f"FAIL: Invalid username - Expected 400, got {status_code} with response: {stdout}")
            return False
        print("✓ Invalid username validation works")
        
        # 3. Test short password validation
        stdout, status_code = run_command(
            f'curl -s -w "400" -X POST {BASE_URL}/register '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"username": "testuser456", "password": "weak"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Short password verification - Command error: {stdout}")
            return False
        if status_code != 400 or "Password too short" not in stdout:
            print(f"FAIL: Short password verification - Expected 400, got {status_code} with response: {stdout}")
            return False
        print("✓ Password length validation works")
        
        # 4. Test duplicate username 
        stdout, status_code = run_command(
            f'curl -s -w "409" -X POST {BASE_URL}/register '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"username": "testuser123", "password": "differentpass"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Duplicate username - Command error: {stdout}")
            return False
        if status_code != 409 or "Username already exists" not in stdout:
            print(f"FAIL: Duplicate username - Expected 409, got {status_code} with response: {stdout}")
            return False
        print("✓ Duplicate username handling works")
        
        # 5. Test login success
        stdout, status_code = run_command(
            f'curl -s -c cookies.txt -w "200" -X POST {BASE_URL}/login '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"username": "testuser123", "password": "testpassword"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Login - Command error: {stdout}")
            return False
        if status_code != 200 or '"id"' not in stdout:
            print(f"FAIL: Login - Expected 200, got {status_code} with response: {stdout}")
            return False
        print("✓ Login works")
        
        # 6. Test login with wrong credentials
        stdout, status_code = run_command(
            f'curl -s -w "401" -X POST {BASE_URL}/login '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"username": "testuser123", "password": "wrongpassword"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Wrong credentials - Command error: {stdout}")
            return False
        if status_code != 401 or "Invalid credentials" not in stdout:
            print(f"FAIL: Wrong credentials - Expected 401, got {status_code} with response: {stdout}")
            return False
        print("✓ Invalid credentials handling works")
        
        # 7. Test accessing protected resource without authentication
        stdout, status_code = run_command(
            f'curl -s -w "401" {BASE_URL}/me'
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Unauth access - Command error: {stdout}")
            return False
        if status_code != 401 or "Authentication required" not in stdout:
            print(f"FAIL: Unauth access - Expected 401, got {status_code} with response: {stdout}")
            return False
        print("✓ Unauthenticated access handled correctly")
        
        # 8. Test accessing protected resource WITH authentication using saved cookies
        stdout, status_code = run_command(
            f'curl -s -b cookies.txt -w "200" {BASE_URL}/me'
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Authenticated me access - Command error: {stdout}")
            return False
        if status_code != 200 or '"testuser123"' not in stdout:
            print(f"FAIL: Authenticated me access - Expected 200 with user data, got {status_code} with response: {stdout}")
            return False
        print("✓ Authenticated access works")
        
        # 9. Test password change
        stdout, status_code = run_command(
            f'curl -s -b cookies.txt -w "200" -X PUT {BASE_URL}/password '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"old_password": "testpassword", "new_password": "newsecurepass"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Password change - Command error: {stdout}")
            return False
        if status_code != 200:
            print(f"FAIL: Password change - Expected 200, got {status_code} with response: {stdout}")
            return False
        print("✓ Password change works")
        
        # 10. Test old password no longer works after change
        stdout, status_code = run_command(
            f'curl -s -w "401" -X POST {BASE_URL}/login '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"username": "testuser123", "password": "testpassword"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Old password after change - Command error: {stdout}")
            return False
        if status_code != 401 or "Invalid credentials" not in stdout:
            print(f"FAIL: Old password after change - Expected 401, got {status_code} with response: {stdout}")
            return False
        print("✓ Old password no longer works after change")
        
        # 11. Test new password works after change
        stdout, status_code = run_command(
            f'curl -s -c cookies_after_change.txt -w "200" -X POST {BASE_URL}/login '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"username": "testuser123", "password": "newsecurepass"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: New password after change - Command error: {stdout}")
            return False
        if status_code != 200:
            print(f"FAIL: New password after change - Expected 200, got {status_code} with response: {stdout}")
            return False
        print("✓ New password works after change")
        
        # 12. Test get todos (initially empty)
        stdout, status_code = run_command(
            f'curl -s -b cookies_after_change.txt -w "200" {BASE_URL}/todos'
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Get todos - Command error: {stdout}")
            return False
        # Empty array could be [] or [\n], normalize whitespace
        normalized_response = stdout.replace(" ", "").replace("\n", "").replace("\t", "")
        if status_code != 200 or normalized_response != '[]':
            print(f"FAIL: Get todos - Expected 200 with empty array, got {status_code} with response: {stdout}")
            return False
        print("✓ Get todos (empty) works")
        
        # 13. Test create todo
        stdout, status_code = run_command(
            f'curl -s -b cookies_after_change.txt -w "201" -X POST {BASE_URL}/todos '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"title": "Buy groceries", "description": "Milk, eggs, bread"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Create todo - Command error: {stdout}")
            return False
        if status_code != 201 or '"Buy groceries"' not in stdout:
            print(f"FAIL: Create todo - Expected 201 with todo, got {status_code} with response: {stdout}")
            return False
            
        # Extract todo ID from response for future tests
        try:
            response_data = json.loads(stdout)  # Don't remove status code here since we get just JSON now
            todo_id = response_data.get('id')
            if not todo_id:
                print(f"FAIL: Could not extract todo ID from create response: {stdout}")
                return False
        except:
            print(f"FAIL: Could not parse todo creation response: {stdout}")
            return False
        print("✓ Create todo works")
        
        # 14. Test create todo without title fails
        stdout, status_code = run_command(
            f'curl -s -b cookies_after_change.txt -w "400" -X POST {BASE_URL}/todos '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"title": "", "description": "Should fail"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Create todo with empty title - Command error: {stdout}")
            return False
        if status_code != 400 or "Title is required" not in stdout:
            print(f"FAIL: Create todo with empty title - Expected 400, got {status_code} with response: {stdout}")
            return False
        print("✓ Create todo with empty title fails")
        
        # 15. Test get specific todo
        stdout, status_code = run_command(
            f'curl -s -b cookies_after_change.txt -w "200" {BASE_URL}/todos/{todo_id}'
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Get specific todo - Command error: {stdout}")
            return False
        # Check if the ID exists. Since JSON includes spaces, patterns like '"id": 1' exist
        # We'll use a different approach: parse JSON and verify ID matches
        try:
            todo_data = json.loads(stdout)
            if 'id' not in todo_data or todo_data['id'] != todo_id:
                print(f"FAIL: Get specific todo - Expected todo ID {todo_id}, got response: {stdout}")
                return False
        except:
            print(f"FAIL: Could not parse specific todo response: {stdout}")
            return False
        print("✓ Get specific todo works")
        
        # 16. Test get non-existent todo
        stdout, status_code = run_command(
            f'curl -s -b cookies_after_change.txt -w "404" {BASE_URL}/todos/{todo_id + 1000}'
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Get non-existent todo - Command error: {stdout}")
            return False
        if status_code != 404 or "Todo not found" not in stdout:
            print(f"FAIL: Get non-existent todo - Expected 404, got {status_code} with response: {stdout}")
            return False
        print("✓ Get non-existent todo fails correctly")
        
        # 17. Test update todo
        stdout, status_code = run_command(
            f'curl -s -b cookies_after_change.txt -w "200" -X PUT {BASE_URL}/todos/{todo_id} '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"completed": true, "title": "Updated todo title"}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Update todo - Command error: {stdout}")
            return False
        if status_code != 200:
            print(f"FAIL: Update todo - Expected 200, got {status_code} with response: {stdout}")
            return False
        # Verify the updates were applied properly
        try:
            updated_todo = json.loads(stdout)
            if updated_todo.get('completed') != True or updated_todo.get('title') != "Updated todo title":
                print(f"FAIL: Update todo - Expected completed=True and updated title, got: {stdout}")
                return False
        except:
            print(f"FAIL: Could not parse updated todo response: {stdout}")
            return False
        print("✓ Update todo partial change works")
        
        # 18. Test update todo with empty title
        stdout, status_code = run_command(
            f'curl -s -b cookies_after_change.txt -w "400" -X PUT {BASE_URL}/todos/{todo_id} '
            f'-H "Content-Type: application/json" '
            f'-d \'{{"title": ""}}\''
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Update with empty title - Command error: {stdout}")
            return False
        if status_code != 400 or "Title is required" not in stdout:
            print(f"FAIL: Update with empty title - Expected 400, got {status_code} with response: {stdout}")
            return False
        print("✓ Update with empty title fails correctly")
        
        # 19. Test delete todo 
        # Run DELETE command separately to get status code 
        result = subprocess.run(
            f'curl -s -b cookies_after_change.txt -X DELETE {BASE_URL}/todos/{todo_id} -w "%{{http_code}}"',
            shell=True, capture_output=True, text=True, timeout=10
        )
        
        # Status code will be appended to the output
        full_output = result.stdout
        status_code = int(full_output[-3:]) if full_output and full_output[-3:].isdigit() else 0
        response_content = full_output[:-3] if len(full_output) >= 3 else full_output  # Remove status from end

        if result.returncode != 0 or status_code != 204:
            print(f"FAIL: Delete todo - Expected 204 (no content), got status {status_code} - Full output: '{full_output}')")
            return False
        print("✓ Delete todo works")
        
        # 20. Test deleting already deleted todo
        result_del2 = subprocess.run(
            f'curl -s -b cookies_after_change.txt -X DELETE {BASE_URL}/todos/{todo_id} -w "%{{http_code}}"',
            shell=True, capture_output=True, text=True, timeout=10
        )
    
        full_output2 = result_del2.stdout
        del2_status_code = int(full_output2[-3:]) if full_output2 and full_output2[-3:].isdigit() else 0
        del2_content = full_output2[:-3] if len(full_output2) >= 3 else full_output2

        if result_del2.returncode != 0 or del2_status_code != 404 or "Todo not found" not in del2_content:
            print(f"FAIL: Delete non-existent todo - Expected 404, got status {del2_status_code} with response: {del2_content}")
            return False
        print("✓ Delete non-existent todo fails correctly")
        
        # 21. Test logout
        stdout, status_code = run_command(
            f'curl -s -b cookies_after_change.txt -w "200" -X POST {BASE_URL}/logout'
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Logout - Command error: {stdout}")
            return False
        if status_code != 200:
            print(f"FAIL: Logout - Expected 200, got {status_code} with response: {stdout}")
            return False
        print("✓ Logout works")
        
        # 22. Test accessing protected after logout (should fail)
        stdout, status_code = run_command(
            f'curl -s -b cookies_after_change.txt -w "401" {BASE_URL}/me'
        )
        if isinstance(stdout, str) and 'Error' in stdout:
            print(f"FAIL: Access after logout - Command error: {stdout}")
            return False
        if status_code != 401 or "Authentication required" not in stdout:
            print(f"FAIL: Access after logout - Expected 401, got {status_code} with response: {stdout}")
            return False
        print("✓ Access protected resource after logout fails correctly")
        
        print("\n🎉 All tests passed! 🎉")
        return True
    
    finally:
        # Clean up - kill the server process
        if server_process:
            try:
                server_process.terminate()
                server_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server_process.kill()
            
            # Clean up temp files
            for fname in ['cookies.txt', 'cookies_after_change.txt']:
                try:
                    os.unlink(fname)
                except (FileNotFoundError, OSError):
                    pass  # May not have been created
    
    return False


if __name__ == "__main__":
    success = test_implementation()
    sys.exit(0 if success else 1)