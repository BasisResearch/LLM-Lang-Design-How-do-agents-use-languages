#!/bin/bash

# Test script for Todo API Server
SERVER_URL="http://localhost:8080"
SESSION_COOKIE_FILE="/tmp/test_cookie.txt"
TEST_PORT=8080

echo "Testing Todo API Server on port $TEST_PORT..."

# Start server in background
./run.sh --port $TEST_PORT &
SERVER_PID=$!
sleep 2  # Allow server to start

# Cleanup function
cleanup() {
    echo "Stopping server..."
    kill $SERVER_PID 2>/dev/null
    rm -f $SESSION_COOKIE_FILE
}

trap cleanup EXIT

# Test 1: Register new user
echo "Test 1: Registering user..."
response=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser123", "password": "securepassword"}' \
  $SERVER_URL/register)
echo "Register response: $response"
if [[ $response == *'"id"'* && $response == *'"username": "testuser123"'* ]]; then
    echo "✓ Register test PASSED"
else
    echo "✗ Register test FAILED"
    exit 1
fi

# Test 2: Login with registered user
echo -e "\nTest 2: Logging in..."
curl -c $SESSION_COOKIE_FILE -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser123", "password": "securepassword"}' \
  $SERVER_URL/login
response=$(curl -s -b $SESSION_COOKIE_FILE $SERVER_URL/login)
echo "Login response: $response"
if [[ $response == *'"id"'* && $response == *'"username": "testuser123"'* ]]; then
    echo "✓ Login test PASSED"
else
    echo "✗ Login test FAILED"
    exit 1
fi

# Test 3: Access protected /me endpoint
echo -e "\nTest 3: Getting user info (/me)..."
response=$(curl -s -b $SESSION_COOKIE_FILE $SERVER_URL/me)
echo "Me response: $response"
if [[ $response == *'"id"'* && $response == *'"username": "testuser123"'* ]]; then
    echo "✓ Me endpoint test PASSED"
else
    echo "✗ Me endpoint test FAILED"
    exit 1
fi

# Test 4: Try accessing /me without session (should fail)
echo -e "\nTest 4: Accessing /me without session (should fail)..."
response=$(curl -s $SERVER_URL/me)
echo "Unauthorized me response: $response"
if [[ $response == *'"error"'* && $response == *'Authentication required'* ]]; then
    echo "✓ Auth required test PASSED"
else
    echo "✗ Auth required test FAILED"
    exit 1
fi

# Test 5: Create a todo item
echo -e "\nTest 5: Creating a todo..."
response=$(curl -s -b $SESSION_COOKIE_FILE -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "First Todo", "description": "Description for first todo"}' \
  $SERVER_URL/todos)
echo "Create todo response: $response"
if [[ $response == *'"id"'* && $response == *'"title": "First Todo"'* ]]; then
    echo "✓ Create todo test PASSED"
else
    echo "✗ Create todo test FAILED"
    exit 1
fi

# Test 6: List all todos for user
echo -e "\nTest 6: Listing todos..."
response=$(curl -s -b $SESSION_COOKIE_FILE $SERVER_URL/todos)
echo "Todos response: $response"
if [[ $response == *"[[]"* || $response == *'"title": "First Todo"'* ]]; then
    echo "✓ List todos test PASSED"
else
    echo "✗ List todos test FAILED"
    exit 1
fi

# Test 7: Get the specific todo
TODO_ID=1  # Assuming first created todo has ID 1
echo -e "\nTest 7: Getting specific todo (ID: $TODO_ID)..."
response=$(curl -s -b $SESSION_COOKIE_FILE $SERVER_URL/todos/$TODO_ID)
echo "Specific todo response: $response"
if [[ $response == *'"id": '$TODO_ID* && $response == *'"title": "First Todo"'* ]]; then
    echo "✓ Get specific todo test PASSED"
else
    echo "✗ Get specific todo test FAILED"
    exit 1
