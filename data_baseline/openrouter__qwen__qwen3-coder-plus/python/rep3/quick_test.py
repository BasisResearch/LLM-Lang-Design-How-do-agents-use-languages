#!/usr/bin/env python3
"""Quick functionality test for our Todo app server"""
import requests
import subprocess
import time
import uuid
import signal
import os
import sys

def run_quick_tests():
    # Start the server in the background
    proc = subprocess.Popen([sys.executable, 'server.py', '--port', '8020'])
    
    # Give the server time to start
    time.sleep(2)
    
    try:
        print("Testing server functionality...")
        
        # Create a session to keep cookies
        session = requests.Session()
        
        # Test 1: Registration
        res = session.post('http://localhost:8020/register', 
                          json={'username': f'test_{uuid.uuid4().hex[:8]}', 'password': 'password123'})
        print(f"Registration status: {res.status_code}, response: {res.json() if res.status_code == 201 else 'Error'}")
        assert res.status_code == 201
        
        # Test 2: Login
        res = session.post('http://localhost:8020/login',
                          json={'username': f'test_{uuid.uuid4().hex[:8]}', 'password': 'password123'})
        print(f"Login status: {res.status_code}, has session cookie: {'session_id' in [c.name for c in session.cookies]}")
        assert res.status_code == 401  # Different usernames, so this should fail
        
        # Test with registered user:
        registered_username = list(session.cookies.jar._cookies.get('localhost', {}).get('/', {}).get('session_id', [None]))[0]
        if not registered_username:
            # We need to login with the actually registered username. Let's get it from the registration result
            registered_username = res.previous.json()['username'] if hasattr(res, 'previous') else None
            
        # Let's do a fresh login with first registered user 
        session2 = requests.Session()
        res = session2.post('http://localhost:8020/login',
                           json={'username': 'testuser' if 'testuser' in [k for k in vars(requests.get('http://localhost:8020/register', json={'username':'testuser', 'password':'password123'}).request).keys() if 'session' in repr(k)] else 'testuser', 'allow_redirects': False})
        
        # Instead, let's just do an incremental test of the actual features
        session_clean = requests.Session()
        test_username = f'testuser_func_{uuid.uuid4().hex[:10]}'
        print(f"Using username: {test_username}")
        
        # Register a user
        res = session_clean.post('http://localhost:8020/register',
                                json={'username': test_username, 'password': 'password123'})
        print(f"New user registration: {res.status_code} - {res.json()}")
        assert res.status_code == 201
        
        # Login with that user 
        res = session_clean.post('http://localhost:8020/login',
                                json={'username': test_username, 'password': 'password123'})
        print(f"Login: {res.status_code} - has session: {'session_id' in [c.name for c in session_clean.cookies]}")
        assert res.status_code == 200 and 'session_id' in [c.name for c in session_clean.cookies]
        
        # Get user info
        res = session_clean.get('http://localhost:8020/me')
        print(f"Get user info: {res.status_code} - {res.json()}")
        assert res.status_code == 200 and res.json()['username'] == test_username
        
        # Create todo
        res = session_clean.post('http://localhost:8020/todos',
                                json={'title': 'Test todo', 'description': 'Test description'})
        print(f"Create todo: {res.status_code} - {res.json()}")
        assert res.status_code == 201 and res.json()['title'] == 'Test todo'
        todo_id = res.json()['id']
        
        # Get that specific todo
        res = session_clean.get(f'http://localhost:8020/todos/{todo_id}')
        print(f"Get todo {todo_id}: {res.status_code} - {res.json()}")
        assert res.status_code == 200 and res.json()['id'] == todo_id
        
        # Update todo
        res = session_clean.put(f'http://localhost:8020/todos/{todo_id}',
                               json={'completed': True, 'title': 'Updated title'})
        print(f"Update todo {todo_id}: {res.status_code} - {res.json()}")
        assert res.status_code == 200 and res.json()['completed'] is True and res.json()['title'] == 'Updated title'
        
        # Get all todos
        res = session_clean.get('http://localhost:8020/todos')
        print(f"Get all todos: {res.status_code} - count: {len(res.json())}")
        assert res.status_code == 200 and len(res.json()) >= 1
        
        # Change password
        res = session_clean.put('http://localhost:8020/password',
                               json={'old_password': 'password123', 'new_password': 'newpassword123'})
        print(f"Change password: {res.status_code}")
        assert res.status_code == 200
        
        # Logout
        res = session_clean.post('http://localhost:8020/logout')
        print(f"Logout: {res.status_code}")
        assert res.status_code == 200
        
        # Verify auth required for protected endpoints
        res = requests.get('http://localhost:8020/me')
        print(f"Check auth required: {res.status_code} - {res.json()}")
        assert res.status_code == 401
        
        print("✓ All basic functionality tests passed!")
        
    finally:
        # Make sure to terminate the server
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

if __name__ == "__main__":
    run_quick_tests()