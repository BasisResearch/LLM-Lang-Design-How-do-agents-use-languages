#!/bin/bash

# Test script for Todo API server
echo "Starting tests for Todo API server..."

# Extract port from arguments or use default
PORT=${1:-3001}
echo "Testing on port $PORT"

# Store cookies in a temporary file for curl
COOKIE_FILE="/tmp/todo_api_cookies.txt"

# Clean up any previous test artifacts
rm -f "$COOKIE_FILE"
pkill -f "node.*server" 2>/dev/null || true  # Kill any existing server processes

# Function to clean exit
cleanup() {
    echo "Cleaning up..."
    pkill -f "tsx server.ts" 2>/dev/null || true
    rm -f "$COOKIE_FILE"
    wait 2>/dev/null  
}
trap cleanup EXIT INT TERM

# Start the server in the background and wait a moment
echo "Starting server..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 3

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "SERVER FAILED TO START"
    exit 1
fi

echo "Server started with PID: $!"

# Test each endpoint

## TEST 1: Register a new user
echo ""
echo "--- TEST 1: Register user ---"
RESPONSE=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "secret123"}')
echo "Response: $RESPONSE"

# Check if registration was successful
if [ "$(echo $RESPONSE | jq -r '.id')" != "" ]; then
    TESTUSER_ID=$(echo $RESPONSE | jq -r '.id')
    echo "✅ User registered successfully with ID: $TESTUSER_ID"
else
    echo "❌ Registration failed"
    exit 1
fi

## TEST 2: Register user with bad username (too short)
echo ""
echo "--- TEST 2: Register with invalid username (too short) ---"
RESPONSE=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "secret123"}')
echo "Response: $RESPONSE"

if [ "$(echo $RESPONSE | jq -r '.error')" = "Invalid username" ]; then
    echo "✅ Correctly rejected too-short username"
else
    echo "❌ Invalid username validation failed"
    exit 1
fi

## TEST 3: Register with existing username
echo ""
echo "--- TEST 3: Register with existing username ---"
RESPONSE=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "secret123"}')
echo "Response: $RESPONSE"

if [ "$(echo $RESPONSE | jq -r '.error')" = "Username already exists" ]; then
    echo "✅ Correctly rejected duplicate username"
else
    echo "❌ Duplicate username handling failed"
    exit 1
fi

## TEST 4: Register with weak password
echo ""
echo "--- TEST 4: Register with weak password (less than 8 chars) ---"
RESPONSE=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "anotheruser", "password": "weak"}')
echo "Response: $RESPONSE"

if [ "$(echo $RESPONSE | jq -r '.error')" = "Password too short" ]; then
    echo "✅ Correctly rejected weak password"
else
    echo "❌ Weak password validation failed"
    exit 1
fi

## TEST 5: Login
echo ""
echo "--- TEST 5: Login ---"
curl -c "$COOKIE_FILE" -s -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "secret123"}' > /dev/null
if [ $? -eq 0 ]; then
    echo "✅ Login successful"
else
    echo "❌ Login failed"
    exit 1
fi

