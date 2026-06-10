#!/bin/bash

# Test script for Todo App API server
set -e

# Start the server in background (using a temporary port)
PORT=8765
echo "Starting server on port $PORT..."
node server.js --port $PORT &
SERVER_PID=$!
sleep 2  # Give server time to start

# Test variables
COOKIE_FILE=$(mktemp)
API_URL="http://localhost:$PORT"

echo "Testing server..."

# Clean up on exit
trap 'kill $SERVER_PID 2>/dev/null; rm -f $COOKIE_FILE 2>/dev/null' EXIT

# Function to run curl with cookie handling
curl_with_cookie() {
    curl -s -c $COOKIE_FILE -b $COOKIE_FILE --cookie-jar $COOKIE_FILE "$@"
}

echo "=== Testing Registration ==="

# Test registration with valid input
echo "Testing valid registration..."
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    "$API_URL/register")
echo "Register response: $response"
if [[ $response != *"testuser"* ]] || [[ $response != *"id"* ]]; then
    echo "ERROR: Registration failed"
    exit 1
else
    echo "✓ Valid registration passed"
fi

# Test registration validation
echo "Testing registration validation..."
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"ab","password":"password123"}' \
    "$API_URL/register")
echo "Short username response: $response"
if [[ $response != *"Invalid username"* ]]; then
    echo "ERROR: Short username validation failed"
    exit 1
else
    echo "✓ Short username validation passed"
fi

# Test registration with invalid characters in username
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"test@user","password":"password123"}' \
    "$API_URL/register")
echo "Invalid chars username response: $response"
if [[ $response != *"Invalid username"* ]]; then
    echo "ERROR: Invalid character validation failed"
    exit 1
else
    echo "✓ Invalid character validation passed"
fi

# Test registration with short password
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"gooduser","password":"short"}' \
    "$API_URL/register")
echo "Short password response: $response"
if [[ $response != *"Password too short"* ]]; then
    echo "ERROR: Short password validation failed"
    exit 1
else
    echo "✓ Short password validation passed"
fi

# Test duplicate username registration
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    "$API_URL/register")
echo "Duplicate registration response: $response"
if [[ $response != *"Username already exists"* ]]; then
    echo "ERROR: Duplicate username validation failed"
    exit 1
else
    echo "✓ Duplicate username validation passed"
fi

echo "=== Testing Login ==="

# Test successful login
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    "$API_URL/login")
echo "Login response: $response"
if [[ $response != *"testuser"* ]] || [[ $response != *"id"* ]]; then
    echo "ERROR: Login failed"
    exit 1
else
    echo "✓ Successful login passed"
fi

# Test login with wrong credentials
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"wrongpass"}' \
    "$API_URL/login")
echo "Wrong password response: $response"
if [[ $response != *"Invalid credentials"* ]]; then
    echo "ERROR: Wrong password validation failed"
    exit 1
else
    echo "✓ Wrong password validation passed"
fi

echo "=== Testing Authenticated Endpoints ==="

# Test /me endpoint
response=$(curl_with_cookie -X GET "$API_URL/me")
echo "/me response: $response"
if [[ $response != *"testuser"* ]] || [[ $response != *"id"* ]]; then
    echo "ERROR: /me endpoint failed"
    exit 1
else
    echo "✓ /me endpoint passed"
fi

# Test endpoint without auth cookie
cookie_content=$(cat $COOKIE_FILE)
echo "" > $COOKIE_FILE  # Remove cookies
response=$(curl_with_cookie -X GET "$API_URL/me")
echo "/me unauthenticated response: $response"
if [[ $response != *"Authentication required"* ]]; then
    echo "ERROR: Unauthorized access detection failed"
    exit 1
else
    echo "✓ Unauthorized access detection passed"
fi
echo "$cookie_content" > $COOKIE_FILE  # Restore cookies

echo "=== Testing Password Change ==="

# Test changing password with wrong old password
response=$(curl_with_cookie -X PUT -H "Content-Type: application/json" \
    -d '{"old_password":"wrongold","new_password":"newpassword123"}' \
    "$API_URL/password")
echo "Wrong old password response: $response"
if [[ $response != *"Invalid credentials"* ]]; then
    echo "ERROR: Old password validation failed"
    exit 1
else
    echo "✓ Old password validation passed"
fi

# Test changing password with invalid new password
response=$(curl_with_cookie -X PUT -H "Content-Type: application/json" \
    -d '{"old_password":"password123","new_password":"short"}' \
    "$API_URL/password")
echo "Short new password response: $response"
if [[ $response != *"Password too short"* ]]; then
    echo "ERROR: New password validation failed"
    exit 1
else
    echo "✓ New password validation passed"
fi

# Test changing password successfully
response=$(curl_with_cookie -X PUT -H "Content-Type: application/json" \
    -d '{"old_password":"password123","new_password":"newpassword123"}' \
    "$API_URL/password")
echo "Password change response: $response"
if [[ "$response" != "{}" ]]; then
    echo "ERROR: Password change failed"
    exit 1
else
    echo "✓ Password change passed"
fi

# Test login with new password
echo "" > $COOKIE_FILE
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"newpassword123"}' \
    "$API_URL/login")
if [[ $response != *"testuser"* ]]; then
    echo "ERROR: Login with new password failed"
    exit 1
else
    echo "✓ Login with new password passed"
fi

echo "=== Testing Todos Operations ==="

# Test creating a todo
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"title":"Test Todo","description":"This is a test todo item"}' \
    "$API_URL/todos")
echo "Create todo response: $response"
if [[ $response != *"Test Todo"* ]] || [[ $response != *"This is a test todo item"* ]]; then
    echo "ERROR: Creating todo failed"
    exit 1
