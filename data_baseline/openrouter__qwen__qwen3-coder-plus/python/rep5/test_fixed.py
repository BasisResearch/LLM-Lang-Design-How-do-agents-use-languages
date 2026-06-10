#!/usr/bin/env python3
"""
Test script for the Todo app server.
Requires: requests library installed (pip install requests)
"""
import subprocess
import time
import signal
import os
import requests
import json


def test_server_endpoints():
    """Test all endpoints of the server."""
    
    # Start the server on port 8080
    server_process = subprocess.Popen(['python3', 'server.py', '--port', '8080'])
    
    # Give the server some time to start
    time.sleep(2)
    
    try:
        # Test variables
        test_user = {"username": "testuser123", "password": "password123"}
        session = requests.Session()
        
        print("Testing /register endpoint...")
        # Test registration
        response = session.post(
            'http://localhost:8080/register',
            json=test_user
        )
        assert response.status_code == 201
        user_data = response.json()
        assert user_data['username'] == test_user['username']
        print("✓ Registration successful")
        
        print("Testing duplicate username registration...")
        # Test duplicate registration
        response = session.post(
            'http://localhost:8080/register',
            json={"username": "testuser123", "password": "anotherpass123"}
        )
        assert response.status_code == 409
        assert response.json()['error'] == 'Username already exists'
        print("✓ Duplicate registration properly rejected")
        
        print("Testing invalid username registration...")
        # Test invalid username registration
        response = session.post(
            'http://localhost:8080/register',
            json={"username": "ab", "password": "testpass123"}
        )
        assert response.status_code == 400
        assert response.json()['error'] == 'Invalid username'
        
        response = session.post(
            'http://localhost:8080/register',
            json={"username": "valid_user", "password": "123"}
        )
        assert response.status_code == 400
        assert response.json()['error'] == 'Password too short'
        print("✓ Invalid registrations properly rejected")
        
        print("Testing /login endpoint...")
        # Login with registered user
        response = session.post(
            'http://localhost:8080/login',
            json=test_user
        )
        assert response.status_code == 200
        assert response.json()['username'] == test_user['username']
        print("✓ Login successful")
        
        print("Testing /me endpoint...")
        # Test authenticated GET /me
        response = session.get('http://localhost:8080/me')
        assert response.status_code == 200
        assert response.json()['username'] == test_user['username']
        print("✓ Me endpoint working")
        
        print("Testing unauthenticated access...")
        # Test unauthenticated access
        unauth_session = requests.Session()
        response = unauth_session.get('http://localhost:8080/me')
        assert response.status_code == 401
        assert response.json()['error'] == 'Authentication required'
        
        response = unauth_session.get('http://localhost:8080/todos')
        assert response.status_code == 401
        assert response.json()['error'] == 'Authentication required'
        print("✓ Unauthenticated access properly blocked")
        
        print("Testing /password endpoint...")
        # Test password change
        response = session.put(
            'http://localhost:8080/password',
            json={
                "old_password": test_user['password'],
                "new_password": "newpassword456"
            }
        )
        assert response.status_code == 200
        print("✓ Password change successful")
        
        print("Testing /todos endpoints...")
        # At this point we still have our authenticated session
        # Test creating todos
        response = session.post(
            'http://localhost:8080/todos',
            json={
                "title": "Buy groceries",
                "description": "Buy milk, bread, eggs"
            }
        )
        assert response.status_code == 201
        todo1 = response.json()
        assert todo1['title'] == 'Buy groceries'
        assert todo1['completed'] == False
        assert 'created_at' in todo1
        assert 'updated_at' in todo1
        print("✓ Todo creation successful")
        
        response = session.post(
            'http://localhost:8080/todos',
            json={
                "title": "Walk the dog",
                "description": ""
            }
        )
        assert response.status_code == 201
        todo2 = response.json()
        assert todo2['title'] == 'Walk the dog'
        print("✓ Second todo created")
        
        # Test empty title rejection
        response = session.post(
            'http://localhost:8080/todos',
            json={
                "title": "",
                "description": "Some description"
            }
        )
        assert response.status_code == 400
        assert response.json()['error'] == 'Title is required'
        print("✓ Empty title rejected")
        
        print("Testing /get todos...")
        # Test fetching all todos (while user is still logged in)
        response = session.get('http://localhost:8080/todos')
        assert response.status_code == 200
        all_todos = response.json()
        # At least these two should be there
        assert len(all_todos) >= 2
        titles = [t['title'] for t in all_todos]
        assert 'Buy groceries' in titles
        assert 'Walk the dog' in titles
        print("✓ Get all todos successful")
        
        print("Testing get specific todo...")
        # Test getting specific todo
        response = session.get(f"http://localhost:8080/todos/{todo1['id']}")
        assert response.status_code == 200
        fetched_todo = response.json()
        assert fetched_todo['id'] == todo1['id']
        print("✓ Get specific todo successful")
        
        print("Testing not found cases...")
        # Test getting non-existent todo
        response = session.get("http://localhost:8080/todos/99999")
        assert response.status_code == 404
        assert response.json()['error'] == 'Todo not found'
        print("✓ Non-existent todo properly handled")
        
        print("Testing update todo...")
        # Test updating a todo
        update_data = {
            "title": "Updated todo",
            "completed": True
        }
        response = session.put(f"http://localhost:8080/todos/{todo1['id']}", json=update_data)
        assert response.status_code == 200
        updated_todo = response.json()
        assert updated_todo['title'] == 'Updated todo'
        assert updated_todo['completed'] == True
        assert updated_todo['id'] == todo1['id']  # ID unchanged
        print("✓ Todo update successful")
        
        # Test partial update
        partial_update = {"description": "New description after partial update"}
        response = session.put(f"http://localhost:8080/todos/{todo2['id']}", json=partial_update)
        assert response.status_code == 200
        partial_updated = response.json()
        assert partial_updated['title'] == 'Walk the dog'  # Unchanged
        assert partial_updated['description'] == 'New description after partial update'  # Updated
        print("✓ Partial update successful")
        
        # Test updating with empty title
        bad_update = {"title": ""}
        response = session.put(f"http://localhost:8080/todos/{todo2['id']}", json=bad_update)
        assert response.status_code == 400
        assert response.json()['error'] == 'Title is required'
        print("✓ Empty title update properly rejected")
        
        print("Testing delete todo...")
        # Test deleting a todo
        response = session.delete(f"http://localhost:8080/todos/{todo1['id']}")
        assert response.status_code == 204
        
        # Verify deletion
        response = session.get(f"http://localhost:8080/todos/{todo1['id']}")
        assert response.status_code == 404
        print("✓ Delete todo successful")
        
        # Now let's do what we did originally - logout session then test other things
        print("Testing logout and subsequent behavior...")
        response = session.post('http://localhost:8080/logout')
        assert response.status_code == 200
        
        # After logout, session should be invalid
        response = session.get('http://localhost:8080/me')
        assert response.status_code == 401
        print("✓ Logout successfully invalidated session")
        
        # Try to log in again with old password - should fail 
        response = session.post(
            'http://localhost:8080/login',
            json=test_user  # Still contains the old password
        )
        assert response.status_code == 401
        print("✓ Old password no longer works")
        
        # Login with new password
        test_user['password'] = 'newpassword456'
        response = session.post(
            'http://localhost:8080/login',
            json=test_user 
        )
        assert response.status_code == 200
        print("✓ New password accepted")
        
        print("\n✅ All tests passed!")
        
    finally:
        # Stop the server
        server_process.terminate()
        server_process.wait()


if __name__ == "__main__":
    test_server_endpoints()