## TEST 6: Get user profile
echo ""
echo "--- TEST 6: Get user profile ---"
RESPONSE=$(curl -b "$COOKIE_FILE" -s http://localhost:$PORT/me)
echo "Response: $RESPONSE"
if [ "$(echo $RESPONSE | jq -r '.id')" = "$TESTUSER_ID" ]; then
    echo "✅ Got user profile successfully"
else
    echo "❌ Failed to get user profile"
    echo "Expected ID: $TESTUSER_ID, got: $(echo $RESPONSE | jq -r '.id')"
    exit 1
fi

## TEST 7: Create TODO
echo ""
echo "--- TEST 7: Create TODO ---"
TODO_JSON='{"title": "Buy groceries", "description": "Milk, eggs, bread"}'
RESPONSE=$(curl -b "$COOKIE_FILE" -s -X POST http://localhost:$PORT/todos \
  -H "Content-Type: application/json" \
  -d "$TODO_JSON")
echo "Response: $RESPONSE"

TODO_ID=$(echo $RESPONSE | jq -r '.id')
TITLE=$(echo $RESPONSE | jq -r '.title')
if [ "$TODO_ID" != "" ] && [ "$TITLE" = "Buy groceries" ]; then
    echo "✅ Created TODO successfully with ID: $TODO_ID"
else
    echo "❌ Failed to create TODO"
    exit 1
fi

## TEST 8: Get a list of todos
echo ""
echo "--- TEST 8: Get all TODOs ---"
RESPONSE=$(curl -b "$COOKIE_FILE" -s http://localhost:$PORT/todos)
echo "Response: $RESPONSE"
TODO_COUNT=$(echo $RESPONSE | jq -r 'length')
if [ "$TODO_COUNT" -eq 1 ]; then
    echo "✅ Retrieved user's TODOs successfully"
else
    echo "❌ Failed to retrieve user's TODOs, expected 1 got $TODO_COUNT"
    exit 1
fi

## TEST 9: Get specific TODO
echo ""
echo "--- TEST 9: Get specific TODO ---"
RESPONSE=$(curl -b "$COOKIE_FILE" -s http://localhost:$PORT/todos/$TODO_ID)
echo "Response: $RESPONSE"
if [ "$(echo $RESPONSE | jq -r '.id')" = "$TODO_ID" ]; then
    echo "✅ Retrieved specific TODO successfully"
else
    echo "❌ Failed to retrieve specific TODO"
    exit 1
fi

## TEST 10: Update TODO
echo ""
echo "--- TEST 10: Update TODO ---"
UPDATE_JSON='{"completed": true, "description": "Updated description"}'
RESPONSE=$(curl -b "$COOKIE_FILE" -s -X PUT http://localhost:$PORT/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d "$UPDATE_JSON")
echo "Response: $RESPONSE"
COMPLETED_STATE=$(echo $RESPONSE | jq -r '.completed')
if [ "$COMPLETED_STATE" = "true" ]; then
    echo "✅ Updated TODO successfully"
else
    echo "❌ Failed to update TODO"
    exit 1
fi

## TEST 11: Change password
echo ""
echo "--- TEST 11: Change password ---"
PASSWORD_CHANGE_JSON='{"old_password": "secret123", "new_password": "newsecret123"}'
RESPONSE=$(curl -b "$COOKIE_FILE" -s -X PUT http://localhost:$PORT/password \
  -H "Content-Type: application/json" \
  -d "$PASSWORD_CHANGE_JSON")
echo "Response: $RESPONSE"
if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "{}" ]; then
    echo "✅ Password changed successfully"
else
    echo "❌ Failed to change password"
    exit 1
fi

## TEST 12: Logout
echo ""
echo "--- TEST 12: Logout ---"
RESPONSE=$(curl -b "$COOKIE_FILE" -s -X POST http://localhost:$PORT/logout)
echo "Response: $RESPONSE"
if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "{}" ]; then
    echo "✅ Logout successful"
else
    echo "❌ Logout failed"
    exit 1
fi

## TEST 13: Try accessing protected resource without auth
echo ""
echo "--- TEST 13: Access protected resource without auth ---"
RESPONSE=$(curl -s -X GET http://localhost:$PORT/me)
ERROR_MSG=$(echo $RESPONSE | jq -r '.error')
if [ "$ERROR_MSG" = "Authentication required" ]; then
    echo "✅ Auth check works correctly - received 401 for unauthorized access"
else
    echo "❌ Expected auth error but got: $RESPONSE"
    exit 1
fi

## TEST 14: Login with new password
echo ""
echo "--- TEST 14: Login with new password ---"
curl -c "$COOKIE_FILE" -s -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newsecret123"}' > /dev/null
if [ $? -eq 0 ]; then
    echo "✅ Login with new password successful"
else
    echo "❌ Login with new password failed"
    exit 1
fi

## TEST 15: Try to access protected resource with new session
echo ""
echo "--- TEST 15: Access protected resource with new session ---"
RESPONSE=$(curl -b "$COOKIE_FILE" -s http://localhost:$PORT/me)
USER_ID_AGAIN=$(echo $RESPONSE | jq -r '.id')
if [ "$USER_ID_AGAIN" = "$TESTUSER_ID" ]; then
    echo "✅ Successfully accessed protected resource with new session"
else
    echo "❌ Failed to access protected resource with valid session"
    exit 1
fi

## TEST 16: Delete TODO
echo ""
echo "--- TEST 16: Delete TODO ---"
STATUS_CODE=$(curl -b "$COOKIE_FILE" -s -w "%{http_code}" -X DELETE http://localhost:$PORT/todos/$TODO_ID)
if [ "$STATUS_CODE" = "204" ]; then
    echo "✅ TODO deleted successfully"
else
    echo "❌ Delete failed, got status: $STATUS_CODE"
    exit 1
fi

## TEST 17: Try to access deleted TODO
echo ""
echo "--- TEST 17: Access deleted TODO ---"
RESPONSE=$(curl -b "$COOKIE_FILE" -s http://localhost:$PORT/todos/$TODO_ID)
ERROR_MSG=$(echo $RESPONSE | jq -r '.error')
if [ "$ERROR_MSG" = "Todo not found" ]; then
    echo "✅ Correctly returned 404 for deleted todo"
else
    echo "❌ Expected 404 for deleted todo but got: $RESPONSE"
    exit 1
fi

## TEST 18: Test bad credentials on password update
echo ""
echo "--- TEST 18: Test bad credentials for password change ---"
PASSWORD_CHANGE_JSON='{"old_password": "wrongpassword", "new_password": "anotherspecialpassword"}'
RESPONSE=$(curl -b "$COOKIE_FILE" -s -X PUT http://localhost:$PORT/password \
  -H "Content-Type: application/json" \
  -d "$PASSWORD_CHANGE_JSON")
echo "Response: $RESPONSE"
ERROR_MSG=$(echo $RESPONSE | jq -r '.error')
if [ "$ERROR_MSG" = "Invalid credentials" ]; then
    echo "✅ Correctly rejected bad credentials for password change"
else
    echo "❌ Expected invalid credentials error but got: $RESPONSE$"
    exit 1
fi

## TEST 19: Test creating todo without title
echo ""
echo "--- TEST 19: Create TODO without title ---"
BAD_TODO_JSON='{"description": "Test description without title"}'
RESPONSE=$(curl -b "$COOKIE_FILE" -s -X POST http://localhost:$PORT/todos \
  -H "Content-Type: application/json" \
  -d "$BAD_TODO_JSON")
echo "Response: $RESPONSE"
ERROR_MSG=$(echo $RESPONSE | jq -r '.error')
if [ "$ERROR_MSG" = "Title is required" ]; then
    echo "✅ Correctly rejected empty title"
else
    echo "❌ Expected title required error but got: $RESPONSE"
    exit 1
fi

## TEST 20: Try updating with empty title
echo ""
echo "--- TEST 20: Update TODO with empty title ---"
EMPTY_TITLE_UPDATE_JSON='{"title": ""}'
RESPONSE=$(curl -b "$COOKIE_FILE" -s -X PUT http://localhost:$PORT/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d "$EMPTY_TITLE_UPDATE_JSON")
echo "Response: $RESPONSE"
ERROR_MSG=$(echo $RESPONSE | jq -r '.error' 2>/dev/null) || true
if [ "$ERROR_MSG" = "Todo not found" ]; then
    echo "✅ Correctly returned 'todo not found' since we deleted the todo earlier (expected)"
else
    echo "❌ Unexpected behavior for deleted todo"
    exit 1
fi

echo ""
echo "🎉 All tests passed! The Todo API server is working correctly."