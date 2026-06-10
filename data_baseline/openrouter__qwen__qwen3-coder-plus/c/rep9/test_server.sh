#!/bin/bash

set -e  # Exit on any error

# Start the server in background
echo "Starting server on port 8080..."
timeout 30s ./server --port 8080 &
SERVER_PID=$!
sleep 1

# Check if server started successfully
if ! ps -p $SERVER_PID > /dev/null; then
    echo "Server failed to start"
    exit 1
fi

# Track test results
TEST_COUNT=0
PASS_COUNT=0

# Function to run a single test
run_test() {
    local test_name="$1"
    local expected_status="$2"
    shift 2
    local curl_args=("$@")
    
    TEST_COUNT=$((TEST_COUNT+1))
    printf "Test %2d: %-60s" "$TEST_COUNT" "$test_name"
    
    # Execute the curl command, suppress output except errors
    local status_code
    status_code=$(curl -s -o /tmp/test_output.txt -w "%{http_code}" "${curl_args[@]}")
    
    if [ "$status_code" = "$expected_status" ]; then
        echo " ✓ PASS"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        echo " ✗ FAIL (expected $expected_status, got $status_code)"
        if [ -s /tmp/test_output.txt ]; then
            echo "  Response: $(cat /tmp/test_output.txt)"
        fi
    fi
}

echo "Running API tests..."

# Test 1: POST /register - register a new user
run_test "Register new user" "201" \
    -X POST http://localhost:8080/register \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}'

# Test 2: POST /register - duplicate username
run_test "Register duplicate username" "409" \
    -X POST http://localhost:8080/register \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}'

# Test 3: POST /register - invalid username (too short)
run_test "Register with too short username" "400" \
    -X POST http://localhost:8080/register \
    -H "Content-Type: application/json" \
    -d '{"username": "ab", "password": "password123"}'

# Test 4: POST /register - invalid username (invalid chars)
run_test "Register with invalid username" "400" \
    -X POST http://localhost:8080/register \
    -H "Content-Type: application/json" \
    -d '{"username": "test@user", "password": "password123"}'

# Test 5: POST /register - weak password
run_test "Register with weak password" "400" \
    -X POST http://localhost:8080/register \
    -H "Content-Type: application/json" \
    -d '{"username": "validuser", "password": "weak"}'

# Test 6: POST /login - successful login (capture cookie)
echo -n "Test  6: Login success and capture cookie                       "
TEST_COUNT=$((TEST_COUNT+1))

