#!/usr/bin/env python3
"""
Test script for the Todo app API server.
Verifies all endpoints functionality.
"""
import subprocess
import time
import threading
import requests
import tempfile
import os
import signal
import sys

# Test server class that will spawn and control the server process
class TestAPI:
    BASE_URL = "http://localhost:8080"
    COOKIES = requests.cookies.RequestsCookieJar() 

    @staticmethod
    def start_server(port=8080):
        """Start the server in the background"""
        cmd = ["python3", "server.py", "--port", str(port)]
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        
        # Give the server some time to start
        time.sleep(1)
        
        # Verify the server started properly (try making a simple request)
        max_retries = 10
        while max_retries > 0:
            try:
                response = requests.get(f"{TestAPI.BASE_URL}/todos", timeout=2)
                # Server is likely up if it responds, even with auth error
                break
            except requests.exceptions.ConnectionError:
                time.sleep(0.5)
                max_retries -= 1
        else:
            raise RuntimeError("Server failed to start")
            
        return process

    @staticmethod
    def stop_server(process):
        """Stop the server process"""
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()

    def clear_session(self):
        """Clear cookies to log out"""
        self.COOKIES.clear()

    def register(self, username, password):
        """Register a new user"""
        url = f"{self.BASE_URL}/register"
        data = {
            "username": username,
            "password": password
        }
        response = requests.post(url, json=data, cookies=self.COOKIES)
        return response

    def login(self, username, password):
        """Login as existing user"""
        url = f"{self.BASE_URL}/login"
        data = {
            "username": username,
            "password": password
        }
        response = requests.post(url, json=data, cookies=self.COOKIES)
        return response

    def logout(self):
        """Logout current user"""
        url = f"{self.BASE_URL}/logout"
        response = requests.post(url, cookies=self.COOKIES)
        response_cookies = response.cookies
        # After logging out, the session cookies should be cleared
        self.COOKIES.clear()
        return response

    def get_profile(self):
        """Get current user's info"""
        url = f"{self.BASE_URL}/me"
        response = requests.get(url, cookies=self.COOKIES)
        return response

    def change_password(self, old_password, new_password):
        """Change current user's password"""
        url = f"{self.BASE_URL}/password"
        data = {
            "old_password": old_password,
            "new_password": new_password
        }
        response = requests.put(url, json=data, cookies=self.COOKIES)
        return response

    def get_todos(self):
        """Get all todos for current user"""
        url = f"{self.BASE_URL}/todos"
        response = requests.get(url, cookies=self.COOKIES)
        return response

    def create_todo(self, title, description=""):
        """Create a new todo"""
        url = f"{self.BASE_URL}/todos"
        data = {
            "title": title,
            "description": description
        }
        response = requests.post(url, json=data, cookies=self.COOKIES)
        return response

    def get_todo_by_id(self, todo_id):
        """Get specific todo by ID"""
        url = f"{self.BASE_URL}/todos/{todo_id}"
        response = requests.get(url, cookies=self.COOKIES)
        return response

    def update_todo(self, todo_id, title=None, description=None, completed=None):
        """Update specific todo with partial updates"""
        url = f"{self.BASE_URL}/todos/{todo_id}"
        data = {}
        if title is not None:
            data["title"] = title
        if description is not None:
            data["description"] = description
        if completed is not None:
            data["completed"] = completed

        response = requests.put(url, json=data, cookies=self.COOKIES)
        return response

    def delete_todo(self, todo_id):
        """Delete specific todo"""
        url = f"{self.BASE_URL}/todos/{todo_id}"
        response = requests.delete(url, cookies=self.COOKIES)
        return response


