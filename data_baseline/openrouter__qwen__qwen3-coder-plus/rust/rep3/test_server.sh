#!/bin/bash

set -e  # Exit on any error

echo "Starting test server in background..."
timeout 30s ./target/debug/todo-api --port 42069 &
SERVER_PID=$!
sleep 2  # Give the server a moment to start

# Clean up on exit
cleanup() {
    kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Test variables
BASE_URL="http://localhost:42069"

echo "Testing REGISTER endpoint..."

# Test registering a new user
response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  "$BASE_URL/register")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 201 ] && echo "$body" | grep -q '"id"'; then
    echo "✓ Register successful user test passed"
else
    echo "✗ Register successful user test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test registering with invalid username
response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"ab","password":"password123"}' \
  "$BASE_URL/register")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 400 ] && echo "$body" | grep -q 'Invalid username'; then
    echo "✓ Register invalid username test passed"
else
    echo "✗ Register invalid username test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test registering with short password
response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"uniqueuser","password":"short"}' \
  "$BASE_URL/register")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 400 ] && echo "$body" | grep -q 'Password too short'; then
    echo "✓ Register short password test passed"
else
    echo "✗ Register short password test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test registering duplicate username
response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  "$BASE_URL/register")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 409 ] && echo "$body" | grep -q 'already exists'; then
    echo "✓ Register duplicate username test passed"
else
    echo "✗ Register duplicate username test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

echo "Testing LOGIN endpoint..."

# Extract session cookie for further testing
response=$(curl -s -c cookies.txt -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  "$BASE_URL/login")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 200 ] && echo "$body" | grep -q '"id"'; then
    echo "✓ Login successful test passed"
else
    echo "✗ Login successful test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test login with invalid credentials
response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"nonexistent","password":"wrongpass"}' \
  "$BASE_URL/login")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 401 ] && echo "$body" | grep -q 'Invalid credentials'; then
    echo "✓ Login invalid credentials test passed"
else
    echo "✗ Login invalid credentials test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Get user_id from the login response for creating todos
user_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)

echo "Testing protected endpoints without authentication..."

# Test accessing protected endpoint without auth
response=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 401 ] && echo "$body" | grep -q 'Authentication required'; then
    echo "✓ Me endpoint without auth test passed"
else
    echo "✗ Me endpoint without auth test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test accessing protected endpoint with auth (using cookies file) 
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X GET "$BASE_URL/me")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 200 ] && echo "$body" | grep -q "\"id\":$user_id"; then
    echo "✓ Me endpoint with auth test passed"
else
    echo "✗ Me endpoint with auth test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test change password endpoint
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword123"}' \
  "$BASE_URL/password")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 200 ] && echo "$body" | grep -q '{}'; then
    echo "✓ Password change test passed"
else
    echo "✗ Password change test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test changing password with wrong old password
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" \
  -d '{"old_password":"wrongpassword","new_password":"anotherpassword"}' \
  "$BASE_URL/password")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 401 ] && echo "$body" | grep -q 'Invalid credentials'; then
    echo "✓ Password change with wrong old password test passed"
else
    echo "✗ Password change with wrong old password test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test create todo
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"title":"Test Todo","description":"A test todo item"}' \
  "$BASE_URL/todos")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 201 ] && echo "$body" | grep -q '"title":"Test Todo"'; then
    echo "✓ Create todo test passed"
else
    echo "✗ Create todo test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Get the created todo ID for subsequent tests
todo_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)

# Test create todo with empty title
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"title":"","description":"A todo with empty title"}' \
  "$BASE_URL/todos")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 400 ] && echo "$body" | grep -q 'Title is required'; then
    echo "✓ Create todo with empty title test passed"
else
    echo "✗ Create todo with empty title test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test get todos
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X GET "$BASE_URL/todos")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 200 ] && echo "$body" | grep -q "Test Todo"; then
    echo "✓ Get todos test passed"
else
    echo "✗ Get todos test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test get specific todo
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X GET "$BASE_URL/todos/$todo_id")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 200 ] && echo "$body" | grep -q "Test Todo"; then
    echo "✓ Get specific todo test passed"
else
    echo "✗ Get specific todo test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test getting a non-existent todo
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X GET "$BASE_URL/todos/999999")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 404 ] && echo "$body" | grep -q 'not found'; then
    echo "✓ Get non-existent todo test passed"
else
    echo "✗ Get non-existent todo test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test update todo
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" \
  -d '{"title":"Updated Todo","completed":true}' \
  "$BASE_URL/todos/$todo_id")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 200 ] && echo "$body" | grep -q 'Updated Todo'; then
    echo "✓ Update todo test passed"
else
    echo "✗ Update todo test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test update todo with empty title
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" \
  -d '{"title":""}' \
  "$BASE_URL/todos/$todo_id")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 400 ] && echo "$body" | grep -q 'Title is required'; then
    echo "✓ Update todo with empty title test passed"
else
    echo "✗ Update todo with empty title test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test delete todo
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$todo_id")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 204 ]; then
    echo "✓ Delete todo test passed"
else
    echo "✗ Delete todo test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Try to get the deleted todo
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X GET "$BASE_URL/todos/$todo_id")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 404 ] && echo "$body" | grep -q 'not found'; then
    echo "✓ Get deleted todo (should fail) test passed"
else
    echo "✗ Get deleted todo (should fail) test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Test logout
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X POST "$BASE_URL/logout")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 200 ]; then
    echo "✓ Logout test passed"
else
    echo "✗ Logout test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

# Verify session was destroyed by trying to access protected endpoint
response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X GET "$BASE_URL/me")
status_code=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)

if [ $status_code -eq 401 ] && echo "$body" | grep -q 'Authentication required'; then
    echo "✓ Session invalidated after logout test passed"
else
    echo "✗ Session invalidated after logout test failed"
    echo "Response ($status_code): $body"
    exit 1
fi

echo "All tests passed!"
echo ""
echo "Summary of functionality tested:"
echo "- POST /register (valid and invalid cases)"
echo "- POST /login (valid and invalid cases)"
echo "- POST /logout"
echo "- GET /me"
echo "- PUT /password (valid and invalid cases)"
echo "- GET /todos"
echo "- POST /todos (valid and invalid cases)"
echo "- GET /todos/{id}"
echo "- PUT /todos/{id} (valid and invalid cases)"
echo "- DELETE /todos/{id}"

cleanup
exit 0