#!/usr/bin/env python3

import subprocess
import time
import requests
import json
import tempfile
import os

def test_all_endpoints():
    # Start the server
    server_process = subprocess.Popen(['java', '-cp', 'bin', 'com.todoserver.Main', '--port', '8091'])
    time.sleep(3)  # Give it time to start
    
    try:
        base_url = 'http://localhost:8091'
        cookies = {}
        
        print("=== Testing POST /register ===")
        resp = requests.post(f'{base_url}/register', 
                           json={'username': 'testuser', 'password': 'password123'})
        print(f'Register status: {resp.status_code}')
        print(f'Register response: {resp.text}')
        assert resp.status_code == 201, f"Expected 201, got {resp.status_code}"
        
        print("\n=== Testing POST /register duplicate ===")
        resp = requests.post(f'{base_url}/register', 
                           json={'username': 'testuser', 'password': 'password123'})
        print(f'Duplicate register status: {resp.status_code}')
        assert resp.status_code == 409, f"Expected 409, got {resp.status_code}"
        
        print("\n=== Testing POST /login ===")
        resp = requests.post(f'{base_url}/login', 
                           json={'username': 'testuser', 'password': 'password123'})
        print(f'Login status: {resp.status_code}')
        print(f'Login response: {resp.text}')
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        
        # Extract session cookie
        cookies = dict(resp.cookies)
        print(f'Cookies extracted: {cookies}')
        
        print("\n=== Testing GET /me ===")
        resp = requests.get(f'{base_url}/me', cookies=cookies)
        print(f'Get me status: {resp.status_code}')
        print(f'Get me response: {resp.text}')
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        
        print("\n=== Testing POST /todos ===")
        resp = requests.post(f'{base_url}/todos', 
                           json={'title': 'My first task', 'description': 'A sample task'},
                           cookies=cookies)
        print(f'Create todo status: {resp.status_code}')
        print(f'Create todo response: {resp.text}')
        assert resp.status_code == 201, f"Expected 201, got {resp.status_code}"
        
        created_todo = resp.json()
        todo_id = created_todo['id']
        print(f'Created todo with ID: {todo_id}')
        
        print("\n=== Testing GET /todos ===")
        resp = requests.get(f'{base_url}/todos', cookies=cookies)
        print(f'Get todos status: {resp.status_code}')
        print(f'Get todos response (first 100 chars): {resp.text[:100]}...')
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        assert len(resp.json()) == 1, f"Expected 1 todo, got {len(resp.json())}"
        
        print("\n=== Testing GET /todos/{id} ===") 
        resp = requests.get(f'{base_url}/todos/{todo_id}', cookies=cookies)
        print(f'Get specific todo status: {resp.status_code}')
        print(f'Get specific todo response: {resp.text}')
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        
        print("\n=== Testing PUT /todos/{id} ===")
        resp = requests.put(f'{base_url}/todos/{todo_id}',
                          json={'title': 'Updated task', 'completed': True},
                          cookies=cookies)
        print(f'Update todo status: {resp.status_code}')
        print(f'Update todo response: {resp.text}')
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        assert resp.json()['title'] == 'Updated task', f"Title not updated properly"
        assert resp.json()['completed'] == True, f"Completed flag not updated properly"
        
        print("\n=== Testing PUT /password ===")
        resp = requests.put(f'{base_url}/password',
                          json={'old_password': 'password123', 'new_password': 'newpass456'},
                          cookies=cookies)
        print(f'Change password status: {resp.status_code}')
        print(f'Change password response: {resp.text}')
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        
        print("\n=== Testing DELETE /todos/{id} ===")
        resp = requests.delete(f'{base_url}/todos/{todo_id}', cookies=cookies)
        print(f'Delete todo status: {resp.status_code}')
        assert resp.status_code == 204, f"Expected 204, got {resp.status_code}"
        
        # Test that deleted todo no longer exists
        resp = requests.get(f'{base_url}/todos/{todo_id}', cookies=cookies)
        print(f'Get deleted todo status: {resp.status_code}')
        assert resp.status_code == 404, f"Expected 404, got {resp.status_code}"
        
        print("\n=== Testing POST /logout ===")
        resp = requests.post(f'{base_url}/logout', cookies=cookies)
        print(f'Logout status: {resp.status_code}')
        print(f'Logout response: {resp.text}')
        assert resp.status_code == 200, f"Expected 200, got {resp.status_code}"
        
        # Test that after logout, /me returns 401
        resp = requests.get(f'{base_url}/me', cookies=cookies)
        print(f'Get me after logout status: {resp.status_code}')
        print(f'Get me after logout response: {resp.text}')
        assert resp.status_code == 401, f"Expected 401, got {resp.status_code}"
        
        print("\n🎉 All tests passed!")
        
    finally:
        # Kill the server
        server_process.terminate()
        server_process.wait()

if __name__ == '__main__':
    test_all_endpoints()