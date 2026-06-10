#!/bin/bash

# Test script to validate all endpoints
SERVER_URL="http://localhost:8080"

echo "Testing Todo App Server..."

# Start the server in background
echo "Starting server on background..."
timeout 30s bash run.sh --port 8080 &
SERVER_PID=$!
sleep 2  # Give server time to start

# Test variables
TEST_COOKIE=""
TODO_ID=""

# Function to cleanup
cleanup() {
    kill $SERVER_PID 2>/dev/null
    exit
}

trap cleanup EXIT INT TERM

# Test 1: POST /register
echo "Test 1: Registering user..."
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "strongpassword"}' \
  ${SERVER_URL}/register)
STATUS=$?
if [ $STATUS -ne 0 ] || [[ "$RESPONSE" != *"id"* ]]; then
  echo "FAIL: Register user - status: $STATUS, response: $RESPONSE"
  cleanup
fi
echo "PASS: User registered - $RESPONSE"

# Test 2: POST /login
echo "Test 2: Logging in user..."
RESPONSE=$(curl -s -c cookies.txt -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "strongpassword"}' \
  ${SERVER_URL}/login)
STATUS=$?
if [ $STATUS -ne 0 ] || [[ "$RESPONSE" != *"id"* ]]; then
  echo "FAIL: Login user - status: $STATUS, response: $RESPONSE"
  cleanup
fi
echo "PASS: User logged in - $RESPONSE"

# Extract session cookie
TEST_COOKIE=$(cat cookies.txt | grep -E '\b[0-9a-f]{64}\b' | awk '{print $7}')
if [ -z "$TEST_COOKIE" ]; then
  # If cookies not saved, assume they're in response headers
  echo "Checking session in headers directly..."
  HEADERS=$(curl -s -D - -c cookies.txt -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "strongpassword"}' \
    ${SERVER_URL}/login | grep -i set-cookie)
  TEST_COOKIE=$(echo "$HEADERS" | grep -oE '[0-9a-f]{64}' | head -n 1)
fi

if [ -z "$TEST_COOKIE" ]; then
  echo "Failed to get session cookie"
  cleanup
fi

echo "Got session cookie: $TEST_COOKIE"

# Test 3: GET /me
echo "Test 3: Getting user details..."
RESPONSE=$(curl -s -b "session_id=$TEST_COOKIE" \
  -H "Content-Type: application/json" \
  ${SERVER_URL}/me)
STATUS=$?
if [ $STATUS -ne 0 ] || [[ "$RESPONSE" != *"id"* ]]; then
  echo "FAIL: Get user details - status: $STATUS, response: $RESPONSE"
  cleanup
fi
echo "PASS: Got user details - $RESPONSE"

# Test 4: POST /todos
echo "Test 4: Creating todo..."
RESPONSE=$(curl -s -b "session_id=$TEST_COOKIE" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "Sample Todo", "description": "Buy groceries"}' \
  ${SERVER_URL}/todos)
STATUS=$?
if [ $STATUS -ne 0 ] || [[ "$RESPONSE" != *"id"* ]]; then
  echo "FAIL: Create todo - status: $STATUS, response: $RESPONSE"
  cleanup
fi
TODO_ID=$(echo "$RESPONSE" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "PASS: Created todo - $RESPONSE"

# Test 5: GET /todos
echo "Test 5: Getting all todos..."
RESPONSE=$(curl -s -b "session_id=$TEST_COOKIE" \
  -H "Content-Type: application/json" \
  ${SERVER_URL}/todos)
STATUS=$?
if [ $STATUS -ne 0 ] || [[ "$RESPONSE" != *"$TODO_ID"* ]]; then
  echo "FAIL: Get todos - status: $STATUS, response: $RESPONSE"
  cleanup
fi
echo "PASS: Got todos - $RESPONSE"

# Test 6: GET /todos/:id
echo "Test 6: Getting specific todo..."
RESPONSE=$(curl -s -b "session_id=$TEST_COOKIE" \
  -H "Content-Type: application/json" \
  ${SERVER_URL}/todos/$TODO_ID)
STATUS=$?
if [ $STATUS -ne 0 ] || [[ "$RESPONSE" != *"$TODO_ID"* ]]; then
  echo "FAIL: Get specific todo - status: $STATUS, response: $RESPONSE"
  cleanup
fi
echo "PASS: Got specific todo - $RESPONSE"

# Test 7: PUT /todos/:id
echo "Test 7: Updating todo..."
RESPONSE=$(curl -s -b "session_id=$TEST_COOKIE" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated Todo", "completed": true}' \
  ${SERVER_URL}/todos/$TODO_ID)
STATUS=$?
if [ $STATUS -ne 0 ] || [[ "$RESPONSE" != *"$TODO_ID"* ]]; then
  echo "FAIL: Update todo - status: $STATUS, response: $RESPONSE"
  cleanup
fi
echo "PASS: Updated todo - $RESPONSE"

# Test 8: DELETE /todos/:id
echo "Test 8: Deleting todo..."
RESPONSE=$(curl -s -b "session_id=$TEST_COOKIE" \
  -X DELETE \
  -H "Content-Type: application/json" \
  ${SERVER_URL}/todos/$TODO_ID)
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -b "session_id=$TEST_COOKIE" \
  -X DELETE \
  -H "Content-Type: application/json" \
  ${SERVER_URL}/todos/$TODO_ID)
if [ $STATUS -ne 204 ]; then
  echo "FAIL: Delete todo - status: $STATUS"
  cleanup
fi
echo "PASS: Deleted todo"

# Test 9: POST /password
echo "Test 9: Changing password..."
RESPONSE=$(curl -s -b "session_id=$TEST_COOKIE" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "strongpassword", "new_password": "newstrongpassword"}' \
  ${SERVER_URL}/password)
STATUS=$?
if [ $STATUS -ne 0 ] || [[ ! -z "$RESPONSE" ]]; then
  echo "FAIL: Change password - status: $STATUS, response: $RESPONSE"
  cleanup
fi
echo "PASS: Changed password"

# Test 10: POST /logout
echo "Test 10: Logging out..."
RESPONSE=$(curl -s -b "session_id=$TEST_COOKIE" \
  -X POST \
  -H "Content-Type: application/json" \
  ${SERVER_URL}/logout)
STATUS=$?
if [ $STATUS -ne 0 ] || [[ ! -z "$RESPONSE" ]]; then
  echo "FAIL: Logout - status: $STATUS, response: $RESPONSE"
  cleanup
fi
echo "PASS: Logged out"

# Test 11: Testing authentication - trying to access protected resource
echo "Test 11: Checking authentication required..."
RESPONSE=$(curl -s -X GET \
  -H "Content-Type: application/json" \
  ${SERVER_URL}/me)
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  ${SERVER_URL}/me)
if [ $STATUS -ne 401 ]; then
  echo "FAIL: Auth required not working - status: $STATUS"
  cleanup
fi
echo "PASS: Authentication required"

echo ""
echo "All tests passed! Server is working correctly!"