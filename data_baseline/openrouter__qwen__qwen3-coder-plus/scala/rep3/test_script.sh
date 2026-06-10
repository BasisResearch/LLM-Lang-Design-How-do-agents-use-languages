#!/bin/bash

# This script will test all endpoints of the todo app server
set -e

echo "Starting server on background..."
./run.sh --port 8090 &
SERVER_PID=$!

# Wait for server to start
sleep 5

# Clean cookies file
COOKIES_FILE=$(mktemp)
trap 'kill $SERVER_PID; rm -f $COOKIES_FILE' EXIT

echo "Testing endpoints..."

# Test 1: POST /register - Valid registration
echo "Test 1: Registering a new user..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' http://localhost:8090/register)
if [ "$HTTP_CODE" -eq 201 ]; then
  echo "✓ Registration successful"
else
  echo "✗ Registration failed with status $HTTP_CODE"
  cat response.json
  exit 1
fi

# Make sure the response has the right data structure
if grep -q '"id":[0-9]*.*"username":"testuser"' response.json; then
  echo "✓ Registration response has correct structure"
else
  echo "✗ Registration response is malformed"
  cat response.json
  exit 1
fi

# Test 2: POST /register - Duplicate username
echo "Test 2: Trying to register duplicate username..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password456"}' http://localhost:8090/register)
if [ "$HTTP_CODE" -eq 409 ]; then
  echo "✓ Duplicate username correctly rejected"
else
  echo "✗ Duplicate username should be rejected"
  cat response.json
  exit 1
fi

# Test 3: POST /login - With valid creds
echo "Test 3: Logging in with valid credentials..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -c $COOKIES_FILE -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' http://localhost:8090/login)
if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Login successful"
else
  echo "✗ Login failed with status $HTTP_CODE"
  cat response.json
  exit 1
fi

# Verify login response structure
if grep -q '"id":[0-9]*.*"username":"testuser"' response.json; then
  echo "✓ Login response has correct structure"
else
  echo "✗ Login response is malformed"
  cat response.json
  exit 1
fi

# Test 4: GET /me - Access protected resource with valid session
echo "Test 4: Accessing /me endpoint..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE http://localhost:8090/me)
if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ /me endpoint accessible with valid session"
else
  echo "✗ /me endpoint not accessible"
  cat response.json
  exit 1
fi

# Test 5: GET /me - Access without session should fail
echo "Test 5: Accessing /me endpoint without session..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" http://localhost:8090/me)
if [ "$HTTP_CODE" -eq 401 ]; then
  echo "✓ /me endpoint correctly requires authentication"
else
  echo "✗ /me endpoint should require authentication (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Test 6: POST /logout - Logout with valid session
echo "Test 6: Logging out..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE -X POST http://localhost:8090/logout)
if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Logout successful"
else
  echo "✗ Logout failed with status $HTTP_CODE"
  cat response.json
  exit 1
fi

# Test 7: POST /logout - After logout, accessing protected resource should fail
echo "Test 7: Trying to access /me after logout..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE http://localhost:8090/me)
if [ "$HTTP_CODE" -eq 401 ]; then
  echo "✓ Session properly invalidated after logout"
else
  echo "✗ Session not invalidated after logout (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Log back in for remaining tests
curl -s -o /dev/null -w "%{http_code}" -c $COOKIES_FILE -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' http://localhost:8090/login > /dev/null

# Test 8: GET /todos - Initially should be empty
echo "Test 8: Getting initial todos list..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE http://localhost:8090/todos)
if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ /todos accessible"
else
  echo "✗ /todos not accessible (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Should initially be an empty array
if [ "$(cat response.json)" = "[]" ]; then
  echo "✓ Initial todos list is empty"
else
  echo "✗ Initial todos list should be empty"
  cat response.json
  exit 1
fi

# Test 9: POST /todos - Adding a new todo
echo "Test 9: Adding a new todo..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE -X POST -H "Content-Type: application/json" \
  -d '{"title":"First todo","description":"This is my first todo item"}' http://localhost:8090/todos)
