#!/usr/bin/env python3
import subprocess
import time
import requests
import json
import tempfile
import signal
import os

def test_basic_functionality():
    print("Testing basic functionality...")
    
    # Kill any existing server process
    os.system("pkill -f server.py >/dev/null 2>&1 || true")
    time.sleep(1)
    
    # Start the server
    print("Starting server on port 8890...")
    process = subprocess.Popen(["python3", "server.py", "--port", "8890"])
    time.sleep(3)  # Wait for server to start

    try:
        errors = 0
        total_tests = 0

        s = requests.Session()

        # Test 1: Register user
        print("\n1. Testing registration...")
        total_tests += 1
        resp = s.post("http://localhost:8890/register", json={
            "username": "testuser1", 
            "password": "password123"
        })
        if resp.status_code == 201 and "id" in resp.json():
            print("  ✓ Registration successful")
        else:
            print(f"  ✗ Registration failed: {resp.status_code}, {resp.text}")
            errors += 1

        # Test 2: Login 
        print("\n2. Testing login...")
        total_tests += 1
        resp = s.post("http://localhost:8890/login", json={
            "username": "testuser1", 
            "password": "password123"
        })
        if resp.status_code == 200 and "id" in resp.json():
            print("  ✓ Login successful")
        else:
            print(f"  ✗ Login failed: {resp.status_code}, {resp.text}")
            errors += 1

        # Test 3: Get user profile
        print("\n3. Testing profile access...")
        total_tests += 1
        resp = s.get("http://localhost:8890/me")
        if resp.status_code == 200 and "username" in resp.json():
            print("  ✓ Profile access successful")
        else:
            print(f"  ✗ Profile access failed: {resp.status_code}, {resp.text}")
            errors += 1

        # Test 4: Create a todo
        print("\n4. Testing todo creation...")
        total_tests += 1
        resp = s.post("http://localhost:8890/todos", json={
            "title": "Test Task",
            "description": "A testing task"
        })
        if resp.status_code == 201 and resp.json().get("title") == "Test Task":
            print("  ✓ Todo creation successful")
            todo_id = resp.json()["id"]
        else:
            print(f"  ✗ Todo creation failed: {resp.status_code}, {resp.text}")
            errors += 1

        # Test 5: Get all todos
        print("\n5. Testing todo listing...")
        total_tests += 1  
        resp = s.get("http://localhost:8890/todos")
        if resp.status_code == 200 and len(resp.json()) >= 1:
            print("  ✓ Todo listing successful")
        else:
            print(f"  ✗ Todo listing failed: {resp.status_code}, {resp.text}")
            errors += 1

        # Test 6: Get specific todo
        print("\n6. Testing single todo retrieval...")
        total_tests += 1
        if 'todo_id' in locals():
            resp = s.get(f"http://localhost:8890/todos/{todo_id}")
            if resp.status_code == 200 and resp.json()["id"] == todo_id:
                print("  ✓ Single todo retrieval successful")
            else:
                print(f"  ✗ Single todo retrieval failed: {resp.status_code}, {resp.text}")
                errors += 1
        else:
            print("  ! Skipped (no todo to test)")

        # Test 7: Update a todo
        print("\n7. Testing todo update...")
        total_tests += 1
        if 'todo_id' in locals():
            resp = s.put(f"http://localhost:8890/todos/{todo_id}", json={
                "title": "Updated Task",
                "completed": True
            })
            if resp.status_code == 200 and resp.json().get("title") == "Updated Task":
                print("  ✓ Todo update successful")
            else:
                print(f"  ✗ Todo update failed: {resp.status_code}, {resp.text}")
                errors += 1
        else:
            print("  ! Skipped (no todo to test)")

        # Test 8: Change password
        print("\n8. Testing password change...")
        total_tests += 1
        resp = s.put("http://localhost:8890/password", json={
            "old_password": "password123",
            "new_password": "newpassword456"
        })
        if resp.status_code == 200:
            print("  ✓ Password change successful")
        else:
            print(f"  ✗ Password change failed: {resp.status_code}, {resp.text}")
            errors += 1

        # Test 9: Create todo with minimal required fields
        print("\n9. Testing todo creation with partial fields...")
        total_tests += 1
        resp = s.post("http://localhost:8890/todos", json={
            "title": "Required Field Only"
        })
        if resp.status_code == 201 and resp.json().get("title") == "Required Field Only":
            print("  ✓ Partial todo creation successful")
            partial_todo_id = resp.json()["id"]
        else:
            print(f"  ✗ Partial todo creation failed: {resp.status_code}, {resp.text}")
            errors += 1

        # Test 10: Delete a todo
        print("\n10. Testing todo deletion...")
        total_tests += 1
        if 'todo_id' in locals():
            resp = s.delete(f"http://localhost:8890/todos/{todo_id}")
            if resp.status_code == 204:
                print("  ✓ Todo deletion successful")
            else:
                print(f"  ✗ Todo deletion failed: {resp.status_code}, {resp.text}")
                errors += 1
        else:
            print("  ! Skipped (no todo to test)")

        # Test 11: Logout
        print("\n11. Testing logout...")
        total_tests += 1
        resp = s.post("http://localhost:8890/logout")
        if resp.status_code == 200:
            print("  ✓ Logout successful")
        else:
            print(f"  ✗ Logout failed: {resp.status_code}, {resp.text}")
            errors += 1

        # Test 12: Verify unauthorized access is denied
        print("\n12. Testing unauthorized access...")
        total_tests += 1
        # Create a new session without login
        unauthorized_session = requests.Session()
        resp = unauthorized_session.get("http://localhost:8890/me")
        if resp.status_code == 401:
            print("  ✓ Unauthorized access properly blocked")
        else:
            print(f"  ✗ Unauthorized access allowed: {resp.status_code}, {resp.text}")
            errors += 1

        print(f"\n\nTest Results: {total_tests - errors}/{total_tests} tests passed")
        if errors == 0:
            print("🎉 ALL TESTS PASSED!")
            return True
        else:
            print(f"❌ {errors} test(s) failed")
            return False

    finally:
        # Always terminate the server
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()

