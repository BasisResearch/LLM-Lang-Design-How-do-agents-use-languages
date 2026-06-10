#!/bin/bash

# Start the server in the background
python3 server.py --port 8765 > /dev/null 2>&1 &
SERVER_PID=$!

# Wait a moment for the server to start
sleep 1

PASS=0
FAIL=0

test_endpoint() {
    local name="$1"
    local expected_status="$2"
    local method="$3"
    local url="$4"
    local data="$5"
    local cookie="$6"
    
    local curl_cookie=""
    if [ -n "$cookie" ]; then
        curl_cookie="-b $cookie"
    fi
    
    if [ -n "$data" ]; then
        response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" -H "Content-Type: application/json" -d "$data" $curl_cookie)
    else
        response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" $curl_cookie)
    fi
    
    local http_code="${response##*$'\n'}"
    local body="${response%$'\n'*}"
    
    if [ "$http_code" -eq "$expected_status" ]; then
        echo "PASS: $name (Status: $http_code)"
        ((PASS++))
    else
        echo "FAIL: $name (Expected: $expected_status, Got: $http_code)"
        echo "Body: $body"
        ((FAIL++))
    fi
}

echo "=== Running Tests ==="

# Register a user first
curl -s -X POST "http://localhost:8765/register" -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "password123"}' > /dev/null

# Get a fresh session cookie
LOGIN_RESPONSE=$(curl -s -D - -X POST "http://localhost:8765/login" -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "password123"}')
SESSION_COOKIE=$(echo "$LOGIN_RESPONSE" | grep -o 'session_id=[^;]*' | head -1)

# Test 1: Register - Success
test_endpoint "Register - Success" "201" "POST" "http://localhost:8765/register" '{"username": "testuser2", "password": "password123"}' ""

# Test 2: Register - Invalid username (too short)
test_endpoint "Register - Invalid username (too short)" "400" "POST" "http://localhost:8765/register" '{"username": "ab", "password": "password123"}' ""

# Test 3: Register - Invalid username (bad chars)
test_endpoint "Register - Invalid username (bad chars)" "400" "POST" "http://localhost:8765/register" '{"username": "test-user", "password": "password123"}' ""

# Test 4: Register - Password too short
test_endpoint "Register - Password too short" "400" "POST" "http://localhost:8765/register" '{"username": "testuser3", "password": "short"}' ""

# Test 5: Register - Username already exists
test_endpoint "Register - Username already exists" "409" "POST" "http://localhost:8765/register" '{"username": "testuser1", "password": "password123"}' ""

# Test 6: Login - Success
test_endpoint "Login - Success" "200" "POST" "http://localhost:8765/login" '{"username": "testuser1", "password": "password123"}' ""

# Test 7: Login - Invalid credentials
test_endpoint "Login - Invalid credentials" "401" "POST" "http://localhost:8765/login" '{"username": "testuser1", "password": "wrongpassword"}' ""

# Test 8: Logout - Success
test_endpoint "Logout - Success" "200" "POST" "http://localhost:8765/logout" "" "$SESSION_COOKIE"

# Test 9: Logout - Then access protected endpoint (should fail)
test_endpoint "Get /me after logout" "401" "GET" "http://localhost:8765/me" "" "$SESSION_COOKIE"

# Re-login for further tests with new password (wait, password wasn't changed yet, use old)
LOGIN_RESPONSE=$(curl -s -D - -X POST "http://localhost:8765/login" -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "password123"}')
SESSION_COOKIE=$(echo "$LOGIN_RESPONSE" | grep -o 'session_id=[^;]*' | head -1)

# Test 10: Get /me - Success
test_endpoint "Get /me - Success" "200" "GET" "http://localhost:8765/me" "" "$SESSION_COOKIE"

# Test 11: Update password - Success
test_endpoint "Update password - Success" "200" "PUT" "http://localhost:8765/password" '{"old_password": "password123", "new_password": "newpassword123"}' "$SESSION_COOKIE"