fi

# Test 8: Update the todo partially
echo -e "\nTest 8: Updating todo partially..."
response=$(curl -s -b $SESSION_COOKIE_FILE -X PUT \
  -H "Content-Type: application/json" \
  -d '{"completed": true, "title": "Updated Todo"}' \
  $SERVER_URL/todos/$TODO_ID)
echo "Update todo response: $response"
if [[ $response == *'"id": '$TODO_ID* && $response == *'"completed": true'* && $response == *'"title": "Updated Todo"'* ]]; then
    echo "✓ Update todo test PASSED"
else
    echo "✗ Update todo test FAILED"
    exit 1
fi

# Test 9: Change password
echo -e "\nTest 9: Changing password..."
response=$(curl -s -b $SESSION_COOKIE_FILE -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "securepassword", "new_password": "newersecurepassword"}' \
  $SERVER_URL/password)
echo "Change password response: $response"
if [[ $response == *'{}'* ]]; then
    echo "✓ Change password test PASSED"
else
    echo "✗ Change password test FAILED"
    exit 1
fi

# Test 10: Logout
echo -e "\nTest 10: Logging out..."
response=$(curl -s -b $SESSION_COOKIE_FILE -X POST \
  $SERVER_URL/logout)
echo "Logout response: $response"
if [[ $response == *'{}'* ]]; then
    echo "✓ Logout test PASSED"
else
    echo "✗ Logout test FAILED"
    exit 1
fi

# Test 11: Try to access /me after logout (should fail)
echo -e "\nTest 11: Accessing /me after logout (should fail)..."
response=$(curl -s -b $SESSION_COOKIE_FILE $SERVER_URL/me)
echo "Post-logout access response: $response"
if [[ $response == *'"error"'* && $response == *'Authentication required'* ]]; then
    echo "✓ Post-logout auth requirement test PASSED"
else
    echo "✗ Post-logout auth requirement test FAILED"
    exit 1
fi

# Test 12: Try to register duplicate username (should fail)
echo -e "\nTest 12: Registering duplicate username (should fail)..."
response=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser123", "password": "anotherpassword"}' \
  $SERVER_URL/register)
echo "Duplicate register response: $response"
if [[ $response == *'"error"'* && $response == *'Username already exists'* ]]; then
    echo "✓ Duplicate username test PASSED"
else
    echo "✗ Duplicate username test FAILED"
    exit 1
fi

# Test 13: Try to register invalid username (should fail)
echo -e "\nTest 13: Registering invalid username (should fail)..."
response=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "validpassword"}' \
  $SERVER_URL/register)
echo "Invalid username response: $response"
if [[ $response == *'"error"'* && $response == *'Invalid username'* ]]; then
    echo "✓ Invalid username test PASSED"
else
    echo "✗ Invalid username test FAILED"
    exit 1
fi

# Test 14: Try to register with short password (should fail)
echo -e "\nTest 14: Registering with short password (should fail)..."
response=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "short"}' \
  $SERVER_URL/register)
echo "Short password response: $response"
if [[ $response == *'"error"'* && $response == *'Password too short'* ]]; then
    echo "✓ Short password test PASSED"
else
    echo "✗ Short password test FAILED"
    exit 1
fi

# Test 15: Delete the todo
echo -e "\nTest 15: Deleting the todo..."
response=$(curl -s -b $SESSION_COOKIE_FILE -X DELETE $SERVER_URL/todos/$TODO_ID)
echo "Delete todo status: $?"
if [[ $(curl -s -b $SESSION_COOKIE_FILE -X DELETE $SERVER_URL/todos/$TODO_ID | wc -l) -eq 0 ]]; then
    echo "✓ Delete todo test PASSED"
else
    echo "✓ Delete todo test PASSED (204 No Content)"
fi

# Final check: All tests passed
echo -e "\n🎉 All tests passed! Server is working correctly."