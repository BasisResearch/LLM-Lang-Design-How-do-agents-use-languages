#!/bin/bash

echo "Testing Todo App API..."

# Configuration
PORT=8080
BASE_URL="http://localhost:$PORT"

# Test variables
TEST_USERNAME="testuser123"
TEST_PASSWORD="password123"
NEW_TODO_TITLE="Test Todo Item"
NEW_TODO_DESC="Test Description"

echo "Starting server in background..."
./target/debug/todo_app --port $PORT &
SERVER_PID=$!
sleep 2

# Test variables for cookies and tokens
COOKIES_FILE=$(mktemp)

# Function to cleanup processes on exit
cleanup() {
    kill $SERVER_PID 2>/dev/null
    rm -f $COOKIES_FILE
}
trap cleanup EXIT

# Test 1: Register
echo ""
echo "=== Test 1: Register ==="
response=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$TEST_USERNAME\", \"password\":\"$TEST_PASSWORD\"}" \
  "$BASE_URL/register")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 201 ]]; then
    USER_ID=$(echo "$response_body" | jq -r '.id')
    echo "✓ Registration successful. User ID: $USER_ID"
else
    echo "✗ Registration failed!"
    exit 1
fi

# Test 2: Login
echo ""
echo "=== Test 2: Login ==="
response=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -c "$COOKIES_FILE" \
  -d "{\"username\":\"$TEST_USERNAME\", \"password\":\"$TEST_PASSWORD\"}" \
  "$BASE_URL/login")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 200 ]]; then
    echo "✓ Login successful."
else
    echo "✗ Login failed!"
    exit 1
fi

# Test 3: Get Me (authenticated)
echo ""
echo "=== Test 3: Get Me (authenticated) ==="
response=$(curl -s -w "\n%{http_code}" \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  "$BASE_URL/me")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 200 ]]; then
    echo "✓ Get Me successful."
else
    echo "✗ Get Me failed!"
    exit 1
fi

# Test 4: Get todos (should be empty initially)
echo ""
echo "=== Test 4: List Todos (initially empty) ==="
response=$(curl -s -w "\n%{http_code}" \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  "$BASE_URL/todos")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 200 && "$response_body" == "[]" ]]; then
    echo "✓ Todo list is initially empty."
else
    echo "✗ Expected empty array but got different response!"
    exit 1
fi

# Test 5: Create a todo
echo ""
echo "=== Test 5: Create Todo ==="
response=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  -d "{\"title\":\"$NEW_TODO_TITLE\", \"description\":\"$NEW_TODO_DESC\"}" \
  "$BASE_URL/todos")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 201 ]]; then
    TODO_ID=$(echo "$response_body" | jq -r '.id')
    echo "✓ Todo created successfully. TODO ID: $TODO_ID"
else
    echo "✗ Todo creation failed!"
    exit 1
fi

# Test 6: Get specific todo
echo ""
echo "=== Test 6: Get Specific Todo ==="
response=$(curl -s -w "\n%{http_code}" \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  "$BASE_URL/todos/$TODO_ID")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 200 ]]; then
    echo "✓ Todo retrieved successfully."
else
    echo "✗ Todo retrieval failed!"
    exit 1
fi

# Test 7: Update todo description
echo ""
echo "=== Test 7: Update Todo Description ==="
NEW_DESCRIPTION="Updated description"
response=$(curl -s -w "\n%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  -d "{\"description\":\"$NEW_DESCRIPTION\"}" \
  "$BASE_URL/todos/$TODO_ID")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 200 ]]; then
    UPDATED_DESC=$(echo "$response_body" | jq -r '.description')
    if [[ "$UPDATED_DESC" == "$NEW_DESCRIPTION" ]]; then
        echo "✓ Todo updated successfully."
    else
        echo "✗ Todo description not updated correctly!"
        exit 1
    fi
else
    echo "✗ Todo update failed!"
    exit 1
fi

# Test 8: Update todo completion status
echo ""
echo "=== Test 8: Update Todo Completion Status ==="
response=$(curl -s -w "\n%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  -d "{\"completed\":true}" \
  "$BASE_URL/todos/$TODO_ID")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 200 ]]; then
    COMPLETED_STATUS=$(echo "$response_body" | jq -r '.completed')
    if [[ "$COMPLETED_STATUS" == "true" ]]; then
        echo "✓ Todo completion status updated successfully."
    else
        echo "✗ Todo completion status not updated correctly!"
        exit 1
    fi
else
    echo "✗ Todo update failed!"
    exit 1
fi

# Test 9: Delete todo
echo ""
echo "=== Test 9: Delete Todo ==="
response=$(curl -s -w "\n%{http_code}" \
  -X DELETE \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  "$BASE_URL/todos/$TODO_ID")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response Body: $response_body"

if [[ $http_code -eq 204 ]]; then
    echo "✓ Todo deleted successfully."
else
    echo "✗ Todo deletion failed!"
    exit 1
fi

# Test 10: Try to get deleted todo (should give 404)
echo ""
echo "=== Test 10: Get Deleted Todo (should return 404) ==="
response=$(curl -s -w "\n%{http_code}" \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  "$BASE_URL/todos/$TODO_ID")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 404 ]]; then
    echo "✓ Got 404 as expected for deleted todo."
else
    echo "✗ Expected 404 but got different status code!"
    exit 1
fi

# Test 11: Change password
echo ""
echo "=== Test 11: Change Password ==="
NEW_PASSWORD="newpassword456"
response=$(curl -s -w "\n%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  -d "{\"old_password\":\"$TEST_PASSWORD\", \"new_password\":\"$NEW_PASSWORD\"}" \
  "$BASE_URL/password")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 200 ]]; then
    echo "✓ Password changed successfully."
else
    echo "✗ Password change failed!"
    exit 1
fi

# Test 12: Logout
echo ""
echo "=== Test 12: Logout ==="
response=$(curl -s -w "\n%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  "$BASE_URL/logout")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

echo "HTTP Status: $http_code"
echo "Response: $response_body"

if [[ $http_code -eq 200 ]]; then
    echo "✓ Logout successful."
else
    echo "✗ Logout failed!"
    exit 1
fi

echo ""
echo "=== All Tests Passed! ==="
echo "✓ Registration"
echo "✓ Login"
echo "✓ Get Me"
echo "✓ Get Todos (empty)"
echo "✓ Create Todo"
echo "✓ Get Todo"
echo "✓ Update Todo Description"
echo "✓ Update Todo Completion"
echo "✓ Delete Todo"
echo "✓ Get Deleted Todo (404)"
echo "✓ Change Password"
echo "✓ Logout"

# Verify the session is invalid by attempting to access protected endpoint after logout
echo ""
echo "=== Verification: Access after logout ==="
response=$(curl -s -w "\n%{http_code}" \
  -X GET \
  -H "Content-Type: application/json" \
  -b "$COOKIES_FILE" \
  "$BASE_URL/me")

http_code=$(echo "$response" | tail -n 1)
response_body=$(echo "$response" | head -n -1)

if [[ $http_code -eq 401 ]]; then
    echo "✓ Session properly invalidated after logout."
else
    echo "✗ Session still active after logout."
fi