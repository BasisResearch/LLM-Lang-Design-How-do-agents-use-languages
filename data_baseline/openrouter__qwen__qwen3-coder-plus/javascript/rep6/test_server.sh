#!/bin/bash

# Test script for Todo App API

set -e  # Exit on any error

# Define colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to print colored output
print_test_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}PASS${NC}: $2"
    else
        echo -e "${RED}FAIL${NC}: $2"
        exit 1
    fi
}

print_header() {
    echo -e "${YELLOW}========== $1 ==========${NC}"
}

# Port to run tests on
TEST_PORT=${1:-8080}
# Start the server in the background
node server.js --port $TEST_PORT &
SERVER_PID=$!

# Give the server some time to start
sleep 2

# Function to kill server on exit
cleanup() {
    kill $SERVER_PID
}
trap cleanup EXIT

# Base URL
BASE_URL="http://localhost:$TEST_PORT"

print_header "Testing Endpoints"

# TEST 1: Register new user
print_header "Test 1: POST /register"
RESPONSE=$(curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 201 ] && echo "$RESPONSE_BODY" | grep -q '"id":1' && echo "$RESPONSE_BODY" | grep -q '"username":"testuser"'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Register user: Valid user registration should succeed"

# TEST 2: Register duplicate user (should fail)
print_header "Test 2: POST /register (duplicate)"
RESPONSE=$(curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 409 ] && echo "$RESPONSE_BODY" | grep -q 'Username already exists'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Register duplicate user: Should return 409 Conflict"

# TEST 3: Register with invalid username (too short)
print_header "Test 3: POST /register (invalid username short)"
RESPONSE=$(curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 400 ] && echo "$RESPONSE_BODY" | grep -q 'Invalid username'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Register with short username: Should return 400"

# TEST 4: Register with invalid username (invalid chars)
print_header "Test 4: POST /register (invalid chars)"
RESPONSE=$(curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "test@user", "password": "password123"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 400 ] && echo "$RESPONSE_BODY" | grep -q 'Invalid username'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Register with invalid chars username: Should return 400"

# TEST 5: Register with weak password (too short)
print_header "Test 5: POST /register (weak password)"
RESPONSE=$(curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 400 ] && echo "$RESPONSE_BODY" | grep -q 'Password too short'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Register with weak password: Should return 400"

# TEST 6: Successful login
print_header "Test 6: POST /login"
COOKIE_FILE=$(mktemp)
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c $COOKIE_FILE -w "HTTP_CODE:%{http_code}" > /tmp/login_resp
RESPONSE_BODY=$( cat /tmp/login_resp | sed 's/HTTP_CODE.*$//g')
HTTP_CODE=$( cat /tmp/login_resp | grep -o 'HTTP_CODE:[0-9]*' | sed 's/HTTP_CODE://' )

if [ $HTTP_CODE -eq 200 ] && echo "$RESPONSE_BODY" | grep -q '"id":1' && echo "$RESPONSE_BODY" | grep -q '"username":"testuser"'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Login with correct credentials should succeed"
SESSION_COOKIE=$(grep 'session_id' $COOKIE_FILE | awk '{print $7}' | head -n1)
if [ -z "$SESSION_COOKIE" ]; then
    echo -e "${RED}FAIL${NC}: Session cookie not set after login"
    exit 1
fi

