#!/usr/bin/env python3
import subprocess
import time
import requests
import json
import os
import signal
import tempfile

def test_all_endpoints():
    # Start server on random high port
    port = 9001 
    cmd = ["./run.sh", "--port", str(port)]
    server_process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    
    # Give it time to start
    time.sleep(2)
    
    base_url = f"http://localhost:{port}"
    
    try:
        print("Testing /register endpoint...")
        # Test register
        resp = requests.post(f"{base_url}/register", json={
            "username": "testuser",
            "password": "password123"
        })
        print(f"Register: {resp.status_code}, {resp.json()}")
        assert resp.status_code == 201
        assert resp.json()["username"] == "testuser"
        
        # Test duplicate registration failure
        resp_dup = requests.post(f"{base_url}/register", json={
            "username": "testuser",
            "password": "password123"
        })
        print(f"Duplicate Register: {resp_dup.status_code}, {resp_dup.json()}")
        assert resp_dup.status_code == 409  # Conflict: Already exists
        
        # Test register with bad name
        resp_bad = requests.post(f"{base_url}/register", json={
            "username": "ab",
            "password": "password123"
        })
        print(f"Bad Username Register: {resp_bad.status_code}, {resp_bad.json()}")
        assert resp_bad.status_code == 400  # Bad request: Invalid username
        
        # Test login
        print("\nTesting /login endpoint...")
        login_resp = requests.post(f"{base_url}/login", json={
            "username": "testuser",
            "password": "password123"
        })
        print(f"Login: {login_resp.status_code}, {login_resp.json()}")
        assert login_resp.status_code == 200
        session_cookie = {c.name: c.value for c in login_resp.cookies}["session_id"]
        cookies = {"session_id": session_cookie}
        
        # Test auth protected operations
        print("\nTesting authentication required endpoints...")
        resp_fail = requests.get(f"{base_url}/me")  # No cookies
        print(f"Unauth Me: {resp_fail.status_code}, {resp_fail.json()}")
        assert resp_fail.status_code == 401  # Should fail
        
        # Test /me with session
        me_resp = requests.get(f"{base_url}/me", cookies=cookies)
        print(f"Auth'ed Me: {me_resp.status_code}, {me_resp.json()}")
        assert me_resp.status_code == 200
        assert me_resp.json()["username"] == "testuser"
        
        # Test /todos without auth
        resp_todos_fail = requests.get(f"{base_url}/todos")
        print(f"Unauth Todos: {resp_todos_fail.status_code}, {resp_todos_fail.json()}")
        assert resp_todos_fail.status_code == 401  # Should fail
        
        # Create a todo
        print("\nTesting /todos creation...")
        todo_resp = requests.post(f"{base_url}/todos", 
                                  cookies=cookies,
                                  json={"title": "First todo", "description": "A test todo"})
        print(f"Create Todo: {todo_resp.status_code}, {todo_resp.json()}")
        assert todo_resp.status_code == 201
        assert todo_resp.json()["title"] == "First todo"
        
        todo_id = todo_resp.json()["id"]
        
        # Fetch user's specific todo
        get_todo_resp = requests.get(f"{base_url}/todos/{todo_id}", cookies=cookies)
        print(f"Get Specific Todo: {get_todo_resp.status_code}, {get_todo_resp.json()}")
        assert get_todo_resp.status_code == 200
        assert get_todo_resp.json()["id"] == todo_id
        
        # Try to fetch other user's todo (doesn't apply here since only 1 user, but test for non-existent)
        wrong_id_resp = requests.get(f"{base_url}/todos/999", cookies=cookies)
        print(f"Non-exist Todo: {wrong_id_resp.status_code}, {wrong_id_resp.json()}")
        assert wrong_id_resp.status_code == 404  # Not found
        
        # Update todo
        print("\nTesting todo updating...")
        update_resp = requests.put(f"{base_url}/todos/{todo_id}",
                                   cookies=cookies,
                                   json={"title": "Updated Todo", "completed": True})
        print(f"Update Todo: {update_resp.status_code}, {update_resp.json()}")
        assert update_resp.status_code == 200
        assert update_resp.json()["completed"] is True
        assert update_resp.json()["title"] == "Updated Todo"
        
        # Fetch all todos
        all_todos_resp = requests.get(f"{base_url}/todos", cookies=cookies)
        print(f"All Todos: {all_todos_resp.status_code}, {all_todos_resp.json()}")
        assert all_todos_resp.status_code == 200
        assert len(all_todos_resp.json()) == 1
        
        # Test PUT /password functionality
        print("\nTesting password change...")
        pass_change_resp = requests.put(f"{base_url}/password",
                               cookies=cookies,
                               json={
                                   "old_password": "password123",
                                   "new_password": "newpass123"
                               })
        print(f"Password Change: {pass_change_resp.status_code}, {pass_change_resp.json()}")
        assert pass_change_resp.status_code == 200
        
        # Try old password for login (should fail)
        old_login_resp = requests.post(f"{base_url}/login", json={
            "username": "testuser",
            "password": "password123"
        })
        print(f"Old Pass Login: {old_login_resp.status_code}")
        assert old_login_resp.status_code == 401  # Should fail now
        
        # Try with new password (should work)
        new_login_resp = requests.post(f"{base_url}/login", json={
            "username": "testuser",
            "password": "newpass123"
        })
        print(f"New Pass Login: {new_login_resp.status_code}")
        assert new_login_resp.status_code == 200  # Should work now
        
        # Delete Todo
        print("\nTesting todo deletion...")
        delete_resp = requests.delete(f"{base_url}/todos/{todo_id}", cookies=cookies)
        print(f"Delete Todo: {delete_resp.status_code}")
        assert delete_resp.status_code == 204  # No content
        
        # Try to fetch deleted todo
        post_delete_resp = requests.get(f"{base_url}/todos/{todo_id}", cookies=cookies)
        print(f"Post-delete Fetch: {post_delete_resp.status_code}, {post_delete_resp.json()}")
        assert post_delete_resp.status_code == 404  # Now 404
        
        # Test logout
        print("\nTesting logout...")
        logout_resp = requests.post(f"{base_url}/logout", cookies=cookies)
        print(f"Logout: {logout_resp.status_code}, {logout_resp.json()}")
        assert logout_resp.status_code == 200
        
        # Try accessing /me after logout (should fail)
        post_logout_resp = requests.get(f"{base_url}/me", cookies=cookies)
        print(f"Post-logout Access: {post_logout_resp.status_code}, {post_logout_resp.json()}")
        assert post_logout_resp.status_code == 401  # Should fail after logout
        
        print("\n✓ All tests passed!")
        
    except Exception as e:
        print(f"\n✗ Test failed: {e}")
        raise
    finally:
        # Kill the server
        server_process.terminate()
        try:
            server_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server_process.kill()

if __name__ == "__main__":
    test_all_endpoints()
