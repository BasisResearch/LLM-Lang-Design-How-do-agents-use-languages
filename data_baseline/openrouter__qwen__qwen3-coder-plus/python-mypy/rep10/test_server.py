#!/usr/bin/env python3
"""
Test script for the Todo REST API server
"""
import subprocess
import time
import json
import requests
from typing import Dict, Any, Optional

def test_all_endpoints():
    # Start the server process
    print("Starting the server...")
    server_process = subprocess.Popen(['./run.sh', '--port', '8080'])
    
    # Wait for server to start
    time.sleep(2)
    
    try:
        base_url = 'http://localhost:8080'
        cookies: Optional[requests.cookies.RequestsCookieJar] = None
        
        print("\n=== Testing POST /register ===")
        # Test register
        reg_data = {
            "username": "testuser",
            "password": "verysecure123"
        }
        response = requests.post(f"{base_url}/register", json=reg_data)
        print(f"Register status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 201
        assert response.json()["username"] == "testuser"
        user_id = response.json()["id"]
        
        print("\n=== Testing duplicate register (should fail) ===")
        # Test duplicate register
        dup_reg_data = {
            "username": "testuser",  # Already exists
            "password": "anotherpassword123"
        }
        response = requests.post(f"{base_url}/register", json=dup_reg_data)
        print(f"Duplicate register status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 409
        assert response.json()["error"] == "Username already exists"
        
        print("\n=== Testing POST /login ===")
        # Test login
        login_data = {
            "username": "testuser",
            "password": "verysecure123"
        }
        response = requests.post(f"{base_url}/login", json=login_data)
        print(f"Login status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 200
        assert response.json()["id"] == user_id
        cookies = response.cookies
        print(f"Got cookies: {cookies}")
        
        print("\n=== Testing GET /me ===")
        # Test get current user
        response = requests.get(f"{base_url}/me", cookies=cookies)
        print(f"GET /me status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 200
        assert response.json()["id"] == user_id
        
        print("\n=== Testing auth-protected endpoint without auth ===")
        # Test without auth
        response = requests.get(f"{base_url}/me")
        print(f"GET /me without auth status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 401
        assert response.json()["error"] == "Authentication required"
        
        print("\n=== Testing GET /todos (empty list) ===")
        # Test get todos (should be empty initially)
        response = requests.get(f"{base_url}/todos", cookies=cookies)
        print(f"GET /todos status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 200
        assert response.json() == []
        
        print("\n=== Testing POST /todos ===")
        # Test create todo
        todo_data = {
            "title": "First todo task",
            "description": "This is a sample todo item"
        }
        response = requests.post(f"{base_url}/todos", json=todo_data, cookies=cookies)
        print(f"POST /todos status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 201
        first_todo_id = response.json()["id"]
        assert response.json()["title"] == "First todo task"
        assert response.json()["description"] == "This is a sample todo item"
        assert response.json()["completed"] is False  # Default value
        
        print("\n=== Testing second POST /todos ===")
        # Create another todo
        todo_data2 = {
            "title": "Second todo task",
            "description": "Another sample todo"
        }
        response = requests.post(f"{base_url}/todos", json=todo_data2, cookies=cookies)
        print(f"POST /todos 2 status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 201
        second_todo_id = response.json()["id"]
        assert second_todo_id > first_todo_id
        
        print("\n=== Testing GET /todos (with items) ===")
        # Test get todos (should now contain two tasks)
        response = requests.get(f"{base_url}/todos", cookies=cookies)
        print(f"GET /todos after creating tasks status: {response.status_code}, count: {len(response.json())}")
        assert response.status_code == 200
        assert len(response.json()) == 2
        # Should be sorted by id - first is smaller than second
        assert response.json()[0]["id"] == first_todo_id
        assert response.json()[1]["id"] == second_todo_id
        
        print("\n=== Testing GET /todos/:id ===")
        # Test get specific todo
        response = requests.get(f"{base_url}/todos/{first_todo_id}", cookies=cookies)
        print(f"GET /todos/{first_todo_id} status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 200
        assert response.json()["id"] == first_todo_id
        assert response.json()["title"] == "First todo task"
        
        print("\n=== Testing GET /todos non-existent ID ===")
        # Test getting non-existent todo
        response = requests.get(f"{base_url}/todos/999", cookies=cookies)
        print(f"GET /todos/999 status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 404
        assert response.json()["error"] == "Todo not found"
        
        print("\n=== Testing PUT /todos/:id (update) ===")
        # Test updating a todo
        update_data = {
            "title": "Updated First todo task",
            "completed": True
        }
        response = requests.put(f"{base_url}/todos/{first_todo_id}", json=update_data, cookies=cookies)
        print(f"PUT /todos/{first_todo_id} status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 200
        assert response.json()["id"] == first_todo_id
        assert response.json()["title"] == "Updated First todo task"
        assert response.json()["completed"] is True
        
        print("\n=== Testing PUT /todos/:id validation ===")
        # Test updating with empty title (should fail)
        bad_update_data = {
            "title": ""
        }
        response = requests.put(f"{base_url}/todos/{first_todo_id}", json=bad_update_data, cookies=cookies)
        print(f"PUT /todos/{first_todo_id} bad title status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 400
        assert response.json()["error"] == "Title is required"
        
        print("\n=== Testing DELETE /todos/:id ===")
        # Test deleting a todo
        response = requests.delete(f"{base_url}/todos/{first_todo_id}", cookies=cookies)
        print(f"DELETE /todos/{first_todo_id} status: {response.status_code}")
        assert response.status_code == 204
        
        print("\n=== Testing GET /todos/:id after deletion ===")
        # Try to get deleted todo (should fail)
        response = requests.get(f"{base_url}/todos/{first_todo_id}", cookies=cookies)
        print(f"GET /todos/{first_todo_id} after delete status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 404
        assert response.json()["error"] == "Todo not found"
        
        print("\n=== Testing PUT /password ===")
        # Change password
        pwd_change_data = {
            "old_password": "verysecure123",
            "new_password": "newverysecure456"
        }
        response = requests.put(f"{base_url}/password", json=pwd_change_data, cookies=cookies)
        print(f"PUT /password status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 200
        
        print("\n=== Testing login with OLD password (should fail) ===")
        # Try logging in with old password (should fail)
        bad_login_data = {
            "username": "testuser",
            "password": "verysecure123"  # Old password
        }
        response = requests.post(f"{base_url}/login", json=bad_login_data)
        print(f"Login with old password status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 401
        assert response.json()["error"] == "Invalid credentials"
        
        print("\n=== Testing login with NEW password ===")
        # Login with new password (should work)
        good_login_data = {
            "username": "testuser",
            "password": "newverysecure456"  # New password
        }
        response = requests.post(f"{base_url}/login", json=good_login_data)
        print(f"Login with new password status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 200
        assert response.json()["id"] == user_id
        
        # Get new cookies for logout
        new_cookies = response.cookies
        
        print("\n=== Testing POST /logout ===")
        # Test logout
        response = requests.post(f"{base_url}/logout", cookies=new_cookies)
        print(f"Logout status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 200
        assert response.json() == {}
        
        print("\n=== Testing /me after logout ===")
        # Test trying to access protected resource after logout
        response = requests.get(f"{base_url}/me", cookies=new_cookies)
        print(f"GET /me after logout status: {response.status_code}, Response: {response.json()}")
        assert response.status_code == 401
        assert response.json()["error"] == "Authentication required"
        
        print("\n=== All tests passed! ===")
        
    finally:
        # Terminate the server process
        server_process.terminate()
        server_process.wait()
        print("\nServer terminated.")

if __name__ == '__main__':
    test_all_endpoints()