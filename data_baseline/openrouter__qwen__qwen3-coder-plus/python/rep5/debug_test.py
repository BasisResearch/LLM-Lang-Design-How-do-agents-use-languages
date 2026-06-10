#!/usr/bin/env python3
"""
Debug script to manually test functionality and identify issue
"""
import subprocess
import time
import requests
import json


def debug_test():
    # Start server
    server_process = subprocess.Popen(['python3', 'server.py', '--port', '8080'])
    time.sleep(1)
    
    try:
        session = requests.Session()
        
        # Register user
        resp = session.post(
            'http://localhost:8080/register',
            json={"username": "debuguser", "password": "debugpassword123"}
        )
        print(f"Register: {resp.status_code}, {resp.json()}")
        
        # Login
        resp = session.post(
            'http://localhost:8080/login',
            json={"username": "debuguser", "password": "debugpassword123"}
        )
        print(f"Login: {resp.status_code}, {resp.json()}")
        
        # Create todo 1
        resp = session.post(
            'http://localhost:8080/todos',
            json={"title": "Test todo 1", "description": "desc 1"}
        )
        print(f"Todo 1: {resp.status_code}, {resp.json()}")
        
        # Create todo 2
        resp = session.post(
            'http://localhost:8080/todos', 
            json={"title": "Test todo 2", "description": "desc 2"}
        )
        print(f"Todo 2: {resp.status_code}, {resp.json()}")
        
        # Check get todos
        resp = session.get('http://localhost:8080/todos')
        print(f"Todolist: {resp.status_code}, count={len(resp.json())} items: {resp.json()}")
        
        # Try the raw curl command too
        import subprocess as sp
        curl_cmd = [
            'curl', '-i',
            '-H', 'Cookie: ' + session.cookies.get_dict().get('session_id', ''),  
            'http://localhost:8080/todos'
        ]
        print(f"Curl command: {' '.join(curl_cmd)}")
        result = sp.run(curl_cmd, capture_output=True, text=True)
        print(f"Curl result:\n{result.stdout}")
        
    finally:
        server_process.terminate()
        server_process.wait()


if __name__ == '__main__':
    debug_test()