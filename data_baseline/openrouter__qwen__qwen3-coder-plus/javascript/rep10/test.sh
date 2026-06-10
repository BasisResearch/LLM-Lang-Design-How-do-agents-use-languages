#!/bin/bash

# Test script for Todo App
set -e  # Exit on any error

# Start the server in background
PORT=3001
echo "Starting server on port $PORT..."
node server.js --port $PORT &
SERVER_PID=$!
sleep 1  # Give server time to start

# Function to cleanup
cleanup() {
  echo "Stopping server..."
  kill -TERM $SERVER_PID
}
trap cleanup EXIT

# Base URL for API
BASE_URL="http://localhost:$PORT"

echo "Testing endpoints..."

# Test 1: Register a new user
echo "Test 1: Registering a user..."
response=$(curl -s -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')
echo "Response: $response"
if [[ "$response" == *"\"id\""* && "$response" == *"testuser"* ]]; then
  echo "✓ Registration successful"
  USER_ID=$(echo "$response" | grep -o '"id":[^,}]*' | cut -d: -f2)
else
  echo "✗ Registration failed"
  exit 1
fi
echo

# Test 2: Register duplicate user (should fail)
echo "Test 2: Registering duplicate user (should fail)..."
response=$(curl -s -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"anotherpass"}')
echo "Response: $response"
if [[ "$response" == *"Username already exists"* ]]; then
  echo "✓ Duplicate registration correctly rejected"
else
  echo "✗ Duplicate registration incorrectly allowed"
  exit 1
fi
echo

# Test 3: Login
echo "Test 3: Logging in..."
response=$(curl -s -c cookies.txt -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')
echo "Response: $response"
if [[ "$response" == *"\"id\""* && "$response" == *"testuser"* ]]; then
  echo "✓ Login successful"
else
  echo "✗ Login failed"
  exit 1
fi
echo

# Test 4: Try to login with wrong password
echo "Test 4: Login with wrong password (should fail)..."
response=$(curl -s -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"wrongpassword"}')
echo "Response: $response"
if [[ "$response" == *"Invalid credentials"* ]]; then
  echo "✓ Invalid credentials correctly rejected"
else
  echo "✗ Invalid credentials incorrectly allowed"
  exit 1
fi
echo

# Test 5: Check /me endpoint (requires auth)
echo "Test 5: Accessing /me endpoint..."
response=$(curl -s -b cookies.txt "$BASE_URL/me")
echo "Response: $response"
if [[ "$response" == *"testuser"* ]]; then
  echo "✓ /me endpoint works"
else
  echo "✗ /me endpoint failed"
  exit 1
fi
echo

# Test 6: Access protected endpoint without auth (should fail)
echo "Test 6: Accessing /me without auth (should fail)..."
response=$(curl -s "$BASE_URL/me")
echo "Response: $response"
if [[ "$response" == *"Authentication required"* ]]; then
  echo "✓ Protected endpoint correctly rejects unauthenticated access"
else
  echo "✗ Protected endpoint incorrectly allows unauthenticated access"
  exit 1
fi
echo

# Test 7: Create a todo
echo "Test 7: Creating a todo..."
response=$(curl -s -b cookies.txt -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -d '{"title":"My First Todo","description":"Learn how to use this app"}')
echo "Response: $response"
if [[ "$response" == *"My First Todo"* ]]; then
  echo "✓ Todo creation successful"
  TODO_ID=$(echo "$response" | grep -o '"id":[^,}]*' | cut -d: -f2)
else
  echo "✗ Todo creation failed"
  exit 1
fi
echo

# Test 8: Create a todo without title
echo "Test 8: Creating todo without title (should fail)..."
response=$(curl -s -b cookies.txt -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -d '{"description":"This should fail"}')
echo "Response: $response"
if [[ "$response" == *"Title is required"* ]]; then
  echo "✓ Todo without title correctly rejected"
else
  echo "✗ Todo without title incorrectly allowed"
  exit 1
fi
echo

# Test 9: Get all todos
echo "Test 9: Getting all todos..."
response=$(curl -s -b cookies.txt "$BASE_URL/todos")
echo "Response: $response"
if [[ "$response" == *"$TODO_ID"* && "$response" == *"My First Todo"* ]]; then
  echo "✓ Retrieving todos works"
else
  echo "✗ Retrieving todos failed"
  exit 1
fi
echo

# Test 10: Get a specific todo
echo "Test 10: Getting specific todo..."
response=$(curl -s -b cookies.txt "$BASE_URL/todos/$TODO_ID")
echo "Response: $response"
if [[ "$response" == *"My First Todo"* ]]; then
  echo "✓ Getting specific todo works"
else
  echo "✗ Getting specific todo failed"
  exit 1
fi
echo

# Test 11: Update the todo
echo "Test 11: Updating the todo..."
response=$(curl -s -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated Todo","completed":true}')
echo "Response: $response"
if [[ "$response" == *"Updated Todo"* && "$response" == *"true"* ]]; then
  echo "✓ Updating todo works"
else
  echo "✗ Updating todo failed"
  exit 1
fi
echo

# Test 12: Try to update with empty title
echo "Test 12: Updating todo with empty title (should fail)..."
response=$(curl -s -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -d '{"title":"","completed":false}')
echo "Response: $response"
if [[ "$response" == *"Title is required"* ]]; then
  echo "✓ Updating with empty title correctly rejected"
else
  echo "✗ Updating with empty title incorrectly allowed"
  exit 1
fi
echo

# Test 13: Change password
echo "Test 13: Changing password..."
response=$(curl -s -b cookies.txt -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword456"}')
echo "Response: $response"
if [[ "$response" == *"{}"* ]]; then
  echo "✓ Password change successful"
else
  echo "✗ Password change failed"
  exit 1
fi
echo

# Test 14: Try to change password with wrong old password
echo "Test 14: Changing password with wrong old password (should fail)..."
response=$(curl -s -b cookies.txt -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -d '{"old_password":"wrongpassword","new_password":"anotherpassword"}')
echo "Response: $response"
if [[ "$response" == *"Invalid credentials"* ]]; then
  echo "✓ Password change with wrong old password correctly rejected"
else
  echo "✗ Password change with wrong old password incorrectly allowed"
  exit 1
fi
echo

# Test 15: Login after password changed
echo "Test 15: Logging in with new password..."
response=$(curl -s -c new_cookies.txt -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpassword456"}')
echo "Response: $response"
if [[ "$response" == *"testuser"* ]]; then
  echo "✓ Login with new password successful"
else
  echo "✗ Login with new password failed"
  exit 1
fi
echo

# Let's re-identify the todo ID because we're using a new cookie file
MY_TODO_ID=$(curl -s -b new_cookies.txt "$BASE_URL/todos" | grep -o '"id":[^,}]*' | cut -d: -f2)

# Test 16: Delete the todo
echo "Test 16: Deleting the todo with ID $MY_TODO_ID..."
result=$(curl -s -w " Status:%{http_code}" -b new_cookies.txt -X DELETE "$BASE_URL/todos/$MY_TODO_ID")
status=$(echo "$result" | grep Status | sed 's/.*Status://' )
body=$(echo "$result" | sed 's/ Status:.*//')

if [ "$status" -eq 204 ]; then
  echo "Response: Success (Status 204 No Content)"
  echo "✓ Todo deletion successful"
else
  echo "Response Body: $body"
  echo "Response Status: $status"
  echo "Expected Status: 204"
  echo "✗ Todo deletion failed"
  exit 1
fi
echo

# Test 17: Try to get the deleted todo (should fail)
echo "Test 17: Trying to get deleted todo (should fail)..."
response=$(curl -s -w " Status:%{http_code}" -b new_cookies.txt "$BASE_URL/todos/$MY_TODO_ID" | grep Status || true)
status=$(echo "$response" | sed 's/.*Status://' )

if [ "$status" -eq 404 ]; then
  echo "Response Status: $status"
  echo "✓ Getting deleted todo correctly fails"
else
  echo "Response Status: $status"
  echo "✗ Getting deleted todo incorrectly succeeds"
  exit 1
fi
echo

# Test 18: Get all todos after deletion
echo "Test 18: Getting all todos after deletion..."
response=$(curl -s -b new_cookies.txt "$BASE_URL/todos")
echo "Response: $response"

# Check for an empty JSON array [] in various forms
if [[ "$response" == "[]" || "$response" == *"\[\]"* ]]; then
  echo "✓ Todos list is empty after deletion"
else
  echo "✗ Todos list is not empty after deletion, got: $response"
  exit 1
fi
echo

# Test 19: Logout
echo "Test 19: Logging out..."
response=$(curl -s -b new_cookies.txt -X POST "$BASE_URL/logout" \
  -H "Content-Type: application/json")
echo "Response: $response"
if [[ "$response" == *"{}"* ]]; then
  echo "✓ Logout successful"
else
  echo "✗ Logout failed"
  exit 1
fi
echo

# Test 20: Try accessing protected resource after logout
echo "Test 20: Accessing /me after logout (should fail)..."
response=$(curl -s -b new_cookies.txt "$BASE_URL/me")
echo "Response: $response"
if [[ "$response" == *"Authentication required"* ]]; then
  echo "✓ Protected resource correctly requires authentication after logout"
else
  echo "✗ Protected resource incorrectly accessible after logout"
  exit 1
fi
echo

# Test 21: Register user with invalid username (should fail)
echo "Test 21: Registering with invalid username (should fail)..."
response=$(curl -s -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"ab","password":"password123"}')
echo "Response: $response"
if [[ "$response" == *"Invalid username"* ]]; then
  echo "✓ Username too short correctly rejected"
else
  echo "✗ Username too short incorrectly allowed"
  exit 1
fi
echo

# Test 22: Register user with invalid username (special chars not allowed)
echo "Test 22: Registering with special chars in username (should fail)..."
response=$(curl -s -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"user@invalid","password":"password123"}')
echo "Response: $response"
if [[ "$response" == *"Invalid username"* ]]; then
  echo "✓ Username with special chars correctly rejected"
else
  echo "✗ Username with special chars incorrectly allowed"
  exit 1
fi
echo

# Test 23: Register user with short password
echo "Test 23: Registering with short password (should fail)..."
response=$(curl -s -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"validuser","password":"pass"}')
echo "Response: $response"
if [[ "$response" == *"Password too short"* ]]; then
  echo "✓ Short password correctly rejected"
else
  echo "✗ Short password incorrectly allowed"
  exit 1
fi
echo

echo "All tests passed! ✓"

exit 0