# Re-login with new password
LOGIN_RESPONSE=$(curl -s -D - -X POST "http://localhost:8765/login" -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "newpassword123"}')
SESSION_COOKIE=$(echo "$LOGIN_RESPONSE" | grep -o 'session_id=[^;]*' | head -1)

# Test 12: Update password - Wrong old password
test_endpoint "Update password - Wrong old password" "401" "PUT" "http://localhost:8765/password" '{"old_password": "wrongoldpassword", "new_password": "newpassword123"}' "$SESSION_COOKIE"

# Test 13: Update password - New password too short
test_endpoint "Update password - New password too short" "400" "PUT" "http://localhost:8765/password" '{"old_password": "newpassword123", "new_password": "short"}' "$SESSION_COOKIE"

# Test 14: Get todos - Success (empty)
test_endpoint "Get todos - Success (empty)" "200" "GET" "http://localhost:8765/todos" "" "$SESSION_COOKIE"

# Test 15: Create todo - Success
test_endpoint "Create todo - Success" "201" "POST" "http://localhost:8765/todos" '{"title": "My first todo", "description": "This is a description"}' "$SESSION_COOKIE"

# Test 16: Create todo - Title required
test_endpoint "Create todo - Title required" "400" "POST" "http://localhost:8765/todos" '{"title": "", "description": "desc"}' "$SESSION_COOKIE"

# Test 17: Get todos - Success (with data)
test_endpoint "Get todos - Success (with data)" "200" "GET" "http://localhost:8765/todos" "" "$SESSION_COOKIE"

# Test 18: Get specific todo - Success
test_endpoint "Get specific todo - Success" "200" "GET" "http://localhost:8765/todos/1" "" "$SESSION_COOKIE"

# Test 19: Get specific todo - Not found
test_endpoint "Get specific todo - Not found" "404" "GET" "http://localhost:8765/todos/999" "" "$SESSION_COOKIE"

# Test 20: Update todo - Success (partial)
test_endpoint "Update todo - Success (partial)" "200" "PUT" "http://localhost:8765/todos/1" '{"completed": true}' "$SESSION_COOKIE"

# Test 21: Update todo - Empty title
test_endpoint "Update todo - Empty title" "400" "PUT" "http://localhost:8765/todos/1" '{"title": ""}' "$SESSION_COOKIE"

# Test 22: Delete todo - Success
test_endpoint "Delete todo - Success" "204" "DELETE" "http://localhost:8765/todos/1" "" "$SESSION_COOKIE"

# Test 23: Delete todo - Not found (already deleted)
test_endpoint "Delete todo - Not found" "404" "DELETE" "http://localhost:8765/todos/1" "" "$SESSION_COOKIE"

# Test 24: Unauthorized access without cookie
test_endpoint "Get todos - Unauthorized" "401" "GET" "http://localhost:8765/todos" "" ""

# Test 25: Todo belongs to another user (should return 404)
# Create user 2 and a todo for user 2
curl -s -X POST "http://localhost:8765/register" -H "Content-Type: application/json" -d '{"username": "testuser4", "password": "password123"}' > /dev/null
LOGIN_RESPONSE=$(curl -s -D - -X POST "http://localhost:8765/login" -H "Content-Type: application/json" -d '{"username": "testuser4", "password": "password123"}')
USER4_COOKIE=$(echo "$LOGIN_RESPONSE" | grep -o 'session_id=[^;]*' | head -1)
curl -s -X POST "http://localhost:8765/todos" -H "Content-Type: application/json" -d '{"title": "User 4 todo"}' -b "$USER4_COOKIE" > /dev/null

# Try to access user 4's todo with user 1's cookie (should be 404)
test_endpoint "Get other user's todo - 404" "404" "GET" "http://localhost:8765/todos/2" "" "$SESSION_COOKIE"

echo ""
echo "=== Test Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

# Kill the server
kill $SERVER_PID 2>/dev/null

if [ $FAIL -eq 0 ]; then
    echo "All tests passed!"
    exit 0
else
    echo "Some tests failed."
    exit 1
fi
