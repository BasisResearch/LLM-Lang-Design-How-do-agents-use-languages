#!/bin/bash

# Test script for Todo Server
PORT=8080
SERVER_URL="http://localhost:$PORT"

echo "Starting Todo Server on port $PORT..."
node index.js --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 2

echo "Testing server..."

# Variables to store results between tests
SESSION_COOKIE=""
USER_ID=""
TODO_ID=""

# Test 1: Register a user
echo "Test 1: Registering user 'testuser'"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  "$SERVER_URL/register")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 201 ]; then
  USER_ID=$(echo "$BODY" | grep -o '"id":[^,}]*' | cut -d':' -f2)
  echo "✓ Registration successful, user ID: $USER_ID"
else
  echo "✗ Registration failed, HTTP code: $HTTP_CODE, Response: $BODY"
fi

# Test 2: Try to register duplicate user
echo "Test 2: Attempting to register duplicate user"
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  "$SERVER_URL/register")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 409 ]; then
  echo "✓ Duplicate registration correctly rejected"
else
  echo "✗ Duplicate registration not rejected properly, HTTP code: $HTTP_CODE"
fi

# Test 3: Login and get session cookie
echo "Test 3: Logging in user"
RESPONSE=$(curl -s -c cookies.txt -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  "$SERVER_URL/login")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 200 ]; then
  SESSION_COOKIE=$(grep session_id cookies.txt | awk '{print $7}')
  if [ ! -z "$SESSION_COOKIE" ]; then
    echo "✓ Login successful, session cookie retrieved: ${SESSION_COOKIE:0:12}..."
  else
    echo "✗ Session cookie not found"
  fi
else
  echo "✗ Login failed, HTTP code: $HTTP_CODE, Response: $BODY"
fi

# Use the cookie for subsequent authenticated requests
COOKIES_HEADER="Cookie: session_id=$SESSION_COOKIE"

# Test 4: Get user info (authenticated)
echo "Test 4: Getting user info as authenticated user"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" \
  "$SERVER_URL/me")
  
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Get user info successful: $BODY"
else
  echo "✗ Get user info failed, HTTP code: $HTTP_CODE, Response: $BODY"
fi

# Test 5: Change password (authenticated)
echo "Test 5: Changing password"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpass456"}' \
  "$SERVER_URL/password")
  
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Password change successful"
else
  echo "✗ Password change failed, HTTP code: $HTTP_CODE"
fi

# Test 6: Try to access protected endpoint without authentication
echo "Test 6: Trying to access protected endpoint without auth"
RESPONSE=$(curl -s -w "\n%{http_code}" \
  "$SERVER_URL/me")
  
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 401 ]; then
  echo "✓ Auth required response correct: $BODY"
else
  echo "✗ Auth not required properly, HTTP code: $HTTP_CODE, Response: $BODY"
fi

# Test 7: Create a new todo
echo "Test 7: Creating a new todo item"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "Test Todo", "description": "A sample todo item"}' \
  "$SERVER_URL/todos")
  
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 201 ]; then
  TODO_ID=$(echo "$BODY" | grep -o '"id":[^,}]*' | cut -d':' -f2)
  echo "✓ Todo created successfully, ID: $TODO_ID, Data: $BODY"
else
  echo "✗ Todo creation failed, HTTP code: $HTTP_CODE, Response: $BODY"
fi

# Test 8: Get all todos
echo "Test 8: Getting all todos"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" \
  "$SERVER_URL/todos")
  
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Todos retrieved: $BODY"
else
  echo "✗ Todo retrieval failed, HTTP code: $HTTP_CODE, Response: $BODY"
fi

# Test 9: Get specific todo by ID
echo "Test 9: Getting specific todo by ID $TODO_ID"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" \
  "$SERVER_URL/todos/$TODO_ID")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Specific todo retrieved: $BODY"
else
  echo "✗ Specific todo retrieval failed, HTTP code: $HTTP_CODE, Response: $BODY"
fi

# Test 10: Update todo
echo "Test 10: Updating todo (setting completed to true)"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"completed": true}' \
  "$SERVER_URL/todos/$TODO_ID")
  
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 200 ]; then
  COMPLETED_T=$(echo "$BODY" | grep -o '"completed":[^,}]*' | cut -d':' -f2 | tr -d ' ')
  if [ "$COMPLETED_T" = "true" ]; then
    echo "✓ Todo successfully marked as completed: $BODY"
  else
    echo "✗ Todo completion status not updated properly"
  fi
else
  echo "✗ Todo update failed, HTTP code: $HTTP_CODE, Response: $BODY"
fi

# Test 11: Delete todo
echo "Test 11: Deleting todo"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X DELETE \
  "$SERVER_URL/todos/$TODO_ID")
  
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

if [ "$HTTP_CODE" -eq 204 ]; then
  echo "✓ Todo deleted successfully"
else
  echo "✗ Todo deletion failed, HTTP code: $HTTP_CODE"
fi

# Test 12: Logout
echo "Test 12: Logging out"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X POST \
  "$SERVER_URL/logout")
  
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Logout successful"
else
  echo "✗ Logout failed, HTTP code: $HTTP_CODE"
fi

# Test 13: Verify logout (try to access /me after logout)
echo "Test 13: Verifying logout worked"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" \
  "$SERVER_URL/me")
  
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" -eq 401 ]; then
  echo "✓ Logout verified, auth now required: $BODY"
else
  echo "✗ Logout didn't work, could still access resource, HTTP code: $HTTP_CODE"
fi

echo ""
echo "Stopping server..."
kill $SERVER_PID
wait $SERVER_PID

echo "All tests completed!"
rm -f cookies.txt  # Clean up cookies file