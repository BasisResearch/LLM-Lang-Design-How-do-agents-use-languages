#!/usr/bin/env python3
import subprocess
import time
import requests
import json
import os
import signal
import sys
from pathlib import Path

# Start server process
server_process = subprocess.Popen(['python3', 'app.py', '--port', '9999'])

# Wait a bit for server to start
time.sleep(2)

try:
    # Test variables to track cookies between requests
    cookies = {}

    print("Testing Registration...")
    
    # Test 1: Register a user
    reg_resp = requests.post('http://localhost:9999/register',
                            json={'username': 'testuser', 'password': 'password123'})
    assert reg_resp.status_code == 201, f"Expected 201, got {reg_resp.status_code}: {reg_resp.text}"
    reg_data = reg_resp.json()
    expected_fields = ['id', 'username']
    for field in expected_fields:
        assert field in reg_data, f"Missing field '{field}' in registration response"
    assert reg_data['username'] == 'testuser', f"Expected username 'testuser', got {reg_data['username']}"
    assert isinstance(reg_data['id'], int), f"Expected id to be integer, got {type(reg_data['id'])}"
    print("✓ Registration successful")
    
    # Test 2: Register duplicate user (should fail)
    dup_reg_resp = requests.post('http://localhost:9999/register',
                                json={'username': 'testuser', 'password': 'password123'})
    assert dup_reg_resp.status_code == 409, f"Expected 409 conflict, got {dup_reg_resp.status_code}: {dup_reg_resp.text}"
    print("✓ Duplicate registration correctly rejected")

    # Test 3: Login 
    login_resp = requests.post('http://localhost:9999/login',
                              json={'username': 'testuser', 'password': 'password123'})
    assert login_resp.status_code == 200, f"Expected 200, got {login_resp.status_code}: {login_resp.text}"
    assert 'session_id' in login_resp.cookies, "Expected session cookie in login response"
    
    # Save the session cookie for continued testing
    cookies = {'session_id': login_resp.cookies['session_id']}
    login_data = login_resp.json()
    assert login_data['username'] == 'testuser', f"Expected username 'testuser', got {login_data['username']}"
    print("✓ Login successful")
    
    # Test 4: Access protected /me endpoint
    me_resp = requests.get('http://localhost:9999/me', cookies=cookies)
    assert me_resp.status_code == 200, f"Expected 200, got {me_resp.status_code}: {me_resp.text}"
    me_data = me_resp.json()
    assert me_data["username"] == "testuser", f"Expected username 'testuser', got {me_data['username']}"
    print("✓ Protected /me endpoint accessible with valid session")
    
    # Test 5: Access protected endpoint without session (should fail)
    no_auth_resp = requests.get('http://localhost:9999/me')
    assert no_auth_resp.status_code == 401, f"Expected 401 unauthorized, got {no_auth_resp.status_code}: {no_auth_resp.text}"
    error_data = no_auth_resp.json()
    assert 'error' in error_data and 'Authentication required' in error_data['error'], \
           f"Expected auth error message, got {error_data}"
    print("✓ Unauthorized access correctly rejected")
    
    # Test 6: Create a todo item
    new_todo_data = {'title': 'Test Todo', 'description': 'A sample todo item'}
    create_resp = requests.post('http://localhost:9999/todos', json=new_todo_data, cookies=cookies)
    assert create_resp.status_code == 201, f"Expected 201 created, got {create_resp.status_code}: {create_resp.text}"
    created_todo = create_resp.json()
    
    for field in ['id', 'title', 'description', 'completed', 'created_at', 'updated_at']:
        assert field in created_todo, f"Missing field '{field}' in created todo"
    
    assert created_todo['title'] == 'Test Todo'
    assert created_todo['description'] == 'A sample todo item'
    assert created_todo['completed'] == False
    print("✓ Todo creation successful")

    # Test 7: Get the specific todo
    todo_id = created_todo['id']
    get_single_resp = requests.get(f'http://localhost:9999/todos/{todo_id}', cookies=cookies)
    assert get_single_resp.status_code == 200, f"Expected 200, got {get_single_resp.status_code}: {get_single_resp.text}"
    retrieved_todo = get_single_resp.json()
    assert retrieved_todo['id'] == todo_id
    assert retrieved_todo['title'] == 'Test Todo'
    print("✓ Getting specific todo successful")

    # Test 8: List all todos
    list_resp = requests.get('http://localhost:9999/todos', cookies=cookies)
    assert list_resp.status_code == 200, f"Expected 200, got {list_resp.status_code}: {list_resp.text}"
    todo_list = list_resp.json()
    assert len(todo_list) == 1, f"Expected 1 todo, got {len(todo_list)}"
    assert todo_list[0]['id'] == todo_id
    print("✓ Todo listing successful")

    # Test 9: Update todo partially
    update_data = {'completed': True, 'title': 'Updated Test Todo'}
    update_resp = requests.put(f'http://localhost:9999/todos/{todo_id}', json=update_data, cookies=cookies)
    assert update_resp.status_code == 200, f"Expected 200, got {update_resp.status_code}: {update_resp.text}"
    updated_todo = update_resp.json()
    assert updated_todo['title'] == 'Updated Test Todo'
    assert updated_todo['completed'] == True
    assert updated_todo['id'] == todo_id  # Should still have same id
    print("✓ Partial todo update successful")

    # Test 10: Delete the todo
    delete_resp = requests.delete(f'http://localhost:9999/todos/{todo_id}', cookies=cookies)
    assert delete_resp.status_code == 204, f"Expected 204, got {delete_resp.status_code}: {delete_resp.text}"
    assert delete_resp.content == b'', "DELETE should have no body"
    print("✓ Todo deletion successful")

    # Confirm todo is gone
    check_deleted_resp = requests.get(f'http://localhost:9999/todos/{todo_id}', cookies=cookies)
    assert check_deleted_resp.status_code == 404, f"Expected 404 after deletion, got {check_deleted_resp.status_code}: {check_deleted_resp.text}"
    print("✓ Deleted todo correctly not found")

    # Test 11: Password update
    pwd_update_resp = requests.put('http://localhost:9999/password',
                                  json={'old_password': 'password123', 'new_password': 'newpassword456'},
                                  cookies=cookies)
    assert pwd_update_resp.status_code == 200, f"Expected 200, got {pwd_update_resp.status_code}: {pwd_update_resp.text}"
    print("✓ Password update successful")
    
    # Test 12: Logout
    logout_resp = requests.post('http://localhost:9999/logout', cookies=cookies)
    assert logout_resp.status_code == 200, f"Expected 200, got {logout_resp.status_code}: {logout_resp.text}"
    print("✓ Logout successful")
    
    # Verify session is really invalidated
    post_logout_resp = requests.get('http://localhost:9999/me', cookies=cookies)
    assert post_logout_resp.status_code == 401, f"Expected 401 after logout, got {post_logout_resp.status_code}: {post_logout_resp.text}"
    print("✓ Session properly invalidated after logout")

    # Test edge cases
    print("Testing edge cases...")
    
    # First test without valid session - should return 401 
    bad_todo_resp = requests.post("http://localhost:9999/todos", json={}, cookies={})  
    assert bad_todo_resp.status_code == 401, f"Expected 401 for not logged in, got {bad_todo_resp.status_code}: {bad_todo_resp.text}" 
    # Now test with valid session and missing title - should return 400 
    login_for_edge_case = requests.post("http://localhost:9999/login",  
                                       json={"username": "testuser", "password": "newpassword456"})  
    valid_cookies = {"session_id": login_for_edge_case.cookies["session_id"]}  
    bad_todo_resp = requests.post("http://localhost:9999/todos", json={}, cookies=valid_cookies)  
    assert bad_todo_resp.status_code == 400, f"Expected 400 for missing title, got {bad_todo_resp.status_code}: {bad_todo_resp.text}"  
    error_msg = bad_todo_resp.json()["error"]  
    assert "Title is required" in error_msg, f"Expected title error, got {error_msg}"  
    print("✓ Missing title validation works")
    # Create fresh credentials for login test
    requests.post('http://localhost:9999/register',
                 json={'username': 'testuser2', 'password': 'password456'})
    
    bad_login_resp = requests.post('http://localhost:9999/login',
                                  json={'username': 'nonexistent', 'password': 'wrongpass'})
    assert bad_login_resp.status_code == 401, f"Expected 401 for wrong login, got {bad_login_resp.status_code}: {bad_login_resp.text}"
    assert 'Invalid credentials' in bad_login_resp.json()['error'], \
        f"Expected credentials error, got {bad_login_resp.json()}"
    print("✓ Invalid login rejected")
    
    # Create another user and verify separation
    req_session = requests.Session()
    register_resp = req_session.post('http://localhost:9999/register',
                                   json={'username': 'seconduser', 'password': 'password789'})
    login_resp2 = req_session.post('http://localhost:9999/login',
                                 json={'username': 'seconduser', 'password': 'password789'})
    
    # Create todo for second user
    todo_resp = req_session.post('http://localhost:9999/todos',
                               json={'title': 'Second User Todo', 'description': 'For second user only'})
    second_user_todo_id = todo_resp.json()['id']
    
    # Switch back to first user and try accessing second user's todo (should fail)
    first_user_login = requests.post('http://localhost:9999/login',
                                    json={'username': 'testuser', 'password': 'newpassword456'})
    first_user_cookies = {'session_id': first_user_login.cookies['session_id']}
    
    other_users_todo = requests.get(f'http://localhost:9999/todos/{second_user_todo_id}', 
                                   cookies=first_user_cookies)
    assert other_users_todo.status_code == 404, f"Expected 404 for other user's todo, got {other_users_todo.status_code}: {other_users_todo.text}"
    print("✓ Cross-user data isolation works correctly")
    
    print("All tests passed! ✅")

except Exception as e:
    print(f"❌ Test failed: {repr(e)}")
    print(f"Details: {str(e)}")
    sys.exit(1)
except AssertionError as e:
    print(f"❌ Assertion failed: {e}")
    sys.exit(1)
finally:
    # Clean up: terminate the server
    server_process.terminate()
    server_process.wait()