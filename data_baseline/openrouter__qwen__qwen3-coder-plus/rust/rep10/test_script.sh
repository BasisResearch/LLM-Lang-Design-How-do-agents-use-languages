#!/bin/bash

# Test script to verify the Todo App server functionality

echo "Building server..."
./run.sh --port 8080 &
SERVER_PID=$!

sleep 3  # Wait for server to start up

echo "Testing server endpoints..."

# Variables for cookies
COOKIES="cookies.txt"

# Test 1: Register endpoint
echo "Test 1: Register user..."
RESPONSE=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  "http://localhost:8080/register")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" = "201" ] && [[ "$BODY" == *"testuser"* ]] && [[ "$BODY" == *"id"* ]]; then
  echo "✓ Register test PASSED"
else
  echo "✗ Register test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 2: Register with invalid username (< 3 chars)
echo "Test 2: Register with invalid username..."
RESPONSE=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}' \
  "http://localhost:8080/register")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" = "400" ] && [[ "$BODY" == *"Invalid username"* ]]; then
  echo "✓ Invalid username test PASSED"
else
  echo "✗ Invalid username test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 3: Register with invalid password (< 8 chars)
echo "Test 3: Register with short password..."
RESPONSE=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "pass"}' \
  "http://localhost:8080/register")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" = "400" ] && [[ "$BODY" == *"Password too short"* ]]; then
  echo "✓ Short password test PASSED"
else
  echo "✗ Short password test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 4: Register duplicate user
echo "Test 4: Register duplicate user..."
RESPONSE=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  "http://localhost:8080/register")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" = "409" ] && [[ "$BODY" == *"Username already exists"* ]]; then
  echo "✓ Duplicate username test PASSED"
else
  echo "✗ Duplicate username test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 5: Proper Login
echo "Test 5: Login with correct credentials..."
JAR_RESPONSE=$(curl -c $COOKIES -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  "http://localhost:8080/login")

HTTP_CODE="${JAR_RESPONSE: -3}"
BODY="${JAR_RESPONSE%???}"

if [ "$HTTP_CODE" = "200" ] && [[ "$BODY" == *"testuser"* ]] && [[ "$BODY" == *"id"* ]]; then
  echo "✓ Login test PASSED"
else
  echo "✗ Login test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Verify that a session cookie was set
if grep -q "session_id" $COOKIES; then
  echo "✓ Session cookie verified"
else
  echo "✗ Session cookie missing"
fi

