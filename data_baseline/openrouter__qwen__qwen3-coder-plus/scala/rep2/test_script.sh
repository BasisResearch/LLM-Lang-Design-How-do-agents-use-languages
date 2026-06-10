#!/bin/bash

# Start the server in the background
./run.sh --port 8080 &
SERVER_PID=$!

# Wait for server to start up
sleep 3

# Cleanup function
cleanup() {
    kill $SERVER_PID
}

# Set trap to ensure cleanup happens on exit
trap cleanup EXIT

echo "Testing server..."

# Test variable to track failures
FAILURE_COUNT=0

# Test 1: Register user
echo "Test 1: Register user"
response=$(curl -s -w "%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')

status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 201 ]; then
    USER_ID=$(echo $body | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "✓ Registration successful (User ID: $USER_ID)"
else
    echo "✗ Registration failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 2: Register duplicate user (should fail)
echo "Test 2: Register duplicate user (should fail)"
response=$(curl -s -w "%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 409 ]; then
    echo "✓ Duplicate registration correctly rejected"
else
    echo "✗ Duplicate registration should have failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 3: Login 
echo "Test 3: Login user"
cookies_file=$(mktemp)
response=$(curl -s -c "$cookies_file" -w "%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Login successful"
else
    echo "✗ Login failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 4: Get user info after login
echo "Test 4: Get user info after login"
response=$(curl -s -b "$cookies_file" -w "%{http_code}" http://localhost:8080/me)
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Get user info successful: $body"
else
    echo "✗ Get user info failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 5: Create todo
echo "Test 5: Create todo"
todo_response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Buy groceries", "description": "Milk, eggs, bread"}')
  
status_code="${todo_response: -3}"
todo_body="${todo_response%???}"

if [ $status_code -eq 201 ]; then
    TODO_ID=$(echo $todo_body | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "✓ Todo creation successful (Todo ID: $TODO_ID)"
else
    echo "✗ Todo creation failed: $todo_body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 6: Create todo without title (should fail)
echo "Test 6: Create todo without title (should fail)"
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"description": "A todo with no title"}')
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 400 ]; then
    echo "✓ Missing title correctly rejected: $body"
else
    echo "✗ Missing title should have been rejected: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 7: Get todos
echo "Test 7: Get all todos"
response=$(curl -s -b "$cookies_file" -w "%{http_code}" http://localhost:8080/todos)
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Get todos successful: $body"
else
    echo "✗ Get todos failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 8: Get specific todo
echo "Test 8: Get specific todo"
response=$(curl -s -b "$cookies_file" -w "%{http_code}" http://localhost:8080/todos/$TODO_ID)
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Get specific todo successful: $body"
else
    echo "✗ Get specific todo failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 9: Update todo
echo "Test 9: Update todo"
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X PUT http://localhost:8080/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title": "Buy weekly groceries", "completed": true}')
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Todo update successful: $body"
else
    echo "✗ Todo update failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 10: Update todo with empty title (should fail)
echo "Test 10: Update todo with empty title (should fail)"
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X PUT http://localhost:8080/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title": ""}')
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 400 ]; then
    echo "✓ Empty title update correctly rejected: $body"
else
    echo "✗ Empty title update should have been rejected: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 11: Change password
echo "Test 11: Change password"
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword456"}')
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Password change successful"
else
    echo "✗ Password change failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 12: Try to login with old password (should fail)
echo "Test 12: Try logging in with old password (should fail)"
response=$(curl -s -w "%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 401 ]; then
    echo "✓ Old password correctly rejected: $body"
else
    echo "✗ Old password should have been rejected: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 13: Login with new password
echo "Test 13: Login with new password"
new_cookies_file=$(mktemp)
response=$(curl -s -c "$new_cookies_file" -w "%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newpassword456"}')
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Login with new password successful"
else
    echo "✗ Login with new password failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 14: Delete todo
echo "Test 14: Delete todo"
response=$(curl -s -b "$new_cookies_file" -w "%{http_code}" -X DELETE http://localhost:8080/todos/$TODO_ID)
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 204 ]; then
    echo "✓ Todo deletion successful"
else
    echo "✗ Todo deletion failed - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 15: Try to access deleted todo (should fail)
echo "Test 15: Access deleted todo (should fail)"
response=$(curl -s -b "$new_cookies_file" -w "%{http_code}" http://localhost:8080/todos/$TODO_ID)
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 404 ]; then
    echo "✓ Deleted todo correctly unavailable"
else
    echo "✗ Deleted todo should not be accessible: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 16: Access without authentication
echo "Test 16: Access protected endpoint without authentication"
response=$(curl -s -w "%{http_code}" http://localhost:8080/me)
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 401 ]; then
    echo "✓ Unauthorized access correctly blocked: $body"
else
    echo "✗ Unauthorized access should have been blocked: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 17: Logout
echo "Test 17: Logout"
response=$(curl -s -b "$new_cookies_file" -w "%{http_code}" -X POST http://localhost:8080/logout)
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 200 ]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Test 18: Try accessing after logout (should fail)
echo "Test 18: Access after logout (should fail)"
response=$(curl -s -b "$new_cookies_file" -w "%{http_code}" http://localhost:8080/me)
  
status_code="${response: -3}"
body="${response%???}"

if [ $status_code -eq 401 ]; then
    echo "✓ Access after logout correctly blocked: $body"
else
    echo "✗ Access after logout should have been blocked: $body - Status: $status_code"
    FAILURE_COUNT=$((FAILURE_COUNT + 1))
fi

# Report results
echo ""
if [ $FAILURE_COUNT -eq 0 ]; then
    echo "✓ All tests passed! ($FAILURE_COUNT failures)"
else
    echo "✗ Tests failed! ($FAILURE_COUNT failures)"
fi

wait $SERVER_PID
exit $FAILURE_COUNT