def test_error_conditions():
    print("\n\nTesting error conditions...")
    process = subprocess.Popen(["python3", "server.py", "--port", "8891"])
    time.sleep(2)

    try:
        errors = 0
        total_tests = 0

        # Test error case 1: Invalid registration username (too short)
        print("\nE1. Testing invalid username (too short)...")
        total_tests += 1
        resp = requests.post("http://localhost:8891/register", json={
            "username": "aa", 
            "password": "password123"
        })
        if resp.status_code == 400 and "Invalid username" in resp.text:
            print("  ✓ Properly rejects short usernames")
        else:
            print(f"  ✗ Did not reject short username: {resp.status_code}, {resp.text}")
            errors += 1

        # Test error case 2: Weak password  
        print("\nE2. Testing weak password...")
        total_tests += 1
        resp = requests.post("http://localhost:8891/register", json={
            "username": "gooduser", 
            "password": "weak"
        })
        if resp.status_code == 400 and "Password too short" in resp.text:
            print("  ✓ Properly rejects weak passwords")
        else:
            print(f"  ✗ Did not reject weak password: {resp.status_code}, {resp.text}")
            errors += 1

        # Test error case 3: Title required for todos
        print("\nE3. Testing missing title for todo creation...")
        total_tests += 1
        s = requests.Session()
        # Register and login first
        s.post("http://localhost:8891/register", json={"username": "tester", "password": "password123"})
        s.post("http://localhost:8891/login", json={"username": "tester", "password": "password123"})
        
        resp = s.post("http://localhost:8891/todos", json={
            "description": "No title provided"
        })
        if resp.status_code == 400 and "Title is required" in resp.text:
            print("  ✓ Properly requires title in todo creation")
        else:
            print(f"  ✗ Did not require title: {resp.status_code}, {resp.text}")
            errors += 1

        # Test error case 4: Invalid login credentials
        print("\nE4. Testing invalid login credentials...")
        total_tests += 1
        resp = requests.post("http://localhost:8891/login", json={
            "username": "nonexistent", 
            "password": "wrongpass"
        })
        if resp.status_code == 401 and "Invalid credentials" in resp.text:
            print("  ✓ Properly rejects invalid credentials")
        else:
            print(f"  ✗ Did not reject invalid credentials: {resp.status_code}, {resp.text}")
            errors += 1

        print(f"\nError Condition Tests: {total_tests - errors}/{total_tests} passed")
        return errors == 0

    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()

if __name__ == "__main__":
    print("RUNNING COMPREHENSIVE SERVER TESTS...")
    
    main_tests_pass = test_basic_functionality()
    error_tests_pass = test_error_conditions()
    
    if main_tests_pass and error_tests_pass:
        print("\n🎉 ALL COMPREHENSIVE TESTS PASSED! Server is working correctly.")
    else:
        print("\n❌ SOME TESTS FAILED. Check implementation.")
        exit(1)