# Test 6: Get user info (protected endpoint)
echo "Test 6: Get user info with valid session..."
RESPONSE_WITH_COOKIE=$(curl -b $COOKIES -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/me")

HTTP_CODE="${RESPONSE_WITH_COOKIE: -3}"
BODY="${RESPONSE_WITH_COOKIE%???}"

if [ "$HTTP_CODE" = "200" ] && [[ "$BODY" == *"testuser"* ]]; then
  echo "✓ Get user info test PASSED"
else
  echo "✗ Get user info test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 7: Try protected endpoint without cookie
echo "Test 7: Access protected endpoint without valid cookie..."
RESPONSE_NO_COOKIE=$(curl -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/me")

HTTP_CODE="${RESPONSE_NO_COOKIE: -3}"
BODY="${RESPONSE_NO_COOKIE%???}"

if [ "$HTTP_CODE" = "401" ] && [[ "$BODY" == *"Authentication required"* ]]; then
  echo "✓ Unauthorized access test PASSED"
else
  echo "✗ Unauthorized access test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 8: Add a todo
echo "Test 8: Add a todo..."
TODO_RESPONSE=$(curl -b $COOKIES -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "My First Todo", "description": "Test description"}' \
  "http://localhost:8080/todos")

HTTP_CODE="${TODO_RESPONSE: -3}"
BODY="${TODO_RESPONSE%???}"

if [ "$HTTP_CODE" = "201" ] && [[ "$BODY" == *"My First Todo"* ]]; then
  echo "✓ Add todo test PASSED"
else
  echo "✗ Add todo test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Extract todo ID from response for later testing
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)

# Test 9: Get all todos
echo "Test 9: Get all todos..."
TODOS_RESPONSE=$(curl -b $COOKIES -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/todos")

HTTP_CODE="${TODOS_RESPONSE: -3}"
BODY="${TODOS_RESPONSE%???}"

if [ "$HTTP_CODE" = "200" ] && [[ "$BODY" == *"My First Todo"* ]]; then
  echo "✓ Get todos test PASSED"
else
  echo "✗ Get todos test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 10: Get a specific todo
echo "Test 10: Get specific todo..."
SINGLE_TODO_RESPONSE=$(curl -b $COOKIES -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/todos/$TODO_ID")

HTTP_CODE="${SINGLE_TODO_RESPONSE: -3}"
BODY="${SINGLE_TODO_RESPONSE%???}"

if [ "$HTTP_CODE" = "200" ] && [[ "$BODY" == *"My First Todo"* ]]; then
  echo "✓ Get single todo test PASSED"
else
  echo "✗ Get single todo test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 11: Try getting a non-existent todo
echo "Test 11: Get non-existent todo..."
NONEXISTENT_TODO_RESPONSE=$(curl -b $COOKIES -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/todos/99999")

HTTP_CODE="${NONEXISTENT_TODO_RESPONSE: -3}"
BODY="${NONEXISTENT_TODO_RESPONSE%???}"

if [ "$HTTP_CODE" = "404" ] && [[ "$BODY" == *"Todo not found"* ]]; then
  echo "✓ Non-existent todo test PASSED"
else
  echo "✗ Non-existent todo test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 12: Update a todo
echo "Test 12: Update a todo..."
UPDATE_RESPONSE=$(curl -b $COOKIES -s -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated Todo Title", "completed": true}' \
  "http://localhost:8080/todos/$TODO_ID")

HTTP_CODE="${UPDATE_RESPONSE: -3}"
BODY="${UPDATE_RESPONSE%???}"

if [ "$HTTP_CODE" = "200" ] && [[ "$BODY" == *"Updated Todo Title"* ]] && [[ "$BODY" == *"true"* ]]; then
  echo "✓ Update todo test PASSED"
else
  echo "✗ Update todo test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 13: Delete the todo
echo "Test 13: Delete the todo..."
DELETE_RESPONSE=$(curl -b $COOKIES -s -w "%{http_code}" \
  -X DELETE \
  "http://localhost:8080/todos/$TODO_ID")

HTTP_CODE="${DELETE_RESPONSE: -3}"

if [ "$HTTP_CODE" = "204" ]; then
  echo "✓ Delete todo test PASSED"
else
  echo "✗ Delete todo test FAILED - Got status $HTTP_CODE, Response: $DELETE_RESPONSE"
fi

# Test 14: Change your password (using old password)
echo "Test 14: Change password..."
PASSWORD_CHANGE=$(curl -b $COOKIES -s -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword456"}' \
  "http://localhost:8080/password")

HTTP_CODE="${PASSWORD_CHANGE: -3}"
BODY="${PASSWORD_CHANGE%???}"

if [ "$HTTP_CODE" = "200" ] && [[ "$BODY" == *"{}"* ]]; then
  echo "✓ Password change test PASSED"
else
  echo "✗ Password change test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Test 15: Logout
echo "Test 15: Logout..."
LOGOUT_RESPONSE=$(curl -b $COOKIES -s -w "%{http_code}" \
  -X POST \
  "http://localhost:8080/logout")

HTTP_CODE="${LOGOUT_RESPONSE: -3}"
BODY="${LOGOUT_RESPONSE%???}"

if [ "$HTTP_CODE" = "200" ] && [[ "$BODY" == *"{}"* ]]; then
  echo "✓ Logout test PASSED"
else
  echo "✗ Logout test FAILED - Got status $HTTP_CODE, Response: $BODY"
fi

# Clean up
rm -f $COOKIES
kill $SERVER_PID

wait $SERVER_PID 2>/dev/null

echo "Tests completed!"