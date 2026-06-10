#!/usr/bin/env python3
import subprocess
import json
import time

# Start the server in the background
server_process = subprocess.Popen(['python3', 'server.py', '--port', '8001'])
time.sleep(3)

try:
    print("Testing 1: Registration")

    # Test registration
    result = subprocess.run([
        'curl', '-X', 'POST', 'http://localhost:8001/register',
        '-H', 'Content-Type: application/json',
        '-d', '{"username": "testuser", "password": "password123"}'
    ], capture_output=True, text=True)
    print(f"Status: {result.returncode}, Output: '{result.stdout}', Error: '{result.stderr}'")
    
    print("\nTesting 2: Authentication-requiring endpoint with no cookie")
    
    # Test unauthenticated /me endpoint
    result = subprocess.run([
        'curl', '-X', 'GET', 'http://localhost:8001/me'
    ], capture_output=True, text=True)
    
    print(f"Status: {result.returncode}, Output: '{result.stdout}', Error: '{result.stderr}'")
    
    # Parse the response to see what we get
    if result.stdout.strip():
        try:
            response_json = json.loads(result.stdout)
            print(f"Parsed Response: {response_json}")
            print(f"Has error key: {'error' in response_json}")
            if 'error' in response_json:
                print(f"Error value: {response_json['error']}")
        except json.JSONDecodeError:
            print(f"Response is not JSON: {result.stdout}")
    
except Exception as e:
    print(f"Error during test: {e}")

finally:
    server_process.terminate()
    server_process.wait()