#!/bin/bash

# Test script for Todo API server

# Start server in background
echo "Starting server on port 8080..."
./run.sh --port 8080 &
SERVER_PID=$!

# Wait a moment for server to start
sleep 3

# Function to check if server is running
check_server() {
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "Server stopped unexpectedly during testing"
        exit 1
    fi
}

echo "Testing API endpoints..."

# Test 1: Register a new user
echo "Test 1: Register new user"
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser1", "password": "testpassword123"}' \
  http://localhost:8080/register)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 201 ]; then
    echo "✓ Register - SUCCESS"
    # Extract session cookie from headers
    session_id=$(curl -s -D - -o /dev/null \
      -X POST \
      -H "Content-Type: application/json" \
      -d '{"username": "testuser1", "password": "testpassword123"}' \
      http://localhost:8080/register | grep -i "Set-Cookie" | grep -o 'session_id=[^;]*')
    session_id=${session_id#session_id=}
else
    echo "✗ Register - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

# Create a cookie string for subsequent requests
cookie="session_id=$session_id"

check_server

# Test 2: Try to register with same username (should fail)
echo "Test 2: Register duplicate username (should fail)"
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser1", "password": "testpassword123"}' \
  http://localhost:8080/register)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 409 ]; then
    echo "✓ Duplicate registration - CORRECTLY FAILED"
else
    echo "✗ Duplicate registration - SHOULD HAVE FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 3: Login with new user
echo "Test 3: Login as registered user"
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser1", "password": "testpassword123"}' \
  -c cookies.txt \
  http://localhost:8080/login)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Login - SUCCESS"
else
    echo "✗ Login - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 4: Access protected endpoint without session (should fail)
echo "Test 4: Protected endpoint without session (should fail)"
response=$(curl -s -w "%{http_code}" \
  http://localhost:8080/me)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 401 ]; then
    echo "✓ Unauthenticated request - CORRECTLY FAILED"
else
    echo "✗ Unauthenticated request - SHOULD HAVE FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 5: Access protected endpoint with session
echo "Test 5: Get current user with session"
response=$(curl -s -w "%{http_code}" \
  -H "Cookie: $cookie" \
  http://localhost:8080/me)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Get current user - SUCCESS"
else
    echo "✗ Get current user - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 6: Create todo item
echo "Test 6: Create a todo item"
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -H "Cookie: $cookie" \
  -d '{"title": "Buy groceries", "description": "Milk, eggs, bread"}' \
  http://localhost:8080/todos)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 201 ]; then
    echo "✓ Create todo - SUCCESS"
    todo_id=$(echo $body | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
    echo "  Created todo with ID: $todo_id"
else
    echo "✗ Create todo - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 7: List todos
echo "Test 7: List todos"
response=$(curl -s -w "%{http_code}" \
  -H "Cookie: $cookie" \
  http://localhost:8080/todos)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ List todos - SUCCESS"
else
    echo "✗ List todos - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 8: Get specific todo
echo "Test 8: Get specific todo"
response=$(curl -s -w "%{http_code}" \
  -H "Cookie: $cookie" \
  http://localhost:8080/todos/$todo_id)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Get specific todo - SUCCESS"
else
    echo "✗ Get specific todo - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 9: Update todo
echo "Test 9: Update todo"
response=$(curl -s -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -H "Cookie: $cookie" \
  -d '{"title": "Buy groceries - URGENT", "completed": true}' \
  http://localhost:8080/todos/$todo_id)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Update todo - SUCCESS"
else
    echo "✗ Update todo - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 10: Delete todo
echo "Test 10: Delete todo"
response=$(curl -s -w "%{http_code}" \
  -X DELETE \
  -H "Cookie: $cookie" \
  http://localhost:8080/todos/$todo_id)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 204 ]; then
    echo "✓ Delete todo - SUCCESS"
else
    echo "✗ Delete todo - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 11: Try to get deleted todo (should fail)
echo "Test 11: Get deleted todo (should fail)"
response=$(curl -s -w "%{http_code}" \
  -H "Cookie: $cookie" \
  http://localhost:8080/todos/$todo_id)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 404 ]; then
    echo "✓ Deleted todo - CORRECTLY FAILED"
else
    echo "✗ Deleted todo - SHOULD HAVE FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

check_server

# Test 12: Logout
echo "Test 12: Logout"
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Cookie: $cookie" \
  http://localhost:8080/logout)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Logout - SUCCESS"
else
    echo "✗ Logout - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

# Test 13: Try to access protected endpoint after logout (should fail)
echo "Test 13: Access protected endpoint after logout (should fail)"
response=$(curl -s -w "%{http_code}" \
  -H "Cookie: $cookie" \
  http://localhost:8080/me)
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 401 ]; then
    echo "✓ Post-logout protection - CORRECTLY WORKING"
else
    echo "✗ Post-logout protection - FAILED ($status_code)"
    echo "Response: $body"
    kill $SERVER_PID
    exit 1
fi

echo ""
echo "All tests passed!"

# Clean up
kill $SERVER_PID
rm -f cookies.txt

echo "Testing completed successfully!"