#!/usr/bin/env python3
import subprocess
import time
import requests

# Start server
proc = subprocess.Popen(['python3', 'server.py', '--port', '8766'])

time.sleep(2)

try:
    base_url = "http://localhost:8766"
    print("Testing duplicate registration...")
    
    # Register first user
    print("Registering first user...")
    result1 = requests.post(
        f"{base_url}/register",
        json={"username": "duptest", "password": "password123"}
    )
    print(f"First registration result: {result1.status_code}, {result1.json()}")
    
    # Register duplicate user (should fail)
    print("Registering duplicate user...")
    result2 = requests.post(
        f"{base_url}/register",
        json={"username": "duptest", "password": "password456"}
    )
    print(f"Duplicate registration result: {result2.status_code}, {result2.text}")
    
    if result2.status_code == 201:
        print("❌ ERROR: Duplicate registration allowed!")
    else:
        print("✅ CORRECT: Duplicate registration rejected!")
except Exception as e:
    print(f"Error during testing: {e}")
finally:
    proc.terminate()
    proc.wait()