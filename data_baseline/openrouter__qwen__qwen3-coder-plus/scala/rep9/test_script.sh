#!/bin/bash

set -e  # Exit on any error

echo "Starting server..."
./run.sh --port 8080 &
SERVER_PID=$!
sleep 3  # Wait for server to start

# Define cleanup function
cleanup() {
  echo "Stopping server..."
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
  echo "Server stopped."
}
trap cleanup EXIT

# Base URL
BASE_URL="http://localhost:8080"

echo "Testing endpoints..."

# Test 1: Register new user
echo "Test 1: Registering user..."
RESPONSE=$(curl -s -w "%{http_code}" -X POST \
  $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test_user","password":"password123"}')
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ $HTTP_CODE -eq 201 ]; then
  echo "✓ Registration successful"
  USER_ID=$(echo $BODY | grep -o '"id":[0-9]*' | cut -d: -f2)
else
  echo "✗ Registration failed: $BODY (Status: $HTTP_CODE)"
  exit 1
fi

# Test 2: Try to register the same user again
echo "Test 2: Trying to register same user again..."
RESPONSE=$(curl -s -w "%{http_code}" -X POST \
  $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test_user","password":"password123"}')
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 409 ]; then
  echo "✓ Duplicate registration correctly rejected"
else
  echo "✗ Duplicate registration should fail: $RESPONSE"
  exit 1
fi

# Test 3: Login with registered user
echo "Test 3: Logging in..."
RESPONSE=$(curl -s -c cookies.txt -w "%{http_code}" -X POST \
  $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username":"test_user","password":"password123"}')
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 200 ]; then
  echo "✓ Login successful"
else
  echo "✗ Login failed: ${RESPONSE%???} (Status: $HTTP_CODE)"
  exit 1
fi

# Test 4: Get user info with authentication
echo "Test 4: Getting user info with auth..."
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" $BASE_URL/me)
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 200 ]; then
  echo "✓ Got user info successfully"
else
  echo "✗ Getting user info failed: ${RESPONSE%???}"
  exit 1
fi

# Test 5: Create a todo item
echo "Test 5: Creating a todo item..."
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X POST \
  $BASE_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"My first task","description":"A sample task"}')
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 201 ]; then
  echo "✓ Todo created successfully"
  TODO_ID=$(echo "${RESPONSE%???}" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
else
  echo "✗ Todo creation failed: ${RESPONSE%???}"
  exit 1
fi

# Test 6: Get all todos
echo "Test 6: Getting all todos..."
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" $BASE_URL/todos)
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 200 ] && [[ "${RESPONSE%???}" == *"$TODO_ID"* ]]; then
  echo "✓ Retrieved todos successfully"
else
  echo "✗ Todo retrieval failed: ${RESPONSE%???} (Status: $HTTP_CODE)"
  exit 1
fi

# Test 7: Get specific todo
echo "Test 7: Getting specific todo..."
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" "$BASE_URL/todos/$TODO_ID")
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 200 ]; then
  echo "✓ Specific todo retrieved successfully"
else
  echo "✗ Specific todo retrieval failed: ${RESPONSE%???}"
  exit 1
fi

# Test 8: Update a todo 
echo "Test 8: Updating a todo..."
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X PUT \
  "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated task title","completed":true}')
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 200 ]; then
  echo "✓ Todo updated successfully"
else
  echo "✗ Todo update failed: ${RESPONSE%???}"
  exit 1
fi

# Test 9: Try to get todo without authentication (after clearing cookies)
echo "Test 9: Trying to get todos without auth..."
# Use a different cookie file to simulate no-login state
rm -f cookies_temp.txt
RESPONSE=$(curl -s -c cookies_temp.txt -w "%{http_code}" $BASE_URL/todos)
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 401 ]; then
  echo "✓ Unauthenticated request correctly rejected"
else
  echo "✗ Unauthenticated request should fail: ${RESPONSE%???}"
  exit 1
fi

# Test 10: Test logout
echo "Test 10: Logging out..."
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X POST $BASE_URL/logout)
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 200 ]; then
  echo "✓ Logout successful"  
else
  echo "✗ Logout failed: ${RESPONSE%???}"
  exit 1
fi

# Test 11: Make sure user is logged out (try retrieving todos again)
echo "Test 11: Trying to access protected resource after logout..."
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" $BASE_URL/todos)
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 401 ]; then
  echo "✓ After logout access correctly denied"
else
  echo "✗ Access after logout should be denied: ${RESPONSE%???}"
  exit 1
fi

# Test 12: Register and login another user to test data separation  
echo "Test 12: Creating second user and testing data isolation..."
curl -s -X POST \
  $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username":"second_user","password":"password123"}' > /dev/null

curl -s -c cookies2.txt -X POST \
  $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username":"second_user","password":"password123"}' > /dev/null

# Second user creates its own todo
SECOND_TODO_RESPONSE=$(curl -s -b cookies2.txt -X POST \
  $BASE_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"Second user todo","description":"Only seen by second user"}')

SECOND_TODO_ID=$(echo $SECOND_TODO_RESPONSE | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

# First user tries to access second user's todo via ID (should get 404)
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" "$BASE_URL/todos/$SECOND_TODO_ID")
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 404 ]; then
  echo "✓ Cross-user data isolation works correctly"
else
  echo "✗ Cross-user access should not be possible: ${RESPONSE%???}"
  exit 1
fi

echo
echo "All tests passed! ✅"