# TEST 7: Login with wrong credentials 
print_header "Test 7: POST /login (wrong credentials)"
RESPONSE=$(curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpass"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 401 ] && echo "$RESPONSE_BODY" | grep -q 'Invalid credentials'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Login with wrong credentials should fail with 401"

# TEST 8: Get user profile (authenticated)
print_header "Test 8: GET /me (authenticated)"
RESPONSE=$(curl -s -X GET "$BASE_URL/me" -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 200 ] && echo "$RESPONSE_BODY" | grep -q '"id":1' && echo "$RESPONSE_BODY" | grep -q '"username":"testuser"'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Get user profile with valid session should succeed"

# TEST 9: Get user profile (unauthenticated)
print_header "Test 9: GET /me (unauthenticated)"
RESPONSE=$(curl -s -X GET "$BASE_URL/me" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 401 ] && echo "$RESPONSE_BODY" | grep -q 'Authentication required'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Get user profile without session should fail with 401"

# TEST 10: Change password (valid)
print_header "Test 10: PUT /password (change password)"
RESPONSE=$(curl -s -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b "session_id=$SESSION_COOKIE" -d '{"old_password": "password123", "new_password": "newpassword456"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 200 ] && echo "$RESPONSE_BODY" | grep -q '{}' ; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Change password with valid credentials should succeed"

# TEST 11: Try to change again with old password (should fail)
print_header "Test 11: Login with new password"
RESPONSE=$(curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword456"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 200 ] && echo "$RESPONSE_BODY" | grep -q '"id":1' && echo "$RESPONSE_BODY" | grep -q '"username":"testuser"'; then
    SESSION_COOKIE_NEW=$(echo "$RESPONSE" | tr '\n' ' ' | sed 's/.*session_id=\([; ]\)/\1/' | cut -c1-36)
    # Extract session_id from response headers more carefully
    NEW_COOKIE_HEADER=$(curl -s -D - -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword456"}' | grep -i 'Set-Cookie' || true)
    if [ -n "$NEW_COOKIE_HEADER" ]; then
        SESSION_COOKIE_NEW=$(echo "$NEW_COOKIE_HEADER" | grep -o 'session_id=[^;]*' | sed 's/session_id=//')
    fi
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Login with new password should work"

# Get a fresh session cookie for subsequent tests
TEMP_COOKIE_FILE=$(mktemp)
curl -s -D - -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword456"}' -c $TEMP_COOKIE_FILE > /dev/null
NEW_SESSION_COOKIE=$(grep 'session_id' $TEMP_COOKIE_FILE | awk '{print $7}')
rm $TEMP_COOKIE_FILE

# TEST 12: Try old password after change (should fail)
print_header "Test 12: Login with old password after change"
RESPONSE=$(curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 401 ] && echo "$RESPONSE_BODY" | grep -q 'Invalid credentials'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Login with old password after change should fail"

# Test 13: Get todos (empty initially)
print_header "Test 13: GET /todos (empty list)"
RESPONSE=$(curl -s -X GET "$BASE_URL/todos" -b "session_id=$NEW_SESSION_COOKIE" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 200 ] && echo "$RESPONSE_BODY" | grep -q '^\[\]$'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Get todos when none exist returns empty array"

# Test 14: Create a todo
print_header "Test 14: POST /todos (create)"
RESPONSE=$(curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b "session_id=$NEW_SESSION_COOKIE" -d '{"title": "First task", "description": "Learn the system"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 201 ] && echo "$RESPONSE_BODY" | grep -q '"title":"First task"' && echo "$RESPONSE_BODY" | grep -q '"completed":false'; then
    TODO_ID=$(echo "$RESPONSE_BODY" | grep -o '"id":[0-9]*' | sed 's/"id"://')
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Create a todo with valid data should succeed with 201"

# Test 15: Create a todo with minimal structure
print_header "Test 15: POST /todos (minimal)"
RESPONSE=$(curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b "session_id=$NEW_SESSION_COOKIE" -d '{"title": "Second task"}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 201 ] && echo "$RESPONSE_BODY" | grep -q '"title":"Second task"' && echo "$RESPONSE_BODY" | grep -q '"description":""'; then
    TODO_ID2=$(echo "$RESPONSE_BODY" | grep -o '"id":[0-9]*' | sed 's/"id"://')
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Create a todo with minimal data (only title) should succeed"

# Test 16: Create todo without title (should fail)
print_header "Test 16: POST /todos (without title)"
RESPONSE=$(curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b "session_id=$NEW_SESSION_COOKIE" -d '{}' -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 400 ] && echo "$RESPONSE_BODY" | grep -q 'Title is required'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Create a todo without title should fail"

# Test 17: Get all todos
print_header "Test 17: GET /todos (with items)"
RESPONSE=$(curl -s -X GET "$BASE_URL/todos" -b "session_id=$NEW_SESSION_COOKIE" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

TODO_COUNT=$(echo "$RESPONSE_BODY" | grep -o '"id":[0-9]' | wc -l)
if [ $HTTP_CODE -eq 200 ] && [ $TODO_COUNT -ge 2 ]; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Get all todos should return existing todos"

# Test 18: Get specific todo
print_header "Test 18: GET /todos/:id"
RESPONSE=$(curl -s -X GET "$BASE_URL/todos/$TODO_ID" -b "session_id=$NEW_SESSION_COOKIE" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 200 ] && echo "$RESPONSE_BODY" | grep -q '"title":"First task"'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Get specific todo by ID should return the todo"

# Test 19: Get non-existent todo
print_header "Test 19: GET /todos/999"
RESPONSE=$(curl -s -X GET "$BASE_URL/todos/999" -b "session_id=$NEW_SESSION_COOKIE" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 404 ] && echo "$RESPONSE_BODY" | grep -q 'Todo not found'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Get non-existent todo should return 404"

# Test 20: Update a todo partially
print_header "Test 20: PUT /todos/:id (partial update)"
UPDATE_PAYLOAD='{"completed": true, "description": "Updated description"}'
RESPONSE=$(curl -s -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b "session_id=$NEW_SESSION_COOKIE" -d "$UPDATE_PAYLOAD" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 200 ] && echo "$RESPONSE_BODY" | grep -q '"completed":true' && echo "$RESPONSE_BODY" | grep -q '"description":"Updated description"'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Partial update of todo should modify those fields only"

# Test 21: Update todo with invalid completed field
print_header "Test 21: PUT /todos/:id (invalid completed type)"
UPDATE_PAYLOAD='{"completed": "yes"}'
RESPONSE=$(curl -s -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b "session_id=$NEW_SESSION_COOKIE" -d "$UPDATE_PAYLOAD" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 400 ] && echo "$RESPONSE_BODY" | grep -q 'Invalid completed status'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Update with invalid completed type should fail"

# Test 22: Delete a todo
print_header "Test 22: DELETE /todos/:id"
RESPONSE=$(curl -s -X DELETE "$BASE_URL/todos/$TODO_ID" -b "session_id=$NEW_SESSION_COOKIE" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

if [ $HTTP_CODE -eq 204 ]; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Delete a todo should succeed with 204 status"

# Test 23: Try get deleted todo (should fail)
print_header "Test 23: GET /todos/:deleted_id"
RESPONSE=$(curl -s -X GET "$BASE_URL/todos/$TODO_ID" -b "session_id=$NEW_SESSION_COOKIE" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 404 ] && echo "$RESPONSE_BODY" | grep -q 'Todo not found'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Getting a deleted todo should return 404"

# Test 24: Logout
print_header "Test 24: POST /logout"
RESPONSE=$(curl -s -X POST "$BASE_URL/logout" -b "session_id=$NEW_SESSION_COOKIE" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 200 ] && echo "$RESPONSE_BODY" | grep -q '{}'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Logout should succeed"

# Test 25: Try to GET /me after logout (should fail)
print_header "Test 25: GET /me (after logout)"
RESPONSE=$(curl -s -X GET "$BASE_URL/me" -b "session_id=$NEW_SESSION_COOKIE" -w "\n%{http_code}")
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n1)

if [ $HTTP_CODE -eq 401 ] && echo "$RESPONSE_BODY" | grep -q 'Authentication required'; then
    TEST_RESULT=0
else
    TEST_RESULT=1
fi
print_test_result $TEST_RESULT "Accessing protected resources after logout should fail"

echo -e "\n${GREEN}All tests passed!${NC}"

rm -f $COOKIE_FILE