else
    echo "✓ Create todo passed"
    TODO_ID=$(echo "$response" | grep -o '"id":[0-9]*' | cut -d':' -f2)
fi

# Test creating a todo with empty title
response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"title":"","description":"Empty title test"}' \
    "$API_URL/todos")
echo "Create todo with empty title response: $response"
if [[ $response != *"Title is required"* ]]; then
    echo "ERROR: Empty title validation failed"
    exit 1
else
    echo "✓ Empty title validation passed"
fi

# Test getting all todos
response=$(curl_with_cookie -X GET "$API_URL/todos")
echo "Get todos response: $response"
if [[ $response != *"Test Todo"* ]]; then
    echo "ERROR: Getting todos failed"
    exit 1
else
    echo "✓ Get todos passed"
fi

# Test getting a specific todo
response=$(curl_with_cookie -X GET "$API_URL/todos/$TODO_ID")
echo "Get specific todo response: $response"
if [[ $response != *"Test Todo"* ]]; then
    echo "ERROR: Getting specific todo failed"
    exit 1
else
    echo "✓ Get specific todo passed"
fi

# Test updating a specific todo
response=$(curl_with_cookie -X PUT -H "Content-Type: application/json" \
    -d '{"title":"Updated Test Todo","completed":true}' \
    "$API_URL/todos/$TODO_ID")
echo "Update todo response: $response"
if [[ $response != *"Updated Test Todo"* ]] || [[ $response != *"true"* ]]; then
    echo "ERROR: Updating todo failed"
    exit 1
else
    echo "✓ Update todo passed"
fi

# Test updating with empty title
response=$(curl_with_cookie -X PUT -H "Content-Type: application/json" \
    -d '{"title":"","completed":false}' \
    "$API_URL/todos/$TODO_ID")
echo "Update with empty title response: $response"
if [[ $response != *"Title is required"* ]]; then
    echo "ERROR: Update empty title validation failed"
    exit 1
else
    echo "✓ Update empty title validation passed"
fi

# Test getting updated todo
response=$(curl_with_cookie -X GET "$API_URL/todos/$TODO_ID")
if [[ $response != *"Updated Test Todo"* ]] || [[ $response != *"true"* ]]; then
    echo "ERROR: Getting updated todo failed"
    exit 1
else
    echo "✓ Get updated todo passed"
fi

# Test deleting a todo
http_status=$(curl_with_cookie -w "%{http_code}" -o /dev/null -X DELETE "$API_URL/todos/$TODO_ID")
if [[ "$http_status" != "204" ]]; then
    echo "ERROR: Deleting todo failed - status $http_status"
    exit 1
else
    echo "✓ Delete todo passed"
fi

# Verify todo was removed
response=$(curl_with_cookie -X GET "$API_URL/todos/$TODO_ID")
if [[ $response != *"Todo not found"* ]]; then
    echo "ERROR: Todo was not properly deleted"
    exit 1
else
    echo "✓ Todo deletion verification passed"
fi

echo "=== Testing Logout ==="

# Test logout
response=$(curl_with_cookie -X POST "$API_URL/logout")
echo "Logout response: $response"
if [[ "$response" != *"{}"* ]]; then
    echo "ERROR: Logout failed"
    exit 1
else
    echo "✓ Logout passed"
fi

# Test access after logout (should fail due to session expiration)
response=$(curl_with_cookie -X GET "$API_URL/me")
echo "Access after logout response: $response"
if [[ $response != *"Authentication required"* ]]; then
    echo "ERROR: Access after logout should require auth"
    exit 1
else
    echo "✓ Session invalidate on logout passed"
fi

# Add another user for testing user isolation
rm -f $COOKIE_FILE
curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"otheruser","password":"otherpassword123"}' \
    "$API_URL/register" > /dev/null
    
curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"otheruser","password":"otherpassword123"}' \
    "$API_URL/login" > /dev/null
    
# Create a todo as second user
todo2_response=$(curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"title":"Other User Todo","description":"From other user"}' \
    "$API_URL/todos")

TODO2_ID=$(echo "$todo2_response" | grep -o '"id":[0-9]*' | cut -d':' -f2)

# Switch back to first user session
rm -f $COOKIE_FILE
curl_with_cookie -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"newpassword123"}' \
    "$API_URL/login" > /dev/null

echo "=== Testing User Isolation ==="

# Try to access other user's todo (should fail)
response=$(curl_with_cookie -X GET "$API_URL/todos/$TODO2_ID")
if [[ $response != *"Todo not found"* ]]; then
    echo "ERROR: User isolation failed - could access another user's todo"
    exit 1
else
    echo "✓ User isolation test passed"
fi

# Try to update other user's todo (should fail)
response=$(curl_with_cookie -X PUT -H "Content-Type: application/json" \
    -d '{"title":"Attempted update"}' \
    "$API_URL/todos/$TODO2_ID")
if [[ $response != *"Todo not found"* ]]; then
    echo "ERROR: User isolation failed - could update another user's todo"
    exit 1
else
    echo "✓ User isolation write protection passed"
fi

# Try to delete other user's todo (should fail)
response=$(curl_with_cookie -X DELETE -w "%{http_code}" -o /dev/null -X DELETE "$API_URL/todos/$TODO2_ID")
# Check status using the right approach
status_check=$(curl -s -w "%{http_code}" -o /tmp/curl_output -X DELETE -b $COOKIE_FILE "$API_URL/todos/$TODO2_ID")
if [[ ${status_check: -3} != "404" ]]; then  # Last 3 characters should be 404
    echo "ERROR: User isolation failed - could delete another user's todo"
    echo "$(cat /tmp/curl_output)"
    exit 1
else
    echo "✓ User isolation delete protection passed"
fi

echo ""
echo "All tests passed! ✅"
echo "Server is working correctly."