#!/bin/bash

# Simple test client to validate our server implementation
SERVER_URL="http://localhost:8080"

echo "Testing Todo Server..."

# Register a user
echo "1. Testing registration..."
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  $SERVER_URL/register)
echo "Registration response: $RESPONSE"

# Try to register the same user again (should fail)
echo "2. Testing duplicate registration..."
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  $SERVER_URL/register)
echo "Duplicate registration response: $RESPONSE"

# Login
echo "3. Testing login..."
COOKIES=$(curl -s -c - -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  $SERVER_URL/login)
echo "Login response: $COOKIES"

# Extract session cookie for subsequent requests
SESSION_ID=$(echo "$COOKIES" | grep "session_id" | awk '{print $7}')
echo "Extracted session ID: $SESSION_ID"

if [ -n "$SESSION_ID" ]; then
    # Test authenticated endpoints using the session cookie
    echo "4. Testing /me endpoint..."
    RESPONSE=$(curl -s -b "session_id=$SESSION_ID" $SERVER_URL/me)
    echo "Me response: $RESPONSE"
    
    # Create a todo
    echo "5. Testing todo creation..."
    TODO_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
      -b "session_id=$SESSION_ID" \
      -d '{"title": "Test Todo", "description": "A sample task"}' \
      $SERVER_URL/todos)
    echo "Created Todo: $TODO_RESPONSE"
    
    # Get todos
    echo "6. Testing getting todos..."
    TODOS_RESPONSE=$(curl -s -H "Content-Type: application/json" \
      -b "session_id=$SESSION_ID" \
      $SERVER_URL/todos)
    echo "Todos: $TODOS_RESPONSE"
    
    # Test changing password
    echo "7. Testing password change..."
    PW_RESPONSE=$(curl -s -X PUT -H "Content-Type: application/json" \
      -b "session_id=$SESSION_ID" \
      -d '{"old_password": "password123", "new_password": "newpassword456"}' \
      $SERVER_URL/password)
    echo "Password change response: $PW_RESPONSE"
    
    # Logout
    echo "8. Testing logout..."
    LOGOUT_RESPONSE=$(curl -s -X POST -b "session_id=$SESSION_ID" $SERVER_URL/logout)
    echo "Logout response: $LOGOUT_RESPONSE"
    
    echo "All tests completed."
else
    echo "No session cookie extracted, tests will fail"
fi