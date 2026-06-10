#!/bin/bash

echo "Starting comprehensive test server on port 8000..."
java -cp "bin" com.todo.server.TodoServer --port 8000 &
SERVER_PID=$!

# Wait for server to start 
sleep 2

echo "Running comprehensive tests..."

# Test invalid username during registration
echo "Testing invalid registration (bad username)..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8000/register \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 400 ]; then
    echo "✓ Invalid username properly rejected: $body"
else
    echo "✗ Should have failed with invalid username but got status $status_code: $body"
fi

# Test short password 
echo "Testing invalid registration (short password)..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8000/register \
  -H "Content-Type: application/json" \
  -d '{"username": "test_user", "password": "pass"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 400 ]; then
    echo "✓ Short password properly rejected: $body"
else
    echo "✗ Should have failed with short password but got status $status_code: $body"
fi

# Test registration with special characters in username
echo "Testing invalid registration (special chars)..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8000/register \
  -H "Content-Type: application/json" \
  -d '{"username": "test-user!", "password": "password123"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 400 ]; then
    echo "✓ Special chars in username properly rejected: $body"
else
    echo "✗ Should have failed with special chars but got status $status_code: $body"
fi

# Valid registration
echo "Testing valid registration..."
response=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST http://localhost:8000/register \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "password123"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 201 ]; then
    echo "✓ Valid registration successful: $body"
else
    echo "✗ Valid registration failed: $body"
fi

# Invalid login credentials
echo "Testing invalid login credentials..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8000/login \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "wrongpassword"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 401 ]; then
    echo "✓ Invalid login properly rejected: $body"
else
    echo "✗ Should reject invalid credentials but got status $status_code: $body"
fi

# Valid login
echo "Testing valid login..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8000/login \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "password123"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 200 ]; then
    echo "✓ Valid login successful: $body"
else
    echo "✗ Valid login failed: $body"
fi

# Login and set cookies for future authenticated tests
curl -s -o /dev/null -c cookies.txt -X POST http://localhost:8000/login \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "password123"}'

# Test todo creation with missing title
echo "Testing todo creation with missing title..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST http://localhost:8000/todos \
  -H "Content-Type: application/json" \
  -d '{"description": "Missing title"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 400 ]; then
    echo "✓ Missing title properly rejected: $body"
else
    echo "✗ Should reject missing title but got status $status_code: $body"
fi

# Test todo creation with empty title
echo "Testing todo creation with empty title..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST http://localhost:8000/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "", "description": "Empty title"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 400 ]; then
    echo "✓ Empty title properly rejected: $body"
else
    echo "✗ Should reject empty title but got status $status_code: $body"
fi

# Create a valid todo for later tests
response=$(curl -s -X POST http://localhost:8000/todos \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"title": "Real todo", "description": "Created for testing"}' | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
TODO_ID=$(echo $response | tr -cd '[[:digit:]]')

echo "Created todo with ID: $TODO_ID"

# Try updating with empty title
if [ -n "$TODO_ID" ]; then
    echo "Testing todo update with empty title..."
    response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8000/todos/$TODO_ID \
      -H "Content-Type: application/json" \
      -d '{"title": ""}')
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    if [ "$status_code" -eq 400 ]; then
        echo "✓ Update with empty title properly rejected: $body"
    else
        echo "✗ Should reject update with empty title but got status $status_code: $body"
    fi
fi

# Test accessing non-existent todo
echo "Testing access to non-existent todo..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET http://localhost:8000/todos/999999 \
  -H "Content-Type: application/json")
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 404 ]; then
    echo "✓ Non-existent todo properly rejected: $body"
else
    echo "✗ Should return 404 for non-existent todo but got status $status_code: $body"
fi

# Test changing password with wrong old password
echo "Testing password change with wrong old password..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8000/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "wrong_password", "new_password": "newer_password123"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 401 ]; then
    echo "✓ Wrong old password properly rejected: $body"
else
    echo "✗ Should reject wrong old password but got status $status_code: $body"
fi

# Test changing to short new password
echo "Testing password change to short password..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8000/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "short"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')
if [ "$status_code" -eq 400 ]; then
    echo "✓ Short new password properly rejected: $body"
else
    echo "✗ Should reject short new password but got status $status_code: $body"
fi

kill -9 $SERVER_PID 2>/dev/null
rm -f cookies.txt

echo "Comprehensive tests completed!"