def test_endpoints():
    """Run comprehensive tests"""
    # Start server in background
    port = 8080
    server_process = TestAPI.start_server(port)
    api = TestAPI()
    
    try:
        print("Testing POST /register...")
        # Test valid registration
        res = api.register("john_doe", "verysecret123")
        assert res.status_code == 201
        assert res.json()["id"] == 1
        assert res.json()["username"] == "john_doe"
        print("✓ Registration works")

        # Test duplicate username
        res = api.register("john_doe", "verysecret123")
        assert res.status_code == 409
        assert res.json()["error"] == "Username already exists"
        print("✓ Duplicate username rejection works")

        # Test invalid username (too short)
        res = api.register("jo", "verysecret123")
        assert res.status_code == 400
        assert res.json()["error"] == "Invalid username"
        print("✓ Short username rejection works")

        # Test invalid username (invalid chars)
        res = api.register("john@doe", "verysecret123")   
        assert res.status_code == 400
        assert res.json()["error"] == "Invalid username"
        print("✓ Invalid character username rejection works")

        # Test weak password
        res = api.register("jane_doe", "weak")
        assert res.status_code == 400
        assert res.json()["error"] == "Password too short"
        print("✓ Weak password rejection works")

        print("\nTesting POST /login...")
        # Test correct login
        res = api.login("john_doe", "verysecret123")
        assert res.status_code == 200
        assert res.json()["id"] == 1
        assert res.json()["username"] == "john_doe"
        # Check that the session cookie was set
        cookies = dict(res.cookies)
        assert "session_id" in str(res.headers)
        print("✓ Login with valid credentials works")

        # Test wrong password
        api.clear_session()
        res = api.login("john_doe", "wrongpassword")
        assert res.status_code == 401
        assert res.json()["error"] == "Invalid credentials"
        print("✓ Invalid password rejection works")

        # Test nonexistent user
        res = api.login("nonexistent", "password")
        assert res.status_code == 401
        assert res.json()["error"] == "Invalid credentials"
        print("✓ Non-existent user login rejection works")

        # Re-login for subsequent tests
        api.login("john_doe", "verysecret123")

        print("\nTesting GET /me...")   
        res = api.get_profile()
        assert res.status_code == 200
        assert res.json()["id"] == 1
        assert res.json()["username"] == "john_doe"
        print("✓ Get profile works")

        print("\nTesting authentication requirement...")
        api.clear_session()
        res = api.get_profile()
        assert res.status_code == 401
        assert res.json()["error"] == "Authentication required"
        print("✓ Authentication requirement enforced")

        # Log back in
        api.login("john_doe", "verysecret123")

        print("\nTesting PUT /password...")
        # Test with correct old password
        res = api.change_password("verysecret123", "newverysecret456")
        assert res.status_code == 204  # no content
        print("✓ Password change works")

        # Test that old password no longer works
        api.logout()
        api.login("john_doe", "verysecret123")
        assert api.get_profile().status_code == 401  # Should fail

        # Test with new password
        api.login("john_doe", "newverysecret456")
        assert api.get_profile().status_code == 200
        assert api.get_profile().json()["username"] == "john_doe"
        print("✓ New password works after change")

        # Restore initial password for next tests and log back in
        api.change_password("newverysecret456", "verysecret123")
        api.logout()
        api.login("john_doe", "verysecret123")

        print("\nTesting POST /logout...")
        res = api.logout()
        assert res.status_code == 204  # no content
        res = api.get_profile()
        assert res.status_code == 401
        print("✓ Logout works and invalidate session");

        # Log back in
        api.login("john_doe", "verysecret123")

        print("\nTesting POST /todos...")
        # Test creating a todo
        res = api.create_todo("Buy groceries", "Need to buy milk and bread")
        assert res.status_code == 201
        assert res.json()["title"] == "Buy groceries"
        assert res.json()["description"] == "Need to buy milk and bread"
        assert res.json()["completed"] == False
        assert "created_at" in res.json()
        assert "updated_at" in res.json()
        todo1_id = res.json()["id"]
        print("✓ Creating todo works")

        # Test creating another todo
        res = api.create_todo("Finish project")
        assert res.status_code == 201
        assert res.json()["title"] == "Finish project"
        assert res.json()["description"] == ""
        assert res.json()["completed"] == False
        todo2_id = res.json()["id"]
        print("✓ Creating second todo works")

        # Test missing title in todo creation
        res = api.create_todo("") # empty title
        assert res.status_code == 400
        assert res.json()["error"] == "Title is required"
        print("✓ Empty title rejection works for creation")

        print("\nTesting GET /todos...")
        res = api.get_todos()
        assert res.status_code == 200
        todos = res.json()
        assert len(todos) == 2
        assert todos[0]["id"] == todo1_id
        assert todos[1]["id"] == todo2_id
        print("✓ Getting todos works")

        print("\nTesting GET /todos/:id...")
        res = api.get_todo_by_id(todo1_id)
        assert res.status_code == 200
        assert res.json()["id"] == todo1_id
        assert res.json()["title"] == "Buy groceries"
        print("✓ Getting specific todo works")

        # Test 404 for non-existing todo
        res = api.get_todo_by_id(9999)
        assert res.status_code == 404
        assert res.json()["error"] == "Todo not found"
        print("✓ 404 for non-existing todo works")

        print("\nTesting PUT /todos/:id...")
        # Partial update - title only
        res = api.update_todo(todo1_id, title="Updated groceries", completed=True)
        assert res.status_code == 200
        updated_todo = res.json()
        assert updated_todo["id"] == todo1_id
        assert updated_todo["title"] == "Updated groceries"
        assert updated_todo["description"] == "Need to buy milk and bread"  # unchanged
        assert updated_todo["completed"] == True
        print("✓ Partial todo update works")

        # Test update with empty title
        res = api.update_todo(todo1_id, title="")
        assert res.status_code == 400
        assert res.json()["error"] == "Title is required"
        print("✓ Empty title rejection works for update")

        print("\nTesting DELETE /todos/:id...")
        # Delete the first todo
        res = api.delete_todo(todo1_id)
        assert res.status_code == 204  # No content
        print("✓ Delete todo works")

        # Make sure it's deleted
        res = api.get_todo_by_id(todo1_id)
        assert res.status_code == 404
        print("✓ Deleted todo is inaccessible")

        # Delete the second todo
        res = api.delete_todo(todo2_id)
        assert res.status_code == 204
        print("✓ Second delete works")

        print("\nTesting cross-user restrictions... (need second user)")
        # Register and login as another user 
        api.logout()
        api.register("jane_smith", "janesecret123")
        api.login("jane_smith", "janesecret123")
        
        # Try to access john_doe's todos after logout - should be 404, not 403
        api.clear_session()
        api.login("john_doe", "verysecret123")
        # Recreate the todos under john_doe
        res = api.create_todo("John's task", "Private task")
        assert res.status_code == 201
        johntask_id = res.json()["id"]
        
        # Go back to jane's session
        api.clear_session() 
        api.login("jane_smith", "janesecret123")
        
        # Attempt to access john's private todo - should return 404, not 403
        res = api.get_todo_by_id(johntask_id)
        assert res.status_code == 404  # Should be 404, not 403 - to prevent ID enumeration
        assert res.json()["error"] == "Todo not found"
        print("✓ Cross-user access prevention works (404 instead of 403)")

        # Try modifying john's todo through jane's session
        res = api.update_todo(johntask_id, title="Trying to edit John's todo")
        assert res.status_code == 404
        assert res.json()["error"] == "Todo not found"
        print("✓ Cross-user modification prevention works")

        # Try deleting john's todo through jane's session
        res = api.delete_todo(johntask_id)
        assert res.status_code == 404
        assert res.json()["error"] == "Todo not found"
        print("✓ Cross-user deletion prevention works")

        print("\n🎉 All tests passed!")
        
    except Exception as e:
        print(f"❌ Test failed: {str(e)}")
        raise e
    finally:
        # Always stop the server
        TestAPI.stop_server(server_process)


if __name__ == "__main__":
    test_endpoints()