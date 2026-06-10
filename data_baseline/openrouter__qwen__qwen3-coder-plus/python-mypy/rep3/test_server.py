#!/usr/bin/env python3
import subprocess
import time
import threading
import requests
import json
import tempfile
import os
from pathlib import Path

def run_test():
    print("Starting server tests...")
    
    # Kill any existing server processes 
    os.system("pkill -f server.py || true")
    
    # Start the server in a subprocess
    cmd = ["python3", "server.py", "--port", "8888"]
    server_process = subprocess.Popen(cmd)
    
    # Give it a moment to start up
    time.sleep(2)
    
    try:
        # Test variables to track session between requests
        session_cookies = {}
        
        # Helper method to handle cookies across requests
        s = requests.Session()
        
        # Test 1: POST /register
        print("\n=== TEST 1: POST /register ===")
        register_data = {"username": "testuser", "password": "password123"}
        response = s.post("http://localhost:8888/register", json=register_data)
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 201
        assert "id" in response.json()
        assert response.json()["username"] == "testuser"
        print("✓ Register test passed")
        
        # Test 2: POST /register with invalid username (too short)
        print("\n=== TEST 2: POST /register (invalid username) ===")
        invalid_register_data = {"username": "ab", "password": "password123"} 
        response = s.post("http://localhost:8888/register", json=invalid_register_data)
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 400
        assert "error" in response.json()
        assert "Invalid username" in response.json()["error"]
        print("✓ Invalid username test passed")
        
        # Test 3: POST /register with weak password (too short)
        print("\n=== TEST 3: POST /register (weak password) ===")
        weak_password_data = {"username": "validuser", "password": "short"}
        response = s.post("http://localhost:8888/register", json=weak_password_data)
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 400
        assert "error" in response.json() 
        assert "Password too short" in response.json()["error"]
        print("✓ Weak password test passed")
        
        # Test 4: POST /login
        print("\n=== TEST 4: POST /login ===")
        login_data = {"username": "testuser", "password": "password123"}
        response = s.post("http://localhost:8888/login", json=login_data)
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 200
        assert response.json()["username"] == "testuser"
        print("✓ Login test passed")
        
        # Test 5: GET /me (authenticated)
        print("\n=== TEST 5: GET /me (authenticated) ===")
        response = s.get("http://localhost:8888/me")
        print(f"Status: {response.status_code}") 
        print(f"Response: {response.json()}")
        
        assert response.status_code == 200
        assert response.json()["username"] == "testuser"
        print("✓ Get profile test passed")
        
        # Test 6: POST /todos (create todo)
        print("\n=== TEST 6: POST /todos ===")
        todo_data = {
            "title": "Test Todo",
            "description": "This is a test todo item."
        }
        response = s.post("http://localhost:8888/todos", json=todo_data)
        print(f"Status: {response.status_code}")
        print(f"Response keys: {list(response.json().keys())}")
        print(f"Title: {response.json()['title']}, Description: {response.json()['description']}")
        print(f"Completed: {response.json()['completed']}, IDs: {response.json()['id']}")
        
        assert response.status_code == 201
        assert response.json()["title"] == "Test Todo"
        assert response.json()["description"] == "This is a test todo item."
        assert response.json()["completed"] is False
        assert "id" in response.json()
        todo_id = response.json()["id"]  # Save for later tests
        print(f"✓ New todo created with ID: {todo_id}")
        
        # Test 7: GET /todos (list todos)
        print(f"\n=== TEST 7: GET /todos ===") 
        response = s.get("http://localhost:8888/todos")
        print(f"Status: {response.status_code}")
        print(f"Response: {len(response.json())} todos found")
        if len(response.json()) > 0:
            print(f"First todo - ID: {response.json()[0]['id']}, Title: {response.json()[0]['title']}")
        
        assert response.status_code == 200
        assert len(response.json()) == 1
        assert response.json()[0]["id"] == todo_id
        print("✓ Todo listing test passed")
        
        # Test 8: GET /todos/:id (get single todo)
        print(f"\n=== TEST 8: GET /todos/{todo_id} ===")
        response = s.get(f"http://localhost:8888/todos/{todo_id}")
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 200
        assert response.json()["id"] == todo_id
        assert response.json()["title"] == "Test Todo"
        print("✓ Single todo retrieval test passed")
        
        # Test 9: PUT /todos/:id (update todo)
        print(f"\n=== TEST 9: PUT /todos/{todo_id} ===")
        update_data = {
            "title": "Updated Test Todo",
            "completed": True
        }
        response = s.put(f"http://localhost:8888/todos/{todo_id}", json=update_data)
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 200
        assert response.json()["title"] == "Updated Test Todo"
        assert response.json()["completed"] is True
        print("✓ Todo update test passed")
        
        # Verify update worked
        print(f"\n--- Verifying update ---")
        response = s.get(f"http://localhost:8888/todos/{todo_id}")
        assert response.json()["title"] == "Updated Test Todo"
        assert response.json()["completed"] is True
        assert "updated_at" in response.json()
        print("✓ Update verification passed")
        
        # Test 10: PUT /password
        print(f"\n=== TEST 10: PUT /password ===")
        password_data = {
            "old_password": "password123",
            "new_password": "newpassword123"
        }
        response = s.put("http://localhost:8888/password", json=password_data)
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 200
        print("✓ Password change test passed")
        
        # Test password change verification by logging out and trying to log back in
        print(f"\n--- Testing login with old password (should fail) ---")
        old_pass_login = {"username": "testuser", "password": "password123"}
        temp_session = requests.Session()
        response = temp_session.post("http://localhost:8888/login", json=old_pass_login)
        assert response.status_code == 401, "Login should fail with old password after change"
        print("✓ Old password verification passed")
        
        # Log in with new password 
        print(f"\n--- Testing login with new password (should succeed) ---")
        new_pass_login = {"username": "testuser", "password": "newpassword123"}
        response = s.post("http://localhost:8888/login", json=new_pass_login)
        assert response.status_code == 200, "Login should succeed with new password"
        print("✓ New password verification passed")
        
        # Test 11: DELETE /todos/:id
        print(f"\n=== TEST 11: DELETE /todos/{todo_id} ===")
        response = s.delete(f"http://localhost:8888/todos/{todo_id}")
        print(f"Status: {response.status_code}")
        print(f"Response: {response.text}")
        
        assert response.status_code == 204
        print("✓ Todo deletion test passed")
        
        # Verify deletion
        print(f"\n--- Verifying deletion ---") 
        response = s.get(f"http://localhost:8888/todos/{todo_id}")
        assert response.status_code == 404
        assert "error" in response.json()
        assert "not found" in response.json()["error"].lower()
        print("✓ Deletion verification passed")
        
        # Test 12: POST /logout
        print(f"\n=== TEST 12: POST /logout ===")
        response = s.post("http://localhost:8888/logout")
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 200
        print("✓ Logout test passed")
        
        # Test 13: Try accessing protected resource without auth (GET /me)
        print(f"\n=== TEST 13: GET /me without Auth (verify logout worked) ===")
        unauth_response = requests.get("http://localhost:8888/me")  # fresh session
        print(f"Status: {unauth_response.status_code}")
        print(f"Response: {unauth_response.json()}")
        
        assert unauth_response.status_code == 401
        assert "error" in unauth_response.json()
        assert "Authentication required" in unauth_response.json()["error"]  
        print("✓ Authentication required test passed")
        
        # Test 14: Test title validation (empty title for create)
        print(f"\n=== TEST 14: POST /todos (missing title) ===")
        bad_todo_data = {
            "description": "A todo with empty title"
        }
        # Relogin to create another todo
        s.post("http://localhost:8888/login", json={"username": "testuser", "password": "newpassword123"})
        response = s.post("http://localhost:8888/todos", json=bad_todo_data) 
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 400
        assert "error" in response.json()
        assert "Title is required" in response.json()["error"]
        print("✓ Missing title test passed")
        
        # Test 15: Test title validation (empty title for update)
        print(f"\n=== TEST 15: PUT /todos (empty title update) ===")
        new_todo_data = {"title": "Valid Test Todo", "description": "desc"}
        create_resp = s.post("http://localhost:8888/todos", json=new_todo_data)
        assert create_resp.status_code == 201
        new_todo_id = create_resp.json()["id"]
        
        empty_title_data = {"title": ""}  # Empty title in update
        response = s.put(f"http://localhost:8888/todos/{new_todo_id}", json=empty_title_data)
        print(f"Status: {response.status_code}")
        print(f"Response: {response.json()}")
        
        assert response.status_code == 400
        assert "error" in response.json()
        assert "Title is required" in response.json()["error"]
        
        # Clean up this test todo
        s.delete(f"http://localhost:8888/todos/{new_todo_id}")
        print("✓ Empty title update test passed")
        
        print("\n🎉 ALL TESTS PASSED! 🎉")
        
    except Exception as e:
        print(f"\n❌ TEST FAILED: {e}")
        import traceback
        traceback.print_exc() 
        
    finally:
        # Terminate the server process
        server_process.terminate()
        server_process.wait()
        print("\nServer terminated.")

if __name__ == "__main__":
    run_test()