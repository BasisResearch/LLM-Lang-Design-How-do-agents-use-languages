#!/bin/bash

# Test script for Todo API

set -e  # Exit on any error

# Start server on a different port
PORT=${TEST_PORT:-8080}
echo "Starting server on port $PORT..."

node dist/server.js --port $PORT &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait a moment for the server to start
sleep 3

# Set up a function to kill the server on exit
cleanup() {
  if ps -p $SERVER_PID > /dev/null; then
    kill -TERM $SERVER_PID
  fi
}
trap cleanup EXIT

# Define base URL
BASE_URL="http://localhost:$PORT"

echo "Testing API..."

# Test 1: Register a user
echo "Test 1: Register user"
RESPONSE=$(curl -s -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
echo "Register response: $RESPONSE"
echo ""

# Test 2: Attempt to register duplicate username
echo "Test 2: Register duplicate user (should fail)"
RESPONSE=$(curl -s -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
echo "Expected conflict response: $RESPONSE"
echo ""

# Test 3: Login to get session cookie
echo "Test 3: Login to get session cookie"
LOGIN_RESPONSE=$(curl -s -c cookies.txt -X POST $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
echo "Login response: $LOGIN_RESPONSE"
echo ""

# Test 4: Get user profile (authenticated)
echo "Test 4: Get user profile using auth"
PROFILE_RESPONSE=$(curl -s -b cookies.txt $BASE_URL/me)
echo "Profile response: $PROFILE_RESPONSE"
echo ""

# Test 5: Access protected endpoint without auth (should fail)
echo "Test 5: Access /me without authentication (should fail)"
UNAUTH_RESPONSE=$(curl -s $BASE_URL/me)
echo "Unauth response: $UNAUTH_RESPONSE"
echo ""

# Test 6: Create a todo item
echo "Test 6: Create a todo item"
TODO_RESPONSE=$(curl -s -b cookies.txt -X POST $BASE_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "First todo", "description": "My first task"}')
echo "Create todo response: $TODO_RESPONSE"
FIRST_TODO_ID=$(echo "$TODO_RESPONSE" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "Created todo with ID: $FIRST_TODO_ID"
echo ""

# Test 7: Create another todo item
echo "Test 7: Create a second todo item"
TODO_RESPONSE2=$(curl -s -b cookies.txt -X POST $BASE_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Second todo", "description": "My second task"}')
echo "Create second todo response: $TODO_RESPONSE2"
SECOND_TODO_ID=$(echo "$TODO_RESPONSE2" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "Created second todo with ID: $SECOND_TODO_ID"
echo ""

# Test 8: Get all todos
echo "Test 8: Get all todos for user"
TODOS_RESPONSE=$(curl -s -b cookies.txt $BASE_URL/todos)
echo "All todos response: $TODOS_RESPONSE"
echo ""

# Test 9: Get specific todo
echo "Test 9: Get specific todo"
SINGLE_TODO=$(curl -s -b cookies.txt $BASE_URL/todos/$FIRST_TODO_ID)
echo "Specific todo response: $SINGLE_TODO"
echo ""

# Test 10: Update a todo
echo "Test 10: Update a todo"
UPDATE_RESPONSE=$(curl -s -b cookies.txt -X PUT $BASE_URL/todos/$FIRST_TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated first todo", "completed": true}')
echo "Update todo response: $UPDATE_RESPONSE"
echo ""

# Test 11: Change password
echo "Test 11: Change password"
CHANGE_PASS=$(curl -s -b cookies.txt -X PUT $BASE_URL/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword456"}')
echo "Change password response: $CHANGE_PASS"
echo ""

# Test 12: Logout
echo "Test 12: Logout"
LOGOUT_RESPONSE=$(curl -s -b cookies.txt -X POST $BASE_URL/logout \
  -H "Content-Type: application/json")
echo "Logout response: $LOGOUT_RESPONSE"
echo ""

# Test 13: Verify logout worked (try accessing protected route)
echo "Test 13: Verify logout (should fail)"
PROTECTED_AFTER_LOGOUT=$(curl -s -b cookies.txt $BASE_URL/me)
echo "Protected route after logout response: $PROTECTED_AFTER_LOGOUT"
echo ""

# Clean up cookies file
rm -f cookies.txt

echo "All tests completed!"