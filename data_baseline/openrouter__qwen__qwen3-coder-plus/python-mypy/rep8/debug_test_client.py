#!/usr/bin/env python3
"""Debug script to test specific endpoint behavior"""
import json
import urllib.request
import urllib.error

def debug_update_todo(port):
    # Login first
    try:
        req = urllib.request.Request(
            f'http://localhost:{port}/login',
            data=json.dumps({
                'username': 'testuser',
                'password': 'newpassword123'
            }).encode(),
            headers={'Content-Type': 'application/json'},
            method='POST'
        )
        with urllib.request.urlopen(req) as response:
            login_result = json.loads(response.read())
            print(f'Login worked: {login_result}')
            
            # Extract session cookie from response headers
            cookies = response.headers.get_all('Set-Cookie', [])
            session_id = None
            for cookie in cookies:
                if cookie.startswith('session_id='):
                    session_id = cookie.split(';')[0].split('=')[1]
                    break
        
        if not session_id:
            print("No session ID found!")
            return
        
        print(f'Got session ID: {session_id}')
        
        # Get first TODO
        headers = {'Cookie': f'session_id={session_id}'}
        req = urllib.request.Request(
            f'http://localhost:{port}/todos',
            headers=headers,
            method='GET'
        )
        with urllib.request.urlopen(req) as response:
            todos = json.loads(response.read())
            print(f'Existing TODOs: {todos}')
            if not todos:
                return
            todo_id = todos[0]['id']
            print(f'TODO ID: {todo_id}')
        
        # Try to update
        headers = {'Cookie': f'session_id={session_id}', 'Content-Type': 'application/json'}
        req = urllib.request.Request(
            f'http://localhost:{port}/todos/{todo_id}',
            data=json.dumps({
                'title': 'Updated title',
                'description': 'Updated description',
                'completed': True
            }).encode(),
            headers=headers,
            method='PUT'
        )
        try:
            with urllib.request.urlopen(req) as response:
                result = json.loads(response.read())
                print(f'Update successful: {result}')
        except urllib.error.HTTPError as e:
            print(f'HTTP Error during update: {e.code}, Reason: {e.reason}')
            if e.code == 404:
                print('Response body:', e.read().decode())
        
    except Exception as e:
        print(f'Debug error: {e}')


if __name__ == "__main__":
    debug_update_todo(8001)