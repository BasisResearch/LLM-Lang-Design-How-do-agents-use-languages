#!/bin/bash

# Test script for the TODO API server

echo "Starting server on port 9090..."
scala-cli run Main.scala -- --port 9090 &
SERVER_PID=$!
sleep 5  # Wait for server to start

# Cleanup function
cleanup() {
    kill $SERVER_PID
    wait $SERVER_PID 2>/dev/null
    exit
}
trap cleanup EXIT

BASE_URL="http://localhost:9090"

echo "Testing Registration..."

# Test invalid registration (username too short)
response=$(curl -s -w "%{http_code}" -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 400 ]; then
    echo "✓ Username validation test passed"
else
    echo "✗ Username validation test failed - got status: $status, body: $body"
    cleanup
fi

# Test invalid registration (invalid characters in username)
response=$(curl -s -w "%{http_code}" -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "user@test", "password": "password123"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 400 ]; then
    echo "✓ Invalid character username validation test passed"
else
    echo "✗ Invalid character username validation test failed - got status: $status, body: $body"
    cleanup
fi

# Test invalid registration (password too short)
response=$(curl -s -w "%{http_code}" -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "pass"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 400 ]; then
    echo "✓ Password length validation test passed"
else
    echo "✗ Password length validation test failed - got status: $status, body: $body"
    cleanup
fi

# Register a user
response=$(curl -s -w "%{http_code}" -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 201 ]; then
    echo "✓ User registration test passed"
    USER_ID=$(echo $body | grep -o '"id":[0-9]*' | cut -d':' -f2)
else
    echo "✗ User registration test failed - got status: $status, body: $body"
    cleanup
fi

# Try to register duplicate user
response=$(curl -s -w "%{http_code}" -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 409 ]; then
    echo "✓ Duplicate username test passed"
else
    echo "✗ Duplicate username test failed - got status: $status, body: $body"
    cleanup
fi

echo "Testing Login..."

# Test invalid login
response=$(curl -s -w "%{http_code}" -X POST $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "notexist", "password": "wrongpass"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 401 ]; then
    echo "✓ Invalid login test passed"
else
    echo "✗ Invalid login test failed - got status: $status, body: $body"
    cleanup
fi

# Login successfully
response=$(curl -s -c cookies.txt -w "%{http_code}" -X POST $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 200 ]; then
    echo "✓ Valid login test passed"
else
    echo "✗ Valid login test failed - got status: $status, body: $body"
    cleanup
fi

echo "Testing Protected Routes..."

# Test without auth
response=$(curl -s -w "%{http_code}" -X GET $BASE_URL/me)
status=${response: -3}
body=${response%???}
if [ $status -eq 401 ]; then
    echo "✓ Unauthenticated access blocked test passed"
else
    echo "✗ Unauthenticated access blocked test failed - got status: $status, body: $body"
    cleanup
fi

# Test authorized access to /me
response=$(curl -s -b cookies.txt -w "%{http_code}" -X GET $BASE_URL/me)
status=${response: -3}
body=${response%???}
if [ $status -eq 200 ] && [[ $body =~ .*\"username\":\"testuser\".* ]]; then
    echo "✓ Authenticated '/me' test passed"
else
    echo "✗ Authenticated '/me' test failed - got status: $status, body: $body"
    cleanup
fi

# Test creating a todo
response=$(curl -s -b cookies.txt -w "%{http_code}" -X POST $BASE_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "First Todo", "description": "This is my first todo"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 201 ]; then
    echo "✓ Create todo test passed"
    TODO_ID=$(echo $body | grep -o '"id":[0-9]*' | cut -d':' -f2)
else
    echo "✗ Create todo test failed - got status: $status, body: $body"
    cleanup
fi

# Test getting all todos
response=$(curl -s -b cookies.txt -w "%{http_code}" -X GET $BASE_URL/todos)
status=${response: -3}
body=${response%???}
if [ $status -eq 200 ] && [[ $body == [* ]]; then
    echo "✓ Get all todos test passed"
else
    echo "✗ Get all todos test failed - got status: $status, body: $body"
    cleanup
fi

# Test getting specific todo
response=$(curl -s -b cookies.txt -w "%{http_code}" -X GET $BASE_URL/todos/$TODO_ID)
status=${response: -3}
body=${response%???}
if [ $status -eq 200 ] && [[ $body =~ .*\"id\":$TODO_ID.* ]]; then
    echo "✓ Get specific todo test passed"
else
    echo "✗ Get specific todo test failed - got status: $status, body: $body"
    cleanup
fi

# Test updating specific todo
response=$(curl -s -b cookies.txt -w "%{http_code}" -X PUT $BASE_URL/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated Todo"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 200 ]; then
    echo "✓ Update todo test passed"
else
    echo "✗ Update todo test failed - got status: $status, body: $body"
    cleanup
fi

# Test deleting todo
response=$(curl -s -b cookies.txt -w "%{http_code}" -X DELETE $BASE_URL/todos/$TODO_ID)
status=${response: -3}
body=${response%???}
if [ $status -eq 204 ]; then
    echo "✓ Delete todo test passed"
else
    echo "✗ Delete todo test failed - got status: $status, body: $body"
    cleanup
fi

# Test change password
response=$(curl -s -b cookies.txt -w "%{http_code}" -X PUT $BASE_URL/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword456"}')
status=${response: -3}
body=${response%???}
if [ $status -eq 200 ]; then
    echo "✓ Change password test passed"
else
    echo "✗ Change password test failed - got status: $status, body: $body"
    cleanup
fi

echo "All tests passed successfully!"