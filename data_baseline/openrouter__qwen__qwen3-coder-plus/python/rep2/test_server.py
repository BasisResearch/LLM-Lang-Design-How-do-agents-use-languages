#!/usr/bin/env python3

import subprocess
import time
import requests
import json
import threading

def start_server(port):
    """Start the server in a separate thread"""
    def run_server():
        subprocess.Popen(['./run.sh', '--port', str(port)])
    thread = threading.Thread(target=run_server)
    thread.daemon = True
    thread.start()
    time.sleep(1)  # Give the server time to start
    return thread

def test_all_endpoints():
    port = 8765
    base_url = f'http://localhost:{port}'
    
    # Start server
    server_thread = start_server(port)
    
    print("Testing endpoints...")
    
    try:
        # Test register endpoint
        print("Testing /register...")
        register_resp = requests.post(f'{base_url}/register',
                                    json={'username': 'testuser', 'password': 'securepass'})
        assert register_resp.status_code == 201
        reg_data = register_resp.json()
        assert 'id' in reg_data and 'username' in reg_data
        print(f"  ✓ Register successful: {reg_data}")
        
        # Test another registration with same username (should fail)
        dup_reg = requests.post(f'{base_url}/register',
                                json={'username': 'testuser', 'password': 'otherpass'})
        assert dup_reg.status_code == 409
        print("  ✓ Duplicate registration correctly blocked")
        
        # Test registration validation (short password)
        short_pass = requests.post(f'{base_url}/register',
                                   json={'username': 'testuser2', 'password': '123'})
        assert short_pass.status_code == 400
        print("  ✓ Short password validation works")
        
        # Test registration validation (invalid username)
        bad_user = requests.post(f'{base_url}/register',
                                 json={'username': 'ab', 'password': 'securepass'})
        assert bad_user.status_code == 400
        print("  ✓ Invalid username validation works")
        
        # Test login
        print("Testing /login...")
        login_resp = requests.post(f'{base_url}/login',
                                  json={'username': 'testuser', 'password': 'securepass'})
        assert login_resp.status_code == 200
        login_cookies = login_resp.cookies
        print("  ✓ Login successful")
        
        # Test protected endpoints without auth
        print("Testing auth protection...")
        no_auth_get_me = requests.get(f'{base_url}/me')
        assert no_auth_get_me.status_code == 401
        print("  ✓ GET /me requires auth")
        
        # Test protected endpoints with auth
        print("Testing authenticated requests...")
        resp_with_auth = requests.get(f'{base_url}/me', cookies=login_cookies)
        assert resp_with_auth.status_code == 200
        user_info = resp_with_auth.json()
        print(f"  ✓ Authenticated GET /me: {user_info}")
        
        # Test todos endpoint
        print("Testing /todos...")
        todos_empty_resp = requests.get(f'{base_url}/todos', cookies=login_cookies)
        assert todos_empty_resp.status_code == 200
        assert todos_empty_resp.json() == []
        print("  ✓ Empty todos list retrieved")
        
        # Test POST /todos
        todo_create_resp = requests.post(f'{base_url}/todos', 
                                        cookies=login_cookies,
                                        json={'title': 'First todo', 'description': 'My first task'})
        assert todo_create_resp.status_code == 201
        created_todo = todo_create_resp.json()
        assert created_todo['title'] == 'First todo'
        assert created_todo['description'] == 'My first task'
        assert 'id' in created_todo
        assert created_todo['completed'] == False
        print(f"  ✓ Created todo: {created_todo}")
        
        # Test GET /todos/:id
        todo_id = created_todo['id']
        todo_get_resp = requests.get(f'{base_url}/todos/{todo_id}', cookies=login_cookies)
        assert todo_get_resp.status_code == 200
        got_todo = todo_get_resp.json()
        assert got_todo['id'] == todo_id
        print(f"  ✓ Retrieved todo with ID {todo_id}")
        
        # Test updating the todo
        update_resp = requests.put(f'{base_url}/todos/{todo_id}',
                                   cookies=login_cookies,
                                   json={'completed': True})
        assert update_resp.status_code == 200
        updated_todo = update_resp.json()
        assert updated_todo['completed'] == True
        print(f"  ✓ Updated todo completion: {updated_todo}")
        
        # Test partial updates
        partial_update_resp = requests.put(f'{base_url}/todos/{todo_id}',
                                           cookies=login_cookies,
                                           json={'title': 'Updated title'})
        assert partial_update_resp.status_code == 200
        final_todo = partial_update_resp.json()
        assert final_todo['title'] == 'Updated title'
        print(f"  ✓ Partial update successful: {final_todo}")
        
        # Try to get a non-existent todo
        wrong_id_resp = requests.get(f'{base_url}/todos/99999', cookies=login_cookies)
        assert wrong_id_resp.status_code == 404
        print("  ✓ Non-existent todo returns 404")
        
        # Test invalidating a session
        logout_resp = requests.post(f'{base_url}/logout', cookies=login_cookies)
        assert logout_resp.status_code == 200
        print("  ✓ Logout successful")
        
        # Verify session is gone
        post_logout_resp = requests.get(f'{base_url}/me', cookies=login_cookies)
        assert post_logout_resp.status_code == 401
        print("  ✓ Session invalidated after logout")
        
        # Test delete functionality
        # First login again
        relogin_resp = requests.post(f'{base_url}/login',
                                    json={'username': 'testuser', 'password': 'securepass'})
        relogin_cookies = relogin_resp.cookies
        # Recreate a todo
        create_resp = requests.post(f'{base_url}/todos', 
                                   cookies=relogin_cookies,
                                   json={'title': 'To Delete', 'description': 'Will be deleted'})
        create_data = create_resp.json()
        del_id = create_data['id']
        
        # Delete the todo
        del_resp = requests.delete(f'{base_url}/todos/{del_id}', cookies=relogin_cookies)
        assert del_resp.status_code == 204  
        print(f"  ✓ Todo with ID {del_id} deleted successfully")
        
        # Verify it's gone
        verify_del = requests.get(f'{base_url}/todos/{del_id}', cookies=relogin_cookies)
        assert verify_del.status_code == 404
        print(f"  ✓ Deleted todo is no longer available")
        
        print("\nAll tests passed! ✅")
        
    except Exception as e:
        print(f"\nTest failed ❌: {str(e)}")
        raise
    
    finally:
        # Kill the server process  
        import os
        import signal
        try:
            result = subprocess.run(['ps', 'aux'], capture_output=True, text=True)
            for line in result.stdout.splitlines():
                if './run.sh' in line and f'--port {port}' in line:
                    pid = int(line.split()[1])
                    os.kill(pid, signal.SIGTERM)
                    break
        except:
            pass  # Ignore errors when trying to kill server


if __name__ == '__main__':
    test_all_endpoints()