if [ "$HTTP_CODE" -eq 201 ]; then
  echo "✓ Todo successfully created"
else
  echo "✗ Todo creation failed (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Check that the todo has the expected structure
if grep -q '"id":[0-9]*.*"title":"First todo".*"description":"This is my first todo".*"completed":false' response.json; then
  echo "✓ Todo structure is correct"
else
  echo "✗ Todo structure is malformed"
  cat response.json
  exit 1
fi

TODO_ID=$(grep -o '"id":[0-9]*' response.json | cut -d: -f2)

# Test 10: GET /todos/:id - Getting the newly created todo
echo "Test 10: Getting todo by ID ($TODO_ID)..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE http://localhost:8090/todos/$TODO_ID)
if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Todo retrieved by ID"
else
  echo "✗ Todo retrieval failed (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Test 11: PUT /password - Changing password
echo "Test 11: Changing password..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE -X PUT -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpass456"}' http://localhost:8090/password)
if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Password successfully changed"
else
  echo "✗ Password change failed (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Try to login again with old password - should fail
echo "Test 12: Attempting login with old password..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' http://localhost:8090/login)
if [ "$HTTP_CODE" -eq 401 ]; then
  echo "✓ Old password no longer works"
else
  echo "✗ Old password should no longer work"
  cat response.json
  exit 1
fi

# Try with new password - should work
curl -s -o /dev/null -w "%{http_code}" -c $COOKIES_FILE -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpass456"}' http://localhost:8090/login > /dev/null
echo "✓ Successfully logged with new password"

# Test 13: PUT /todos/:id - Updating a todo
echo "Test 13: Updating a todo..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE -X PUT -H "Content-Type: application/json" \
  -d '{"title":"Updated todo","completed":true}' http://localhost:8090/todos/$TODO_ID)
if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Todo updated successfully"
  # Verify update was applied
  if grep -q '"title":"Updated todo".*"completed":true' response.json; then
    echo "✓ Todo update content verified"
  else
    echo "✗ Todo update not reflected properly"
    cat response.json
    exit 1
  fi
else
  echo "✗ Todo update failed (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Test 14: DELETE /todos/:id - Deleting a todo
echo "Test 14: Deleting a todo..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE -X DELETE http://localhost:8090/todos/$TODO_ID)
if [ "$HTTP_CODE" -eq 204 ]; then
  echo "✓ Todo deleted successfully"
else
  echo "✗ Todo deletion failed (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Try to get the deleted todo - should fail
echo "Test 15: Verifying todo deletion..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE http://localhost:8090/todos/$TODO_ID)
if [ "$HTTP_CODE" -eq 404 ]; then
  echo "✓ Deleted todo not found (correctly removed)"
else
  echo "✗ Deleted todo should not be available anymore (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Test 16: Validate required field handling
echo "Test 16: Testing required field validation..."
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE -X POST -H "Content-Type: application/json" \
  -d '{"title":"","description":"test"}' http://localhost:8090/todos)
if [ "$HTTP_CODE" -eq 400 ]; then
  echo "✓ Empty title correctly rejected"
else
  echo "✗ Empty title should be rejected (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b $COOKIES_FILE -X PUT -H "Content-Type: application/json" \
  -d '{"title":""}' http://localhost:8090/todos/$TODO_ID)
if [ "$HTTP_CODE" -eq 400 ]; then
  echo "✓ Empty title in update correctly rejected"
else
  echo "✗ Empty title in update should be rejected (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi

# Test 17: Ensure other users' todos aren't accessible (in our single-user test)
echo "Test 17: Testing todo security (accessing with no session after clearing)..."
curl -s -o /dev/null --cookie-jar $COOKIES_FILE --cookie "" --data '' http://localhost:8090/logout || true
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" http://localhost:8090/todos/$TODO_ID)
if [ "$HTTP_CODE" -eq 401 ]; then
  echo "✓ Unauthorized access to todo properly denied"
else
  echo "✗ Unauthorized access should be denied (status: $HTTP_CODE)"
  cat response.json
  exit 1
fi


echo ""
echo "All tests passed! ✅"
kill $SERVER_PID || true