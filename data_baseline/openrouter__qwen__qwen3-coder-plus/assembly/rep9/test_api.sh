#!/bin/bash

# This is a test script to validate the Todo API server
# Will be run after the NASM server is built

set -e  # Exit on any error

PORT=8081
BASE_URL="http://localhost:$PORT"

echo "Testing Todo API Server on port $PORT"

# Wait briefly to ensure server is up
sleep 2

# Temporary file to hold cookies between requests
COOKIES_FILE=$(mktemp)

echo "TEST 1: POST /register"
response=$(curl -s -w "%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')
status_code="${response: -3}"
response_body="${response%???}"

expected='{"id":1,"username":"testuser"}'

if [ $status_code -eq 201 ] && [[ "$response_body" =~ .*id.*username.*testuser.* ]] ; then
    echo "✓ Register test passed"
else
    echo "✗ Register test failed. Expected status 201, got $status_code. Response: $response_body"
    exit 1
fi

echo "TEST 2: POST /register (duplicate user)"
response=$(curl -s -w "%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')
status_code="${response: -3}"
response_body="${response%???}"

if [ $status_code -eq 409 ]; then
    echo "✓ Duplicate registration test passed"
else
    echo "✗ Duplicate registration test failed. Expected status 409, got $status_code"
    exit 1
fi

echo "TEST 3: POST /login"
response=$(curl -s -w "%{http_code}" -X POST "$BASE_URL/login" \
  -c "$COOKIES_FILE" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')
status_code="${response: -3}"

if [ $status_code -eq 200 ]; then
    echo "✓ Login test passed"
else
    echo "✗ Login test failed. Expected status 200, got $status_code. Response: ${response%???}"
    exit 1
fi

echo "TEST 4: GET /me (authenticated)"
response=$(curl -s -w "%{http_code}" -X GET "$BASE_URL/me" \
  -b "$COOKIES_FILE")
status_code="${response: -3}"
response_body="${response%???}"

if [ $status_code -eq 200 ] && [[ "$response_body" =~ .*testuser.* ]]; then
    echo "✓ GET /me authenticated test passed"
else
    echo "✗ GET /me test failed. Expected status 200, got $status_code. Response: $response_body"
    exit 1
fi

echo "TEST 5: POST /logout"
response=$(curl -s -w "%{http_code}" -X POST "$BASE_URL/logout" \
  -b "$COOKIES_FILE")
status_code="${response: -3}"

if [ $status_code -eq 200 ]; then
    echo "✓ Logout test passed"
else
    echo "✗ Logout test failed. Expected status 200, got $status_code"
    exit 1
fi

echo "TEST 6: GET /me after logout (should fail)"
response=$(curl -s -w "%{http_code}" -X GET "$BASE_URL/me" \
  -b "$COOKIES_FILE")
status_code="${response: -3}"

if [ $status_code -eq 401 ]; then
    echo "✓ Authentication check after logout passed"
else
    echo "✗ Authentication after logout check failed. Expected 401, got $status_code"
    exit 1
fi

# Login again for remaining tests
curl -s -X POST "$BASE_URL/login" \
  -c "$COOKIES_FILE" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' > /dev/null

echo "TEST 7: POST /todos"
response=$(curl -s -w "%{http_code}" -X POST "$BASE_URL/todos" \
  -b "$COOKIES_FILE" \
  -H "Content-Type: application/json" \
  -d '{"title":"Test todo","description":"A sample todo item"}')
status_code="${response: -3}"
response_body="${response%???}"

if [ $status_code -eq 201 ] && [[ "$response_body" =~ .*title.*Test\ todo.* ]]; then
    echo "✓ POST /todos test passed"
    # Extract ID for further tests
    TODO_ID=$(echo "$response_body" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    TODO_ID=${TODO_ID:-$(echo "$response_body" | sed -n 's/.*"id":\([0-9]\+\).*/\1/p')}
else
    echo "✗ POST /todos test failed. Expected 201, got $status_code. Response: $response_body"
    exit 1
fi

echo "TEST 8: GET /todos"
response=$(curl -s -w "%{http_code}" -X GET "$BASE_URL/todos" \
  -b "$COOKIES_FILE")
status_code="${response: -3}"
response_body="${response%???}"

if [ $status_code -eq 200 ] && [[ "$response_body" == "["* ]]; then
    echo "✓ GET /todos test passed"
else
    echo "✗ GET /todos test failed. Expected 200 with array, got $status_code. Response: $response_body"
    exit 1
fi

echo "TEST 9: GET /todos/:id"
response=$(curl -s -w "%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" \
  -b "$COOKIES_FILE")
status_code="${response: -3}"
response_body="${response%???}"

if [ $status_code -eq 200 ] && [[ "$response_body" =~ .*Test\ todo.* ]]; then
    echo "✓ GET /todos/:id test passed"
else
    echo "✗ GET /todos/:id test failed. Expected 200, got $status_code. Response: $response_body"
    exit 1
fi

echo "TEST 10: PUT /todos/:id"
response=$(curl -s -w "%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" \
  -b "$COOKIES_FILE" \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated todo","completed":true}')
status_code="${response: -3}"
response_body="${response%???}"

if [ $status_code -eq 200 ] && [[ "$response_body" =~ .*Updated\ todo.* ]] && [[ "$response_body" =~ .*completed.*true.* ]]; then
    echo "✓ PUT /todos/:id test passed"
else
    echo "✗ PUT /todos/:id test failed. Expected 200 and completed:true, got $status_code. Response: $response_body"
    exit 1
fi

echo "TEST 11: DELETE /todos/:id"
response=$(curl -s -w "%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" \
  -b "$COOKIES_FILE")
status_code="${response: -3}"

if [ $status_code -eq 204 ]; then
    echo "✓ DELETE /todos/:id test passed"
else
    echo "✗ DELETE /todos/:id test failed. Expected 204, got $status_code. Response: ${response%???}"
    exit 1
fi

echo "TEST 12: PUT /password"
response=$(curl -s -w "%{http_code}" -X PUT "$BASE_URL/password" \
  -b "$COOKIES_FILE" \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword123"}')
status_code="${response: -3}"

if [ $status_code -eq 200 ]; then
    echo "✓ PUT /password test passed"
else
    echo "✗ PUT /password test failed. Expected 200, got $status_code. Response: ${response%???}"
    exit 1
fi

# Test login with new password
echo "TEST 13: Login with new password"
response=$(curl -s -w "%{http_code}" -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpassword123"}')
status_code="${response: -3}"

if [ $status_code -eq 200 ]; then
    echo "✓ Login with new password test passed"
else
    echo "✗ Login with new password test failed. Expected 200, got $status_code. Response: ${response%???}"
    exit 1
fi

# Clean up
rm -f "$COOKIES_FILE"

echo
echo "All API tests passed! ✓"