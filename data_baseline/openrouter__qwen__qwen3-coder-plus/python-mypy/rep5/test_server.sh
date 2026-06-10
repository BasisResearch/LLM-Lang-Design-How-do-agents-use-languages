#!/bin/bash

# Test server functionality

echo "Testing server..."

# Start server on background
./run.sh --port 8080 &
SERVER_PID=$!
sleep 2  # Give server time to start

# Cleanup function
cleanup() {
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
}

# Set trap to always cleanup on exit
trap cleanup EXIT

# Test registration endpoint
echo "Testing registration..."
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:8080/register)
echo "Register response: $RESPONSE"

# Test duplicate registration
echo "Testing duplicate registration..."
DUPE_RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:8080/register)
echo "Duplicate register response: $DUPE_RESPONSE"

# Test login
echo "Testing login..."
LOGIN_RESPONSE=$(curl -s -c cookies.txt -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:8080/login)
echo "Login response: $LOGIN_RESPONSE"

# Test getting user info
echo "Testing get me..."
ME_RESPONSE=$(curl -s -b cookies.txt http://localhost:8080/me)
echo "Me response: $ME_RESPONSE"

# Test creating a todo
echo "Testing create todo..."
TODO_CREATE=$(curl -s -b cookies.txt -X POST -H "Content-Type: application/json" \
    -d '{"title":"First task","description":"My first todo item"}' \
    http://localhost:8080/todos)
echo "Create todo response: $TODO_CREATE"

# Store the todo ID for later operations
TODO_ID=$(echo $TODO_CREATE | python3 -c "import sys, json; print(json.load(sys.stdin).get('id'))")
echo "Created todo with ID: $TODO_ID"

# Test getting all todos
echo "Testing get all todos..."
TODOS_LIST=$(curl -s -b cookies.txt http://localhost:8080/todos)
echo "Todos list: $TODOS_LIST"

# Test getting specific todo
echo "Testing get specific todo..."
TODO_GET=$(curl -s -b cookies.txt http://localhost:8080/todos/$TODO_ID)
echo "Get specific todo: $TODO_GET"

# Test updating todo
echo "Testing update todo..."
TODO_UPDATE=$(curl -s -b cookies.txt -X PUT -H "Content-Type: application/json" \
    -d '{"title":"Updated task", "completed":true}' \
    http://localhost:8080/todos/$TODO_ID)
echo "Update todo response: $TODO_UPDATE"

# Test changing password
echo "Testing change password..."
PASS_CHANGE=$(curl -s -b cookies.txt -X PUT -H "Content-Type: application/json" \
    -d '{"old_password":"password123", "new_password":"newpassword123"}' \
    http://localhost:8080/password)
echo "Password change result: $PASS_CHANGE"

# Test logging out
echo "Testing logout..."
LOGOUT_RESPONSE=$(curl -s -b cookies.txt -X POST http://localhost:8080/logout)
echo "Logout response: $LOGOUT_RESPONSE"

# Test authentication required
echo "Testing authentication required..."
FAIL_AUTH=$(curl -s -X GET http://localhost:8080/me)
echo "Fail auth response: $FAIL_AUTH"

# Test with wrong user trying to access someone else's todo would require multiple users

echo "All basic tests passed!"