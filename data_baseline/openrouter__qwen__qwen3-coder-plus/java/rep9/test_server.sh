#!/bin/bash

echo "Starting server on port 8080..."
java -cp "bin" com.todo.server.TodoServer --port 8080 &
SERVER_PID=$!

# Wait for server to start 
sleep 2

echo "Testing endpoints..."

# Test register endpoint
echo "Testing POST /register..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$status_code" -eq 201 ]; then
    echo "✓ Register successful: $body"
else
    echo "✗ Register failed with status $status_code: $body"
fi

# Try to register duplicate user
echo "Testing duplicate username registration..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password456"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$status_code" -eq 409 ]; then
    echo "✓ Duplicate registration rejected: $body"
else
    echo "✗ Duplicate registration should have failed but got status $status_code: $body"
fi

# Test login
echo "Testing POST /login..."
response=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$status_code" -eq 200 ]; then
    echo "✓ Login successful: $body"
else
    echo "✗ Login failed with status $status_code: $body"
fi

# Store session cookie for future requests
echo "Testing GET /me..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET http://localhost:8080/me)
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$status_code" -eq 200 ]; then
    echo "✓ Get me successful: $body"
else
    echo "✗ Get me failed with status $status_code: $body"
fi

# Test POST /todos
echo "Testing POST /todos..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Test todo", "description": "A test task"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

todo_id=""
if [ "$status_code" -eq 201 ]; then
    echo "✓ Todo creation successful: $body"
    # Extract the todo ID from the response using basic text extraction
    todo_id=$(echo "$body" | sed 's/.*"id":\s*\([0-9]*\).*/\1/' | head -n 1)
else
    echo "✗ Todo creation failed with status $status_code: $body"
fi

# Test GET /todos
echo "Testing GET /todos..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET http://localhost:8080/todos)
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$status_code" -eq 200 ]; then
    echo "✓ Get todos successful: $body"
else
    echo "✗ Get todos failed with status $status_code: $body"
fi

# Test GET /todos/:id
if [ -n "$todo_id" ] && [ "$todo_id" != "" ]; then
    echo "Testing GET /todos/$todo_id..."
    response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET http://localhost:8080/todos/$todo_id)
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$status_code" -eq 200 ]; then
        echo "✓ Get specific todo successful: $body"
    else
        echo "✗ Get specific todo failed with status $status_code: $body"
    fi
    
    # Test PUT /todos/:id
    echo "Testing PUT /todos/$todo_id..."
    response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8080/todos/$todo_id \
      -H "Content-Type: application/json" \
      -d '{"title": "Updated task", "completed": true}')
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$status_code" -eq 200 ]; then
        echo "✓ Update todo successful: $body"
    else
        echo "✗ Update todo failed with status $status_code: $body"
    fi
fi

# Test authentication failure - unauthenticated request to protected endpoint
echo "Testing unauthenticated access to protected endpoint..."
response=$(curl -s -w "\n%{http_code}" -X GET http://localhost:8080/me)
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$status_code" -eq 401 ]; then
    echo "✓ Unauthenticated request properly rejected: $body"
else
    echo "✗ Unauthenticated request should have been rejected but got status $status_code: $body"
fi

# Test password change
echo "Testing PUT /password..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpass456"}')
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$status_code" -eq 200 ]; then
    echo "✓ Password change successful: $body"
else
    echo "✗ Password change failed with status $status_code: $body"
fi

# Test logout
echo "Testing POST /logout..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST http://localhost:8080/logout)
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$status_code" -eq 200 ]; then
    echo "✓ Logout successful: $body"
else
    echo "✗ Logout failed with status $status_code: $body"
fi

# Verify that we're no longer authenticated after logging out
echo "Testing access after logout..."
response=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET http://localhost:8080/me)
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ "$status_code" -eq 401 ]; then
    echo "✓ Post-logout authentication properly rejected: $body"
else
    echo "✗ Post-logout request should have been rejected but got status $status_code: $body"
fi

kill -9 $SERVER_PID 2>/dev/null
rm -f cookies.txt

echo "Tests completed!"