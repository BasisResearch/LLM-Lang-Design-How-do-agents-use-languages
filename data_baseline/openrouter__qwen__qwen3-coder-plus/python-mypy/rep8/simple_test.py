#!/usr/bin/env python3
import subprocess
import time
import signal
import sys
import json
import urllib.request
import urllib.error

# Start the server
port = 8002
print(f'Starting server on {port}...')
server_proc = subprocess.Popen([sys.executable, 'server.py', '--port', str(port)])

# Wait for start
time.sleep(1)

try:
    base_url = f'http://localhost:{port}'
    
    # Register user
    print('1. Register new user...')
    resp = urllib.request.urlopen(urllib.request.Request(
        f'{base_url}/register',
        data=json.dumps({'username': 'user456', 'password': 'password123'}).encode(),
        headers={'Content-Type': 'application/json'},
        method='POST'
    ))
    user_data = json.loads(resp.read())
    print(f'Registered user: {user_data}')
    user_id = user_data['id']
    
    # Login
    print('2. Login to get session...')
    login_req = urllib.request.Request(
        f'{base_url}/login',
        data=json.dumps({'username': 'user456', 'password': 'password123'}).encode(),
        headers={'Content-Type': 'application/json'},
        method='POST'
    )
    with urllib.request.urlopen(login_req) as resp:
        login_data = json.loads(resp.read())
        print(f'Login successful: {login_data}')
        # Fetch session
        headers = dict(resp.headers)
        cookie = None
        for k in headers:
            if 'Set-Cookie' in k or k.lower() == 'set-cookie':
                for line in resp.headers.get_all('Set-Cookie', []):
                    if 'session_id=' in line:
                        cookie = line.split(';')[0]
                        break
                break
    
    print(f'Got cookie: {cookie}')
    cookie_headers = {'Cookie': cookie} if cookie else {}
    
    # Create todo
    print('3. Create todo...')
    create_req = urllib.request.Request(
        f'{base_url}/todos',
        data=json.dumps({
            'title': 'Original title',
            'description': 'Original description'
        }).encode(),
        headers={**cookie_headers, 'Content-Type': 'application/json'},
        method='POST'
    )
    with urllib.request.urlopen(create_req) as resp:
        todo_data = json.loads(resp.read())
        print(f'Created todo: {todo_data}')
        todo_id = todo_data['id']
    
    # Update the todo completely
    print('4. Update todo completely...')
    update_req = urllib.request.Request(
        f'{base_url}/todos/{todo_id}',
        data=json.dumps({
            'title': 'Updated title',
            'description': 'Updated description',
            'completed': True
        }).encode(),
        headers={**cookie_headers, 'Content-Type': 'application/json'},
        method='PUT'
    )
    
    try:
        with urllib.request.urlopen(update_req) as resp:
            updated_data = json.loads(resp.read())
            print(f'✓ Successfully updated todo: {updated_data}')
            
            # Verify expected state after update
            if (updated_data['title'] == 'Updated title' and
                updated_data['description'] == 'Updated description' and
                updated_data['completed'] == True):
                print('✓ Update values are correct!')
            else:
                print(f'✗ Update returned wrong data: {updated_data}')
    except urllib.error.HTTPError as e:
        print(f'✗ UPDATE FAILED with {e.code}: {e.read().decode()}')
        # Try getting it to see its actual current state
        get_req = urllib.request.Request(
            f'{base_url}/todos/{todo_id}',
            headers=cookie_headers,
            method='GET'
        )
        try:
            with urllib.request.urlopen(get_req) as gresp:
                old_state = json.loads(gresp.read())
                print(f'Current state before update: {old_state}')
        except urllib.error.HTTPError as ge:
            print(f'Could not even get state: {ge.code}: {ge.read().decode()}')

except Exception as e:
    print(f"Error in test: {e}")
    import traceback
    traceback.print_exc()
finally:
    server_proc.terminate()
    try:
        server_proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        server_proc.kill()