# Save the response to check for Set-Cookie header
status_code=$(curl -s -D /tmp/headers.txt -o /tmp/test_output.txt -w "%{http_code}" \
    -X POST http://localhost:8080/login \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}')

# Extract session cookie
SESSION_ID=$(grep -i "set-cookie" /tmp/headers.txt | sed 's/.*session_id=\([^(;]*\).*/\1/' | head -n1)

if [ "$status_code" = "200" ] && [ -n "$SESSION_ID" ]; then
    echo " ✓ PASS"
    PASS_COUNT=$((PASS_COUNT+1))
else
    echo " ✗ FAIL (expected 200 and cookie, got $status_code)"
    echo "  Cookie ID: '$SESSION_ID'"
    cat /tmp/test_output.txt
fi

# Test 7: POST /login - invalid credentials
run_test "Login with invalid credentials" "401" \
    -X POST http://localhost:8080/login \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "wrongpassword"}'

# Test 8: GET /me - without authentication
run_test "Get profile without auth" "401" \
    -X GET http://localhost:8080/me
    
# Test 9: GET /me - with authentication
run_test "Get profile with auth" "200" \
    -X GET http://localhost:8080/me \
    -H "Cookie: session_id=$SESSION_ID"

# Test 10: POST /todos - without authentication (should fail)
run_test "Create todo without auth" "401" \
    -X POST http://localhost:8080/todos \
    -H "Content-Type: application/json" \
    -d '{"title": "Test todo", "description": "Test description"}'

# Test 11: POST /todos - with authentication (valid)
run_test "Create todo with auth" "201" \
    -X POST http://localhost:8080/todos \
    -H "Content-Type: application/json" \
    -H "Cookie: session_id=$SESSION_ID" \
    -d '{"title": "My First Todo", "description": "This is my first todo item"}'

# Test 12: GET /todos - see all user todos
run_test "Get all todos for user" "200" \
    -X GET http://localhost:8080/todos \
    -H "Cookie: session_id=$SESSION_ID"

# Test 13: POST /todos - create a second todo
run_test "Create second todo" "201" \
    -X POST http://localhost:8080/todos \
    -H "Content-Type: application/json" \
    -H "Cookie: session_id=$SESSION_ID" \
    -d '{"title": "Second Todo", "description": ""}'

# Test 14: GET /todos - see both user todos
echo -n "Test 14: Verify multiple todos exist                          "
TEST_COUNT=$((TEST_COUNT+1))
status_code=$(curl -s -o /tmp/todos_list.txt -w "%{http_code}" \
    -H "Cookie: session_id=$SESSION_ID" \
    http://localhost:8080/todos)

todos_count=$(grep -o '{' /tmp/todos_list.txt | wc -l)

if [ "$status_code" = "200" ] && [ "$todos_count" -ge 2 ]; then
    echo " ✓ PASS"
    PASS_COUNT=$((PASS_COUNT+1))
else
    echo " ✗ FAIL (expected 200 and at least 2 todos, got $status_code with $todos_count todos)"
    cat /tmp/todos_list.txt
fi

# Test 15: GET /todos/1 - get specific todo
run_test "Get specific todo 1" "200" \
    -X GET http://localhost:8080/todos/1 \
    -H "Cookie: session_id=$SESSION_ID"

# Test 16: PUT /password - change user password
run_test "Change user password" "200" \
    -X PUT http://localhost:8080/password \
    -H "Content-Type: application/json" \
    -H "Cookie: session_id=$SESSION_ID" \
    -d '{"old_password": "password123", "new_password": "newpassword123"}'

# Test 17: PUT /todos/1 - partially update todo
run_test "Update specific todo" "200" \
    -X PUT http://localhost:8080/todos/1 \
    -H "Content-Type: application/json" \
    -H "Cookie: session_id=$SESSION_ID" \
    -d '{"title": "Updated Todo Title", "completed": true}'

# Test 18: POST /logout - log out
run_test "Logout" "200" \
    -X POST http://localhost:8080/logout \
    -H "Cookie: session_id=$SESSION_ID"

# Start a new session for remaining tests
echo -n "Test 19: Login again to test remaining functionality            "
TEST_COUNT=$((TEST_COUNT+1))
status_code=$(curl -s -D /tmp/headers_after_logout.txt -o /tmp/relogin_output.txt -w "%{http_code}" \
    -X POST http://localhost:8080/login \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}')
NEW_PASSWORD_STATUS_CODE=$status_code

# Try with new password
status_code=$(curl -s -D /tmp/headers_new_pass.txt -o /tmp/new_pass_output.txt -w "%{http_code}" \
    -X POST http://localhost:8080/login \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "newpassword123"}')

if [ "$NEW_PASSWORD_STATUS_CODE" = "401" ] && [ "$status_code" = "200" ]; then
    SESSION_NEW=$(grep -i "set-cookie" /tmp/headers_new_pass.txt | sed 's/.*session_id=\([^(;]*\).*/\1/' | head -n1)
    if [ -n "$SESSION_NEW" ]; then
        echo " ✓ PASS"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        echo " ✗ FAIL (new password didn't work)"
    fi
else
    echo " ✗ FAIL (invalid credential handling for changed password)"
fi

# Test 20: GET /todos/1 with new session - authentication required
run_test "Access todo with new session" "200" \
    -X GET http://localhost:8080/todos/1 \
    -H "Cookie: session_id=$SESSION_NEW"

# Test 21: DELETE /todos/1 - delete todo
run_test "Delete specific todo" "204" \
    -X DELETE http://localhost:8080/todos/1 \
    -H "Cookie: session_id=$SESSION_NEW"

# Test 22: GET /todos/1 - should not exist after deletion
run_test "Verify deleted todo doesn't exist" "404" \
    -X GET http://localhost:8080/todos/1 \
    -H "Cookie: session_id=$SESSION_NEW"

# Test 23: PUT /password with wrong old password
run_test "Try changing password with wrong old password" "401" \
    -X PUT http://localhost:8080/password \
    -H "Content-Type: application/json" \
    -H "Cookie: session_id=$SESSION_NEW" \
    -d '{"old_password": "wrongpassword", "new_password": "anotherpassword"}'

# Test 24: Try to access todo from another user (simulating two users scenario)
run_test "Register another user" "201" \
    -X POST http://localhost:8080/register \
    -H "Content-Type: application/json" \
    -d '{"username": "seconduser", "password": "password123"}'

SECOND_USER_LOGIN_STATUS=$(curl -s -D /tmp/second_user_headers.txt -o /tmp/second_login_output.txt -w "%{http_code}" \
    -X POST http://localhost:8080/login \
    -H "Content-Type: application/json" \
    -d '{"username": "seconduser", "password": "password123"}')

SECOND_SESSION_ID=$(grep -i "set-cookie" /tmp/second_user_headers.txt | sed 's/.*session_id=\([^(;]*\).*/\1/' | head -n1)

# Create a todo with second user
SECOND_TODO_CREATE_STATUS=$(curl -s -o /tmp/second_todo_resp.txt -w "%{http_code}" \
    -X POST http://localhost:8080/todos \
    -H "Content-Type: application/json" \
    -H "Cookie: session_id=$SECOND_SESSION_ID" \
    -d '{"title": "Second user todo", "description": "Owned by second user"}')

# Second user should not have access to first user's todo (now deleted anyway)    
echo -n "Test 25: Other user can't access another user's todo           "
TEST_COUNT=$((TEST_COUNT+1))

status_code=$(curl -s -o /tmp/no_access_resp.txt -w "%{http_code}" \
    -H "Cookie: session_id=$SECOND_SESSION_ID" \
    http://localhost:8080/todos/2)  # Todo 1 should already be deleted, try todo 2

if [ "$status_code" = "404" ]; then
    echo " ✓ PASS"
    PASS_COUNT=$((PASS_COUNT+1))
else
    echo " ✗ FAIL (expected 404, got $status_code)"
    cat /tmp/no_access_resp.txt
fi

# Stop the server
kill $SERVER_PID 2>/dev/null || true

echo ""
echo "=================================="
echo "Test Summary: $PASS_COUNT/$TEST_COUNT tests passed"
echo "=================================="

if [ $PASS_COUNT -eq $TEST_COUNT ]; then
    echo "🎉 All tests passed!"
    exit 0
else
    echo "❌ $((TEST_COUNT - PASS_COUNT)) test(s) failed"
    exit 1
fi