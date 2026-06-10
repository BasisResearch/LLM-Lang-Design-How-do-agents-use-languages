#!/usr/bin/env python3
"""Test script to validate server implementation."""
import subprocess
import time
import requests
import json
import threading
from urllib.parse import urljoin
import os

def start_server(port=5000):
    """Start the server in a background process."""
    # Start server in background
    env = os.environ.copy()
    env["PYTHONPATH"] = "."
    proc = subprocess.Popen(['python3', 'server.py', '--port', str(port)], env=env)
    
    # Give server time to start
    time.sleep(2)
    return proc

def run_tests():
    """Run comprehensive tests of all endpoints."""
    print("Starting server...")
    server_process = start_server(5000)
    
    try:
        base_url = 'http://localhost:5000'
        print("Testing endpoints...\n")
        
        # Test Register (No Auth)
        print("Testing POST /register...")
        reg_resp = requests.post(f'{base_url}/register', 
                                json={'username': 'testuser', 'password': 'verysecret123'})
        if reg_resp.status_code == 201:
            user_data = reg_resp.json()
            print(f"✓ Registered user: {user_data}")
        else:
            print(f"✗ Registration failed: {reg_resp.status_code} - {reg_resp.text}")
            return False
        
        # Test Duplicate Register (should fail with 409)
        dup_resp = requests.post(f'{base_url}/register',
                                 json={'username': 'testuser', 'password': 'anotherpass'})
        if dup_resp.status_code == 409:
            print("✓ Duplicate registration correctly rejected")
        else:
            print(f"✗ Duplicate registration should have failed, got {dup_resp.status_code}: {dup_resp.text}")
            return False
        
        # Test Login to get session (No Auth)  
        print("\nTesting POST /login...")
        login_resp = requests.post(f'{base_url}/login', 
                                  json={'username': 'testuser', 'password': 'verysecret123'})
        # We should extract the session cookie from this later...
        
        s = requests.Session()
        
        # Attempt login through session
        login_resp = s.post(f'{base_url}/login', 
                           json={'username': 'testuser', 'password': 'verysecret123'})
        if login_resp.status_code == 200:
            logged_user = login_resp.json()
            print(f"✓ Logged in as: {logged_user}")
        else:
            print(f"✗ Login failed: {login_resp.status_code} - {login_resp.text}")
            return False
            
        # Test Getting User Info
        print("\nTesting GET /me...")
        me_resp = s.get(f'{base_url}/me')
        if me_resp.status_code == 200:
            userinfo = me_resp.json()
            print(f"✓ Got user info: {userinfo}")
        else:
            print(f"✗ Get me failed: {me_resp.status_code} - {me_resp.text}")
            return False
            
        # Test Adding Todo
        print("\nTesting POST /todos...")
        todo_resp = s.post(f'{base_url}/todos',
                          json={'title': 'Buy milk', 'description': 'From the store'})
        if todo_resp.status_code == 201:
            todo_data = todo_resp.json()
            print(f"✓ Created todo: {todo_data}")
            todo_id = todo_data['id']
        else:
            print(f"✗ Create todo failed: {todo_resp.status_code} - {todo_resp.text}")
            return False
            
        # Test Get All Todos
        print("\nTesting GET /todos...")
        todos_resp = s.get(f'{base_url}/todos')
        if todos_resp.status_code == 200:
            todos_list = todos_resp.json()
            print(f"✓ Got todos: {len(todos_list)} todo(s)")
        else:
            print(f"✗ Get todos failed: {todos_resp.status_code} - {todos_resp.text}")
            return False
            
        # Test Get Specific Todo
        print("\nTesting GET /todos/... (specific)")
        single_todo_resp = s.get(f'{base_url}/todos/{todo_id}')
        if single_todo_resp.status_code == 200:
            single_todo = single_todo_resp.json()
            print(f"✓ Got specific todo: {single_todo}")
        else:
            print(f"✗ Get specific todo failed: {single_todo_resp.status_code} - {single_todo_resp.text}")
            return False
            
        # Test Update Todo
        print("\nTesting PUT /todos/... (update)")
        update_resp = s.put(f'{base_url}/todos/{todo_id}',
                           json={'title': 'Buy organic milk', 'completed': True})
        if update_resp.status_code == 200:
            updated_todo = update_resp.json()
            print(f"✓ Updated todo: {updated_todo}")
        else:
            print(f"✗ Update todo failed: {update_resp.status_code} - {update_resp.text}")
            return False
            
        # Test Deleting Todo
        print("\nTesting DELETE /todos/...")
        del_resp = s.delete(f'{base_url}/todos/{todo_id}')
        if del_resp.status_code == 204:
            print("✓ Deleted todo successfully")
        else:
            print(f"✗ Delete todo failed: {del_resp.status_code} - {del_resp.text}")
            return False
            
        # Test Unauthorized /me call (without session)
        print("\nTesting unauthorized access (no session)...")
        unauth_s = requests.Session()
        unauth_resp = unauth_s.get(f'{base_url}/me')
        if unauth_resp.status_code == 401:
            print("✓ Unauthorized access correctly rejected")
        else:
            print(f"✗ Should have been unauthorized, got: {unauth_resp.status_code}")
            return False
            
        # Test Password Change
        print("\nTesting PUT /password...")
        passwd_resp = s.post(f'{base_url}/password', 
                             json={'old_password': 'verysecret123', 'new_password': 'newverysecret123'})
        if passwd_resp.status_code == 200:
            print("✓ Password changed successfully")
        else:
            print(f"✗ Password change failed: {passwd_resp.status_code} - {passwd_resp.text}")
            return False
            
        print("\n✓ All tests passed!")
        return True
    
    finally:
        server_process.terminate()
        server_process.wait()

if __name__ == '__main__':
    if run_tests():
        print("\n✓ Implementation is working correctly")
    else:
        print("\n✗ Tests failed - fixes needed")