#!/bin/bash

# Simple test script to verify all endpoints work
PORT=8080
BASE_URL="http://localhost:$PORT"

echo "Testing Todo API server..."

# Start the server in background
echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 2  # Wait for server to start

# Cleanup function
cleanup() {
  kill $SERVER_PID 2>/dev/null
  wait $SERVER_PID 2>/dev/null
}

# Error handling
trap cleanup EXIT

# Test registration
echo "Testing registration..."
response=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  $BASE_URL/register)
echo "Register response: $response"
echo ""

# Extract session cookie
COOKIE_FILE=$(mktemp)
curl -c $COOKIE_FILE -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  $BASE_URL/login

if [[ -s $COOKIE_FILE ]]; then
  SESSION_COOKIE=$(grep session_id $COOKIE_FILE | awk '{print $7}')
  echo "Got session ID: $SESSION_COOKIE"
else
  echo "Failed to get login session"
  exit 1
fi

echo ""
echo "Testing secured endpoints with session..."

# Test get user info
curl -b "session_id=$SESSION_COOKIE" -s $BASE_URL/me
echo ""
echo "Get user info tested"

# Test create todo
TODO_RESPONSE=$(curl -b "session_id=$SESSION_COOKIE" -s -X POST -H "Content-Type: application/json" \
  -d '{"title":"Test todo","description":"A sample todo item"}' \
  $BASE_URL/todos)
echo "Created todo: $TODO_RESPONSE"

TODO_ID=$(echo $TODO_RESPONSE | grep -o '"id":[0-9]*' | cut -d: -f2)
if [ ! -z "$TODO_ID" ]; then
  echo "Created todo with ID: $TODO_ID"
  
  # Test get todo by ID
  curl -b "session_id=$SESSION_COOKIE" -s $BASE_URL/todos/$TODO_ID
  echo ""
  echo "Get todo by ID tested"
  
  # Test update todo
  curl -b "session_id=$SESSION_COOKIE" -s -X PUT -H "Content-Type: application/json" \
    -d '{"completed":true}' \
    $BASE_URL/todos/$TODO_ID
  echo ""
  echo "Update todo tested"
  
  # Get all todos after update
  curl -b "session_id=$SESSION_COOKIE" -s $BASE_URL/todos
  echo ""
  echo "Get all todos tested"
  
  # Test delete todo
  curl -b "session_id=$SESSION_COOKIE" -s -X DELETE $BASE_URL/todos/$TODO_ID
  echo ""
  echo "Delete todo tested"
fi

# Test password change
curl -b "session_id=$SESSION_COOKIE" -s -X PUT -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword456"}' \
  $BASE_URL/password
echo ""
echo "Password change tested"

# Test logout
curl -b "session_id=$SESSION_COOKIE" -s -X POST $BASE_URL/logout
echo ""
echo "Logout tested"

# Final test - should fail without authentication
FAIL_TEST=$(curl -s -w "\n%{http_code}" -b "session_id=$SESSION_COOKIE" -X GET $BASE_URL/me)
HTTP_CODE=$(echo "$FAIL_TEST" | tail -n1)
if [ "$HTTP_CODE" = "401" ]; then
  echo "Auth protection working correctly"
else
  echo "Auth protection failed"
fi

echo ""
echo "All tests completed!"