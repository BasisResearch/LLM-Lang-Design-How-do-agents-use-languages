#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

echo "Starting API server tests..."

# Start the server on background, using a port that's likely free
PORT=${TEST_PORT:-8080}
echo "Starting server on port $PORT"

npx tsx server.ts --port=$PORT &
SERVER_PID=$!

# Give the server some time to start
sleep 2

BASE_URL="http://localhost:$PORT"
COOKIES_FILE=$(mktemp)

# Clean up on exit
cleanup() {
    rm -f "$COOKIES_FILE"
    kill $SERVER_PID || true
}
trap cleanup EXIT

echo "=== Running tests ==="

# Test 1: Register a user
echo "1. Testing user registration..."
response=$(curl -s -c "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X POST -d '{"username":"testuser","password":"secret123"}' "$BASE_URL/register")
status=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
    -X POST -d '{"username":"testuser","password":"secret123"}' "$BASE_URL/register")

if [ $status -eq 201 ]; then
    user_data=$(echo $response | jq -r '.')
    echo "   ✓ Registration succeeded: $user_data"
else
    echo "   ✗ Registration failed. Status: $status, Response: $response"
    exit 1
fi

# Test 2: Try to register duplicate user
echo "2. Testing duplicate registration..."
response=$(curl -s -H "Content-Type: application/json" \
    -X POST -d '{"username":"testuser","password":"secret123"}' "$BASE_URL/register")
status=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
    -X POST -d '{"username":"testuser","password":"secret123"}' "$BASE_URL/register")

if [ $status -eq 409 ]; then
    error_msg=$(echo $response | jq -r '.error')
    if [ "$error_msg" = "Username already exists" ]; then
        echo "   ✓ Duplicate registration correctly blocked: $error_msg"
    else
        echo "   ✗ Wrong error message: $response"
        exit 1
    fi
else
    echo "   ✗ Expected 409 conflict, got: $status"
    exit 1
fi

# Test 3: Login
echo "3. Testing login..."
response=$(curl -s -c "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X POST -d '{"username":"testuser","password":"secret123"}' "$BASE_URL/login")
status=$(curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" \
    -X POST -d '{"username":"testuser","password":"secret123"}' "$BASE_URL/login")

if [ $status -eq 200 ]; then
    user_data=$(echo $response | jq -r '.')
    echo "   ✓ Login succeeded: $user_data"
else
    echo "   ✗ Login failed. Status: $status, Response: $response"
    exit 1
fi

# Test 4: Access protected route - GET /me
echo "4. Testing protected route /me..."
response=$(curl -s -b "$COOKIES_FILE" "$BASE_URL/me")
status=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIES_FILE" "$BASE_URL/me")

if [ $status -eq 200 ]; then
    user_info=$(echo $response | jq -r '.')
    echo "   ✓ /me endpoint worked: $user_info"
else
    echo "   ✗ /me endpoint failed. Status: $status, Response: $response"
    exit 1
fi

# Test 5: Try to access protected route without auth
echo "5. Testing protected route without auth..."
response=$(curl -s "$BASE_URL/me")
status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/me")

if [ $status -eq 401 ]; then
    error_msg=$(echo $response | jq -r '.error')
    if [ "$error_msg" = "Authentication required" ]; then
        echo "   ✓ Unauthenticated access correctly blocked: $error_msg"
    else
        echo "   ✗ Wrong error message: $response"
        exit 1
    fi
else
    echo "   ✗ Expected 401, got: $status"
    exit 1
fi

# Test 6: Create a todo
echo "6. Testing creating todo..."
todo_response=$(curl -s -b "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X POST -d '{"title":"Test Todo","description":"A test todo item"}' "$BASE_URL/todos")
status=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X POST -d '{"title":"Test Todo","description":"A test todo item"}' "$BASE_URL/todos")

if [ $status -eq 201 ]; then
    todo=$(echo $todo_response | jq -r '.')
    TODO_ID=$(echo $todo_response | jq -r '.id')
    echo "   ✓ Todo created: ID $TODO_ID"
else
    echo "   ✗ Todo creation failed. Status: $status, Response: $todo_response"
    exit 1
fi

# Test 7: Get all todos
echo "7. Testing getting all todos..."
response=$(curl -s -b "$COOKIES_FILE" "$BASE_URL/todos")
status=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIES_FILE" "$BASE_URL/todos")

if [ $status -eq 200 ]; then
    count=$(echo $response | jq 'length')
    echo "   ✓ Got $count todos"
else
    echo "   ✗ Failed to get todos. Status: $status, Response: $response"
    exit 1
fi

# Test 8: Get specific todo
echo "8. Testing getting specific todo..."
response=$(curl -s -b "$COOKIES_FILE" "$BASE_URL/todos/$TODO_ID")
status=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIES_FILE" "$BASE_URL/todos/$TODO_ID")

if [ $status -eq 200 ]; then
    title=$(echo $response | jq -r '.title')
    echo "   ✓ Retrieved todo titled: '$title'"
else
    echo "   ✗ Failed to get specific todo. Status: $status, Response: $response"
    exit 1
fi

# Test 9: Update a todo partially
echo "9. Testing updating todo..."
update_response=$(curl -s -b "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X PUT -d '{"completed":true}' "$BASE_URL/todos/$TODO_ID")
status=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X PUT -d '{"completed":true}' "$BASE_URL/todos/$TODO_ID")

if [ $status -eq 200 ]; then
    updated_todo=$(echo $update_response | jq -r '.')
    is_completed=$(echo $updated_todo | jq -r '.completed')
    if [ "$is_completed" = "true" ]; then
        echo "   ✓ Todo updated successfully, completed: $is_completed"
    else
        echo "   ✗ Todo completion status not updated correctly"
        exit 1
    fi
else
    echo "   ✗ Todo update failed. Status: $status, Response: $update_response"
    exit 1
fi

# Test 10: Delete a todo
echo "10. Testing deleting todo..."
status=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIES_FILE" \
    -X DELETE "$BASE_URL/todos/$TODO_ID")

if [ $status -eq 204 ]; then
    echo "   ✓ Todo deleted successfully"
else
    echo "   ✗ Todo deletion failed. Status: $status"
    exit 1
fi

# Test 11: Test password change
echo "11. Testing password change..."
change_response=$(curl -s -b "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X PUT -d '{"old_password":"secret123","new_password":"newpassword123"}' "$BASE_URL/password")
status=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X PUT -d '{"old_password":"secret123","new_password":"new_password123"}' "$BASE_URL/password")

if [ $status -eq 200 ]; then
    echo "   ✓ Password changed successfully"
else
    response_error=$(echo $change_response 2>/dev/null || echo "Request failed")
    echo "   ✗ Password change failed. Status: $status, Response: $response_error"
    exit 1
fi

# Test 12: Logout
echo "12. Testing logout..."
response=$(curl -s -b "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X POST "$BASE_URL/logout")
status=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIES_FILE" -H "Content-Type: application/json" \
    -X POST "$BASE_URL/logout")

if [ $status -eq 200 ]; then
    echo "   ✓ Logout successful"
else
    echo "   ✗ Logout failed. Status: $status, Response: $response"
    exit 1
fi

echo ""
echo "=== All Tests Passed! ==="
echo ""
echo "Summary:"
echo "- User registration works"
echo "- Login/logout flow works"
echo "- Cookie authentication works"
echo "- Creating todos works"
echo "- Retrieving todos works"
echo "- Updating todos works"
echo "- Deleting todos works"
echo "- Password change works"
echo "- Error handling works"

# Clean up
rm -f "$COOKIES_FILE"
kill $SERVER_PID || true