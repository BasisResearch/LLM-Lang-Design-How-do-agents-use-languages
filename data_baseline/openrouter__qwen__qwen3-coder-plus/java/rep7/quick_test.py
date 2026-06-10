#!/usr/bin/env python3

import requests
import time
import subprocess
import signal
import sys
import os

def test_api():
    port = 8082
    base_url = f"http://localhost:{port}"
    
    print("Starting server...")
    
    # Start server
    server_process = subprocess.Popen([
        "java", "-cp", ".:gson-2.8.9.jar:src", "com.todo.server.TodoServer", "--port", str(port)
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    
    # Give it time to start
    time.sleep(3)
    
    if server_process.poll() is not None:
        print("Server failed to start")
        stdout, stderr = server_process.communicate()
        print(f"STDOUT: {stdout.decode()}")
        print(f"STDERR: {stderr.decode()}")
        return False
        
    print("Server started successfully")
    
    try:
        # Test register endpoint
        print("\n1. Testing POST /register")
        register_data = {"username": "testuser123", "password": "verysecure123"}
        response = requests.post(f"{base_url}/register", json=register_data)
        print(f"Register status: {response.status_code}")
        print(f"Register response: {response.json()}")
        
        if response.status_code != 201:
            print("✗ Register failed")
            return False
        else:
            print("✓ Register success")
        
        # Test login
        print("\n2. Testing POST /login")
        login_data = {"username": "testuser123", "password": "verysecure123"}
        response = requests.post(f"{base_url}/login", json=login_data)
        print(f"Login status: {response.status_code}")
        
        if response.status_code == 200:
            print("✓ Login success")
            session_cookie = response.cookies.get_dict()
            print(f"Session cookie received: {'session_id' in session_cookie}")
        else:
            print("✗ Login failed")
            print(f"Response: {response.json()}")
            return False
            
        # Test unauthorized access to protected endpoint
        print("\n3. Testing unauthorized access to GET /me")
        response = requests.get(f"{base_url}/me")
        print(f"Unauth access status: {response.status_code}")
        
        if response.status_code == 401:
            print("✓ Unauthorized access correctly blocked")
        else:
            print("✗ Unauthorized access allowed")
            return False
            
        # Test authorized access to /me
        print("\n4. Testing authorized access to GET /me")
        response = requests.get(f"{base_url}/me", cookies=session_cookie)
        print(f"Authorized access status: {response.status_code}")
        
        if response.status_code == 200:
            print(f"✓ Authorized access success: {response.json()}")
        else:
            print("✗ Authorized access failed")
            return False
            
        # Test todo creation
        print("\n5. Testing POST /todos")
        todo_data = {"title": "Test Todo", "description": "A test todo item"}
        response = requests.post(f"{base_url}/todos", json=todo_data, cookies=session_cookie)
        print(f"Todo creation status: {response.status_code}")
        
        if response.status_code == 201:
            todo = response.json()
            print(f"✓ Todo created: {todo['title']}")
            todo_id = todo["id"]
        else:
            print(f"✗ Todo creation failed: {response.json() if response.content else 'No response'}")
            return False
            
        # Test getting todos
        print("\n6. Testing GET /todos")
        response = requests.get(f"{base_url}/todos", cookies=session_cookie)
        print(f"Get todos status: {response.status_code}")
        
        if response.status_code == 200:
            todos = response.json()
            print(f"✓ Got {len(todos)} todos")
            if len(todos) > 0:
                print(f"First todo: {todos[0].get('title')}")
        else:
            print("✗ Getting todos failed")
            return False
            
        # Test getting specific todo
        print("\n7. Testing GET /todos/{id}")
        response = requests.get(f"{base_url}/todos/{todo_id}", cookies=session_cookie)
        print(f"Get specific todo status: {response.status_code}")
        
        if response.status_code == 200:
            print(f"✓ Retrieved specific todo: {response.json()['title']}")
        else:
            print("✗ Getting specific todo failed")
            return False
            
        # Test updating todo
        print("\n8. Testing PUT /todos/{id}")
        update_data = {"title": "Updated Todo Title", "completed": True}
        response = requests.put(
            f"{base_url}/todos/{todo_id}", 
            json=update_data, 
            cookies=session_cookie
        )
        print(f"Update todo status: {response.status_code}")
        
        if response.status_code == 200:
            updated_todo = response.json()
            print(f"✓ Todo updated: {updated_todo['title']}, completed: {updated_todo['completed']}")
        else:
            print("✗ Updating todo failed")
            return False
            
        # Test deleting todo
        print("\n9. Testing DELETE /todos/{id}")
        response = requests.delete(f"{base_url}/todos/{todo_id}", cookies=session_cookie)
        print(f"Delete todo status: {response.status_code}")
        
        if response.status_code == 204:
            print("✓ Todo deleted")
        else:
            print("✗ Deleting todo failed")
            return False
            
        # Try accessing the deleted todo
        print("\n10. Testing access to deleted todo")
        response = requests.get(f"{base_url}/todos/{todo_id}", cookies=session_cookie)
        print(f"Access deleted todo status: {response.status_code}")
        
        if response.status_code == 404:
            print("✓ Deleted todo properly inaccessible")
        else:
            print("✗ Deleted todo still accessible")
            return False
            
        # Test logout
        print("\n11. Testing POST /logout")
        response = requests.post(f"{base_url}/logout", cookies=session_cookie)
        print(f"Logout status: {response.status_code}")
        
        if response.status_code == 200:
            print("✓ Logout success")
        else:
            print("✗ Logout failed")
            return False
            
        # Test that session is invalidated after logout
        print("\n12. Testing access after logout")
        response = requests.get(f"{base_url}/me", cookies=session_cookie)
        print(f"Access after logout status: {response.status_code}")
        
        if response.status_code == 401:
            print("✓ Session correctly invalidated after logout")
        else:
            print("✗ Session still valid after logout")
            return False
            
        print("\n🎉 All tests passed!")
        return True
        
    except Exception as e:
        print(f"\nTest error: {e}")
        return False
        
    finally:
        # Clean up
        print("\nShutting down server...")
        server_process.terminate()
        try:
            server_process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server_process.kill()

if __name__ == "__main__":
    success = test_api()
    if not success:
        sys.exit(1)