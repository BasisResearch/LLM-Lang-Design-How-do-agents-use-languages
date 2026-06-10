import subprocess
import time
import urllib.request
import urllib.error
import json
import http.cookiejar

PORT = 8765
BASE_URL = f"http://localhost:{PORT}"

def start_server():
    # Start server in background
    proc = subprocess.Popen(["python3", "server.py", "--port", str(PORT)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(1)  # give it time to start
    return proc

def make_request(method, endpoint, data=None, cookies=None, expect_status=200):
    url = f"{BASE_URL}{endpoint}"
    req = urllib.request.Request(url, method=method)
    req.add_header("Content-Type", "application/json")
    
    if cookies:
        req.add_header("Cookie", cookies)

    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        req.add_header("Content-Length", str(len(body)))

    try:
        response = urllib.request.urlopen(req, data=body)
        response_body = response.read().decode("utf-8")
        status = response.getcode()
        headers = dict(response.headers)
    except urllib.error.HTTPError as e:
        response_body = e.read().decode("utf-8")
        status = e.code
        headers = dict(e.headers)

    if status != expect_status:
        print(f"FAIL: {method} {endpoint} expected {expect_status}, got {status}")
        print(f"Response: {response_body}")
        return False, None, None

    try:
        parsed_body = json.loads(response_body) if response_body.strip() else None
    except json.JSONDecodeError:
        parsed_body = response_body

    return True, parsed_body, headers

def main():
    print("Starting server...")
    proc = start_server()
    
    all_passed = True

    # Register user 1
    print("Testing POST /register (valid)...")
    ok, data, _ = make_request("POST", "/register", {"username": "user1", "password": "password123"}, expect_status=201)
    if not ok or data.get("username") != "user1":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Register duplicate username
    print("Testing POST /register (duplicate)...")
    ok, data, _ = make_request("POST", "/register", {"username": "user1", "password": "password123"}, expect_status=409)
    if not ok or data.get("error") != "Username already exists":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Register invalid username (too short)
    print("Testing POST /register (invalid username - short)...")
    ok, data, _ = make_request("POST", "/register", {"username": "u1", "password": "password123"}, expect_status=400)
    if not ok or data.get("error") != "Invalid username":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Register invalid password (too short)
    print("Testing POST /register (invalid password - short)...")
    ok, data, _ = make_request("POST", "/register", {"username": "user2_test", "password": "short"}, expect_status=400)
    if not ok or data.get("error") != "Password too short":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Login user 1
    print("Testing POST /login (valid)...")
    ok, data, headers = make_request("POST", "/login", {"username": "user1", "password": "password123"}, expect_status=200)
    if not ok or data.get("username") != "user1":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")
    
    # Extract session cookie
    set_cookie = headers.get("Set-Cookie", "")
    session_id = None
    for part in set_cookie.split(";"):
        if "session_id=" in part:
            session_id = part.split("=", 1)[1].strip()
            break
    
    if not session_id:
        print("  FAILED: No session_id cookie found")
        all_passed = False
    else:
        cookies = f"session_id={session_id}"

    # Login with invalid credentials
    print("Testing POST /login (invalid credentials)...")
    ok, data, _ = make_request("POST", "/login", {"username": "user1", "password": "wrongpassword"}, expect_status=401)
    if not ok or data.get("error") != "Invalid credentials":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Get /me without auth
    print("Testing GET /me (no auth)...")
    ok, data, _ = make_request("GET", "/me", expect_status=401)
    if not ok or data.get("error") != "Authentication required":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Get /me with auth
    print("Testing GET /me (with auth)...")
    ok, data, _ = make_request("GET", "/me", cookies=cookies, expect_status=200)
    if not ok or data.get("username") != "user1" or data.get("id") != 1:
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Change password
    print("Testing PUT /password (valid)...")
    ok, data, _ = make_request("PUT", "/password", {"old_password": "password123", "new_password": "newpassword123"}, cookies=cookies, expect_status=200)
    if not ok or data != {}:
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Change password with wrong old password
    print("Testing PUT /password (wrong old password)...")
    ok, data, _ = make_request("PUT", "/password", {"old_password": "password123", "new_password": "anotherpassword"}, cookies=cookies, expect_status=401)
    if not ok or data.get("error") != "Invalid credentials":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Change password with short new password
    print("Testing PUT /password (short new password)...")
    ok, data, _ = make_request("PUT", "/password", {"old_password": "newpassword123", "new_password": "short"}, cookies=cookies, expect_status=400)
    if not ok or data.get("error") != "Password too short":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Create todo
    print("Testing POST /todos (valid)...")
    ok, data, _ = make_request("POST", "/todos", {"title": "My first todo", "description": "This is a description"}, cookies=cookies, expect_status=201)
    if not ok or data.get("title") != "My first todo" or data.get("completed") != False or "created_at" not in data:
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")
        todo_id = data.get("id")

    # Create todo with empty title
    print("Testing POST /todos (empty title)...")
    ok, data, _ = make_request("POST", "/todos", {"title": "", "description": "desc"}, cookies=cookies, expect_status=400)
    if not ok or data.get("error") != "Title is required":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Create todo without title
    print("Testing POST /todos (missing title)...")
    ok, data, _ = make_request("POST", "/todos", {"description": "desc"}, cookies=cookies, expect_status=400)
    if not ok or data.get("error") != "Title is required":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Get todos
    print("Testing GET /todos...")
    ok, data, _ = make_request("GET", "/todos", cookies=cookies, expect_status=200)
    if not ok or len(data) != 1 or data[0].get("title") != "My first todo":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Get specific todo
    print("Testing GET /todos/:id...")
    ok, data, _ = make_request("GET", f"/todos/{todo_id}", cookies=cookies, expect_status=200)
    if not ok or data.get("title") != "My first todo":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Get non-existent todo
    print("Testing GET /todos/:id (not found)...")
    ok, data, _ = make_request("GET", "/todos/999", cookies=cookies, expect_status=404)
    if not ok or data.get("error") != "Todo not found":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Update todo
    print("Testing PUT /todos/:id...")
    ok, data, _ = make_request("PUT", f"/todos/{todo_id}", {"completed": True, "description": "Updated desc"}, cookies=cookies, expect_status=200)
    if not ok or data.get("completed") != True or data.get("description") != "Updated desc" or data.get("title") != "My first todo":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Update todo with empty title
    print("Testing PUT /todos/:id (empty title)...")
    ok, data, _ = make_request("PUT", f"/todos/{todo_id}", {"title": ""}, cookies=cookies, expect_status=400)
    if not ok or data.get("error") != "Title is required":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Register user 2
    print("Testing POST /register (user 2)...")
    ok, _, _ = make_request("POST", "/register", {"username": "user2", "password": "password456"}, expect_status=201)
    if not ok:
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Login user 2
    print("Testing POST /login (user 2)...")
    ok, data, headers = make_request("POST", "/login", {"username": "user2", "password": "password456"}, expect_status=200)
    if not ok:
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    session_id_2 = None
    for part in headers.get("Set-Cookie", "").split(";"):
        if "session_id=" in part:
            session_id_2 = part.split("=", 1)[1].strip()
            break
    cookies_2 = f"session_id={session_id_2}"

    # User 2 tries to get user 1's todo (should return 404, not 403)
    print("Testing GET /todos/:id (another user's todo - should be 404)...")
    ok, data, _ = make_request("GET", f"/todos/{todo_id}", cookies=cookies_2, expect_status=404)
    if not ok or data.get("error") != "Todo not found":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # User 2 tries to update user 1's todo
    print("Testing PUT /todos/:id (another user's todo - should be 404)...")
    ok, data, _ = make_request("PUT", f"/todos/{todo_id}", {"completed": True}, cookies=cookies_2, expect_status=404)
    if not ok or data.get("error") != "Todo not found":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # User 2 tries to delete user 1's todo
    print("Testing DELETE /todos/:id (another user's todo - should be 404)...")
    ok, data, _ = make_request("DELETE", f"/todos/{todo_id}", cookies=cookies_2, expect_status=404)
    if not ok or data.get("error") != "Todo not found":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Delete todo
    print("Testing DELETE /todos/:id...")
    ok, data, _ = make_request("DELETE", f"/todos/{todo_id}", cookies=cookies, expect_status=204)
    if not ok or data is not None:
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Get deleted todo
    print("Testing GET /todos/:id (after delete)...")
    ok, data, _ = make_request("GET", f"/todos/{todo_id}", cookies=cookies, expect_status=404)
    if not ok or data.get("error") != "Todo not found":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Logout
    print("Testing POST /logout...")
    ok, data, _ = make_request("POST", "/logout", cookies=cookies, expect_status=200)
    if not ok or data != {}:
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Try to access protected endpoint after logout
    print("Testing GET /me (after logout)...")
    ok, data, _ = make_request("GET", "/me", cookies=cookies, expect_status=401)
    if not ok or data.get("error") != "Authentication required":
        all_passed = False
        print("  FAILED")
    else:
        print("  PASSED")

    # Cleanup
    proc.terminate()
    proc.wait()

    if all_passed:
        print("\nAll tests PASSED!")
    else:
        print("\nSome tests FAILED!")
        exit(1)

if __name__ == "__main__":
    main()