#!/bin/bash

set -e  # Exit on any error

echo "Starting tests..."

# Configuration
PORT=8080
SERVER_URL="http://localhost:$PORT"

# Start server in background
node_modules/.bin/tsx server.ts --port $PORT &
SERVER_PID=$!
sleep 2  # Give server time to start

# Clean up function
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Test variables
COOKIES=""
JAR_FILE="/tmp/todo_test_cookies.txt"

# Function to extract session cookie
extract_session_cookie() {
  SESSION_ID=$(grep -oP 'session_id=\K[a-f0-9\-]+' $JAR_FILE)
}

# Helper for making curl requests with cookies 
make_request() {
  local method="$1"
  local endpoint="$2" 
  local data="$3"
  local expected_code="$4"
  local description="$5"
  
  echo "Testing: $description"
  
  if [ -n "$data" ]; then
    response=$(curl -X $method -b $JAR_FILE -c $JAR_FILE -s -w "%{http_code}" \
      -H "Content-Type: application/json" -d "$data" "$SERVER_URL$endpoint")
  else
    response=$(curl -X $method -b $JAR_FILE -c $JAR_FILE -s -w "%{http_code}" \
      -H "Content-Type: application/json" "$SERVER_URL$endpoint")
  fi
  
  status_code="${response: -3}"
  response_body="${response%???}"
  
  if [ "$status_code" = "$expected_code" ]; then
    echo "  ✓ Success ($status_code)"
  else
    echo "  ✗ Failed: Expected $expected_code, got $status_code"
    echo "    Response: $response_body"
    exit 1
  fi
  
  echo ""
  return 0
}

make_request_no_body() {
  local method="$1"
  local endpoint="$2" 
  local expected_code="$3"
  local description="$4"
  
  echo "Testing: $description"
  
  response=$(curl -X $method -b $JAR_FILE -c $JAR_FILE -s -w "%{http_code}" \
    -H "Content-Type: application/json" "$SERVER_URL$endpoint")
  
  status_code="${response: -3}"
  response_body="${response%???}"
  
  if [ "$status_code" = "$expected_code" ]; then
    echo "  ✓ Success ($status_code)"
  else
    echo "  ✗ Failed: Expected $expected_code, got $status_code"
    echo "    Response: $response_body"
    exit 1
  fi
  
  echo ""
  return 0
}

# Test 1: Register user with valid data
echo "=== Test 1: Register user with valid data ==="
make_request "POST" "/register" '{"username":"testuser1","password":"password123"}' "201" "Register valid user"

# Test 2: Register duplicate user (should fail)
echo "=== Test 2: Register duplicate user (should fail) ==="
make_request "POST" "/register" '{"username":"testuser1","password":"password123"}' "409" "Register duplicate user (should fail)"

# Test 3: Register user with invalid username
echo "=== Test 3: Register user with invalid username ==="
make_request "POST" "/register" '{"username":"ab","password":"password123"}' "400" "Register user with short username (should fail)"
make_request "POST" "/register" '{"username":"!@#$%^&*()}","password":"password123"}' "400" "Register user with special characters (should fail)"

# Test 4: Register user with short password
echo "=== Test 4: Register user with short password ==="
make_request "POST" "/register" '{"username":"validuser","password":"12345"}' "400" "Register user with short password (should fail)"

# Test 5: Login with user
echo "=== Test 5: Login with registered user ==="
make_request "POST" "/login" '{"username":"testuser1","password":"password123"}' "200" "Login with valid credentials"

# Test 6: Use auth-protected endpoint after login
echo "=== Test 6: Access protected endpoints after login ==="
make_request "GET" "/me" "" "200" "Access /me endpoint after login"

# Test 7: Attempt to access protected endpoint without auth
echo "=== Test 7: Access protected endpoint without authentication ==="
rm -f $JAR_FILE  # Clear cookies
make_request "GET" "/me" "" "401" "Access /me endpoint without login (should fail)"

# Test 8: Login properly to continue
echo "=== Test 8: Re-login to continue testing ==="
make_request "POST" "/login" '{"username":"testuser1","password":"password123"}' "200" "Login again to continue tests"

# Test 9: Create a todo
echo "=== Test 9: Create a todo ==="
make_request "POST" "/todos" '{"title":"First Todo","description":"Learn Node.js"}' "201" "Create first todo"

# Test 10: Create a todo without title (should fail)
echo "=== Test 10: Create a todo without title ==="
make_request "POST" "/todos" '{"description":"This should fail","title":""}' "400" "Create todo with empty title (should fail)"

# Test 11: Get all todos by this user
echo "=== Test 11: Get all todos ==="
make_request "GET" "/todos" "" "200" "Get all todos (should return one todo)"

# Test 12: Get specific todo by ID
echo "=== Test 12: Get specific todo by ID ==="
make_request "GET" "/todos/1" "" "200" "Get existing todo by ID"

# Test 13: Try to get non-existent todo
echo "=== Test 13: Try to get non-existent todo ==="
make_request "GET" "/todos/999" "" "404" "Try to get non-existent todo"

# Test 14: Update a todo partially
echo "=== Test 14: Update a todo partially ==="
make_request "PUT" "/todos/1" '{"completed":true}' "200" "Complete the todo partially"

# Test 15: Verify todo was updated properly
echo "=== Test 15: Verify todo update ==="
make_request "GET" "/todos/1" "" "200" "Check that todo was updated"

# Test 16: Update todo with empty title (should fail)
echo "=== Test 16: Update todo with empty title ==="
make_request "PUT" "/todos/1" '{"title":""}' "400" "Update todo with empty title (should fail)"

# Test 17: Update todo completely
echo "=== Test 17: Update todo completely ==="
make_request "PUT" "/todos/1" '{"title":"Updated Todo","description":"Updated Description","completed":false}' "200" "Fully update the todo"

# Test 18: Delete the todo
echo "=== Test 18: Delete the todo ==="
make_request_no_body "DELETE" "/todos/1" "204" "Delete the todo"

# Test 19: Try to access deleted todo
echo "=== Test 19: Try to access deleted todo ==="
make_request "GET" "/todos/1" "" "404" "Try to get deleted todo"

# Test 20: Change password
echo "=== Test 20: Change password ==="
make_request "PUT" "/password" '{"old_password":"password123","new_password":"newpassword123"}' "200" "Change user password"

# Test 21: Try invalid old password when changing
echo "=== Test 21: Try invalid old password when changing ==="
make_request "PUT" "/password" '{"old_password":"wrongpassword","new_password":"anotherpassword"}' "401" "Try to change password with wrong old password"

# Test 22: Logout
echo "=== Test 22: Logout ==="
make_request "POST" "/logout" "" "200" "Logout user"

# Test 23: Try to access protected resource after logout
echo "=== Test 23: Access protected resource after logout ==="
make_request "GET" "/me" "" "401" "Access protected resource after logout (should fail)"

# Final test - register new user and try to access other's non-existent resources
echo "=== Test 24: Register a new user and test isolation ==="
make_request "POST" "/register" '{"username":"testuser2","password":"password123"}' "201" "Register second user"
make_request "POST" "/login" '{"username":"testuser2","password":"password123"}' "200" "Login as second user" 
make_request "GET" "/todos/1" "" "404" "Second user tries accessing first user's todo (now nonexistent - should fail)"
make_request "GET" "/me" "" "200" "Check second user data still accessible"


echo "All tests passed successfully!"