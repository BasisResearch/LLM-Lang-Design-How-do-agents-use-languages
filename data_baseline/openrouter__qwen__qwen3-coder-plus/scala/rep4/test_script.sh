#!/bin/bash

set -e

echo "Starting server on port 8080..."
timeout 60 ./run.sh --port 8080 &
SERVER_PID=$!
sleep 3  # Give the server time to start

echo "Server started with PID: $SERVER_PID"

# Test variables
SERVER_URL="http://localhost:8080"

# Test 1: Register a new user
echo "Test 1: Register user johndoe..."
response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"johndoe","password":" secret123"}' \
  $SERVER_URL/register)

status_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | head -n-1)

if [ "$status_code" -eq 201 ]; then
  echo "✓ Register user successful"
else
  echo "✗ Register user failed: $status_code - $response_body"
fi

# Capture session cookie from login response
echo "Test 2: Login user..."
login_response=$(curl -s -D headers.txt -X POST -H "Content-Type: application/json" \
  -d '{"username":"johndoe","password":" secret123"}' \
  $SERVER_URL/login)

status_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
  -d '{"username":"johndoe","password":" secret123"}' \
  $SERVER_URL/login)

# Extract session cookie
SESSION_ID=$(grep -i 'set-cookie:' headers.txt | sed 's/Set-Cookie: session_id=\([^;]*\);.*/\1/')
rm -f headers.txt

if [ -n "$SESSION_ID" ]; then
  echo "✓ Login successful, got session_id: ${SESSION_ID:0:12}..."
else
  echo "✗ Login failed"
fi

# Test 3: Get user info with valid session
echo "Test 3: Get user info..."
response=$(curl -s -w "\n%{http_code}" -b "session_id=$SESSION_ID" -X GET $SERVER_URL/me)

status_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | head -n-1)

if [ "$status_code" -eq 200 ]; then
  echo "✓ Get user info successful"
else
  echo "✗ Get user info failed: $status_code - $response_body"
fi

# Test 4: Create a todo
echo "Test 4: Create a todo..."
response=$(curl -s -w "\n%{http_code}" -b "session_id=$SESSION_ID" -X POST -H "Content-Type: application/json" \
  -d '{"title":"Buy groceries","description":"Need to buy milk, eggs, and bread"}' \
  $SERVER_URL/todos)

status_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | head -n-1)

if [ "$status_code" -eq 201 ]; then
  TODO_ID=$(echo "$response_body" | grep -o '"id":[0-9]*' | cut -d: -f2)
  echo "✓ Create todo successful, ID: $TODO_ID"
else
  echo "✗ Create todo failed: $status_code - $response_body"
fi

# Test 5: Get all todos
echo "Test 5: Get all todos..."
response=$(curl -s -w "\n%{http_code}" -b "session_id=$SESSION_ID" -X GET $SERVER_URL/todos)

status_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | head -n-1)

if [ "$status_code" -eq 200 ]; then
  echo "✓ Get all todos successful"
else
  echo "✗ Get all todos failed: $status_code - $response_body"
fi

# Test 6: Get a specific todo
echo "Test 6: Get specific todo..."
response=$(curl -s -w "\n%{http_code}" -b "session_id=$SESSION_ID" -X GET $SERVER_URL/todos/$TODO_ID)

status_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | head -n-1)

if [ "$status_code" -eq 200 ]; then
  echo "✓ Get specific todo successful"
else
  echo "✗ Get specific todo failed: $status_code - $response_body"
fi

# Test 7: Update a todo
echo "Test 7: Update todo..."
response=$(curl -s -w "\n%{http_code}" -b "session_id=$SESSION_ID" -X PUT -H "Content-Type: application/json" \
  -d '{"title":"Updated task","completed":true}' \
  $SERVER_URL/todos/$TODO_ID)

status_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | head -n-1)

if [ "$status_code" -eq 200 ]; then
  echo "✓ Update todo successful"
else
  echo "✗ Update todo failed: $status_code - $response_body"
fi

# Test 8: Delete a todo
echo "Test 8: Delete todo..."
response=$(curl -s -w "\n%{http_code}" -b "session_id=$SESSION_ID" -X DELETE $SERVER_URL/todos/$TODO_ID)

status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 204 ]; then
  echo "✓ Delete todo successful"
else
  echo "✗ Delete todo failed: $status_code"
fi

# Test 9: Test unauthorized access
echo "Test 9: Try accessing protected route without a token..."
response=$(curl -s -w "\n%{http_code}" -X GET $SERVER_URL/me)

status_code=$(echo "$response" | tail -n1)
response_body=$(echo "$response" | head -n-1)

if [ "$status_code" -eq 401 ]; then
  echo "✓ Properly rejected unauthorized access"
else
  echo "✗ Unauthorized access should have been rejected: $status_code - $response_body"
fi

# Test 10: Logout
echo "Test 10: Logout..."
response=$(curl -s -w "\n%{http_code}" -b "session_id=$SESSION_ID" -X POST $SERVER_URL/logout)

status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 200 ]; then
  echo "✓ Logout successful"
else
  echo "✗ Logout failed: $status_code"
fi

# Clean up
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
echo "Done testing."

# Final verification of the server functionality
echo ""
echo "Testing completed - all endpoints were exercised."