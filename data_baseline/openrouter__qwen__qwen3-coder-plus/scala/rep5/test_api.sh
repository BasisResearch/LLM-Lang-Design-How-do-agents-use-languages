#!/bin/bash

set -e  # Exit on any error

echo "Starting server..."
timeout 30s scala-cli Main.scala -- --port 8080 &
SERVER_PID=$!
sleep 3  # Give server time to start

# Store cookies for session management
COOKIES_FILE=$(mktemp)

echo "Testing API endpoints..."

# Test 1: Register new user
echo "Test 1: Register user 'testuser'"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  http://localhost:8080/register)
if [ "$HTTP_CODE" = "201" ]; then
  echo "✓ Registration succeeded"
  cat response.json
else
  echo "✗ Registration failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 2: Register duplicate user
echo "Test 2: Register duplicate user"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  http://localhost:8080/register)
if [ "$HTTP_CODE" = "409" ]; then
  echo "✓ Duplicate registration correctly rejected"
  cat response.json
else
  echo "✗ Duplicate registration should have failed - code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 3: Login with registered user
echo "Test 3: Login with registered user"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -c "$COOKIES_FILE" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  http://localhost:8080/login)
if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Login succeeded"
  cat response.json
else
  echo "✗ Login failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 4: Access protected /me endpoint
echo "Test 4: Access /me endpoint"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  http://localhost:8080/me)
if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ /me endpoint accessible with valid session"
  cat response.json
else
  echo "✗ /me endpoint failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 5: Access protected /me endpoint without valid session
echo "Test 5: Access /me without valid session"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  http://localhost:8080/me)
if [ "$HTTP_CODE" = "401" ]; then
  echo "✓ /me correctly requires authentication"
  cat response.json
else
  echo "✗ /me should have required authentication - code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 6: Create todo
echo "Test 6: Create a todo item"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"title":"Sample task","description":"Description of the sample task"}' \
  http://localhost:8080/todos)
if [ "$HTTP_CODE" = "201" ]; then
  echo "✓ Todo created successfully"
  cat response.json
  TODO_ID=$(grep -o '"id":[0-9]*' response.json | cut -d: -f2)
else
  echo "✗ Todo creation failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 7: Get the todo we just created
echo "Test 7: Get the created todo (ID: $TODO_ID)"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  http://localhost:8080/todos/$TODO_ID)
if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Todo retrieved successfully"
  cat response.json
else
  echo "✗ Todo retrieval failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 8: Get all todos
echo "Test 8: Get all todos"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  http://localhost:8080/todos)
if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Todos list retrieved successfully"
  cat response.json
else
  echo "✗ Todos list retrieval failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 9: Update the todo
echo "Test 9: Update the todo (ID: $TODO_ID)"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated Sample Task","completed":true}' \
  http://localhost:8080/todos/$TODO_ID)
if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Todo updated successfully"
  cat response.json
  UPDATED_AT=$(grep -o '"updated_at":"[^"]*"' response.json)
else
  echo "✗ Todo update failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 10: Try to access non-existing todo
echo "Test 10: Try to access non-existing todo"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  http://localhost:8080/todos/9999)
if [ "$HTTP_CODE" = "404" ]; then
  echo "✓ Non-existing todo correctly returns 404"
  cat response.json
else
  echo "✗ Non-existing todo should have returned 404 - code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 11: Change password
echo "Test 11: Change password"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword456"}' \
  http://localhost:8080/password)
if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Password changed successfully"
else
  echo "✗ Password change failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 12: Logout
echo "Test 12: Logout"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  -X POST \
  http://localhost:8080/logout)
if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Logout successful"
else
  echo "✗ Logout failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 13: Try to access /me after logout (should fail)
echo "Test 13: Try accessing /me after logout"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  http://localhost:8080/me)
if [ "$HTTP_CODE" = "401" ]; then
  echo "✓ Access to /me correctly denied after logout"
  cat response.json
else
  echo "✗ /me should have required authentication after logout - code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

# Test 14: Delete todo after logging back in
echo "Test 14: Login again and delete the todo"
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -c "$COOKIES_FILE" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpassword456"}' \
  http://localhost:8080/login)
if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Re-login succeeded"
else
  echo "✗ Re-login failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" -b "$COOKIES_FILE" \
  -X DELETE \
  http://localhost:8080/todos/$TODO_ID)
if [ "$HTTP_CODE" = "204" ]; then
  echo "✓ Todo deleted successfully"
else
  echo "✗ Todo deletion failed with code $HTTP_CODE"
  cat response.json
  kill $SERVER_PID
  exit 1
fi

echo "✓ All tests passed!"

# Clean up
rm "$COOKIES_FILE"
kill $SERVER_PID