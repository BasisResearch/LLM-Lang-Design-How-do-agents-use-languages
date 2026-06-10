#!/bin/bash

# Test script for the Todo App API
echo "Starting Todo App API tests..."

# Start the server in the background
./run.sh --port 3001 &
SERVER_PID=$!
sleep 2

# Function to check if server is still running
check_server() {
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "ERROR: Server stopped unexpectedly during tests"
        exit 1
    fi
}

# Track test results
TESTS_PASSED=0
TESTS_TOTAL=0

# Function to run a test
run_test() {
    local test_name="$1"
    shift
    local cmd="$@"
    
    echo -n "Testing: $test_name... "
    
    # Execute the test command
    result=$($cmd 2>/dev/null)
    status=$?
    
    if [ $status -eq 0 ]; then
        echo "PASS"
        ((TESTS_PASSED++))
    else
        echo "FAIL ($result)"
    fi
    ((TESTS_TOTAL++))
}

# Test registration with valid input
run_test "POST /register with valid data" "curl -s -w '%{http_code}' -X POST http://localhost:3001/register -H 'Content-Type: application/json' -d '{\"username\":\"testuser\",\"password\":\"password123\"}' | grep -q \"201\""

# Test registration with invalid username (too short)
run_test "POST /register with invalid username (too short)" "curl -s -X POST http://localhost:3001/register -H 'Content-Type: application/json' -d '{\"username\":\"ab\",\"password\":\"password123\"}' | grep -q '\"error\":\"Invalid username\"'"

# Test registration with invalid username (invalid characters)
run_test "POST /register with invalid username (special chars)" "curl -s -X POST http://localhost:3001/register -H 'Content-Type: application/json' -d '{\"username\":\"test@user\",\"password\":\"password123\"}' | grep -q '\"error\":\"Invalid username\"'"

# Test registration with short password
run_test "POST /register with short password" "curl -s -X POST http://localhost:3001/register -H 'Content-Type: application/json' -d '{\"username\":\"testuser2\",\"password\":\"short\"}' | grep -q '\"error\":\"Password too short\"'"

# Test duplicate username registration
run_test "POST /register with existing username" "curl -s -X POST http://localhost:3001/register -H 'Content-Type: application/json' -d '{\"username\":\"testuser\", \"password\":\"password123\"}' | grep -q '\"error\":\"Username already exists\"'"

# Test login with valid credentials
run_test "POST /login with valid credentials" "curl -s -c cookies.txt -w '%{http_code}' -X POST http://localhost:3001/login -H 'Content-Type: application/json' -d '{\"username\":\"testuser\",\"password\":\"password123\"}' | grep -q \"200\""

# Test login with invalid credentials (wrong password)
run_test "POST /login with wrong password" "curl -s -w '%{http_code}' -X POST http://localhost:3001/login -H 'Content-Type: application/json' -d '{\"username\":\"testuser\",\"password\":\"wrongpass\"}' | grep -q \"401\""

# Test login with invalid username
run_test "POST /login with invalid username" "curl -s -w '%{http_code}' -X POST http://localhost:3001/login -H 'Content-Type: application/json' -d '{\"username\":\"nonexistent\",\"password\":\"password123\"}' | grep -q \"401\""

# Test unauthorized access to protected endpoints using a temporary cookie variable
run_test "GET /me without authentication" "curl -s -w '%{http_code}' http://localhost:3001/me | grep -q \"401\""

# Test POST /logout without auth (should fail)
run_test "POST /logout without authentication" "curl -s -w '%{http_code}' -X POST http://localhost:3001/logout | grep -q \"401\""

# Get user info using authenticated session
run_test "GET /me with authentication" "curl -sb cookies.txt -w '%{http_code}' http://localhost:3001/me | grep -q \"200\""

# Add a user for testing unauthorized access cases
curl -s -X POST http://localhost:3001/register -H 'Content-Type: application/json' -d '{"username":"testuser2","password":"password123"}' >/dev/null
curl -s -c cookies2.txt -X POST http://localhost:3001/login -H 'Content-Type: application/json' -d '{"username":"testuser2","password":"password123"}' >/dev/null

# Test unauthorized access to someone else's todo by first creating one with user1 then accessing with user2
TODO_ID=$(curl -sb cookies.txt -X POST http://localhost:3001/todos -H 'Content-Type: application/json' -d '{"title":"Test Todo","description":"A test todo item"}' | grep -o '"id":[0-9]*' | cut -d: -f2)
sleep 1  # Give it a moment 

if [ -n "$TODO_ID" ]; then
    # Get the todo with same session (will be used later)
    run_test "Unauthorized access to other's todo" "curl -sb cookies2.txt -w '%{http_code}' http://localhost:3001/todos/$TODO_ID | grep -q \"404\""
else
    echo "Could not extract todo ID to test unauthorized access"
fi

# Test PUT /password with incorrect old password
run_test "PUT /password with wrong old password" "curl -sb cookies.txt -w '%{http_code}' -X PUT http://localhost:3001/password -H 'Content-Type: application/json' -d '{\"old_password\":\"wrongpassword\",\"new_password\":\"newpassword123\"}' | grep -q \"401\""

# Test PUT /password with short new password
run_test "PUT /password with short new password" "curl -sb cookies.txt -w '%{http_code}' -X PUT http://localhost:3001/password -H 'Content-Type: application/json' -d '{\"old_password\":\"password123\",\"new_password\":\"short\"}' | grep -q \"400\""

# Test POST /todos validation (missing title)
run_test "POST /todos with missing title" "curl -sb cookies.txt -w '%{http_code}' -X POST http://localhost:3001/todos -H 'Content-Type: application/json' -d '{\"description\":\"No title\"}' | grep -q \"400\""

# Test basic todo operations with authentication
run_test "POST /todos with valid data" "curl -sb cookies.txt -w '%{http_code}' -X POST http://localhost:3001/todos -H 'Content-Type: application/json' -d '{\"title\":\"Test Todo\",\"description\":\"A test todo item\"}' | grep -q \"201\""

# Try to retrieve a todo that doesn't exist
run_test "GET /todos/:id non-existent todo" "curl -sb cookies.txt -w '%{http_code}' http://localhost:3001/todos/99999 | grep -q \"404\""

# Get existing todo with authentication
EXISTING_TODO_ID=$(curl -sb cookies.txt -X POST http://localhost:3001/todos -H 'Content-Type: application/json' -d '{"title":"Todo for get test","description":"Description for get test"}' | grep -o '"id":[0-9]*' | cut -d: -f2)
if [ -n "$EXISTING_TODO_ID" ]; then
    run_test "GET /todos/:id with authenticated session" "curl -sb cookies.txt -w '%{http_code}' http://localhost:3001/todos/$EXISTING_TODO_ID | grep -q \"$EXISTING_TODO_ID\""
else
    echo "Could not create or extract todo for GET test"
fi

# Test PUT /todos updates
if [ -n "$EXISTING_TODO_ID" ]; then
    run_test "PUT /todos/:id with updated data" "curl -sb cookies.txt -w '%{http_code}' -X PUT http://localhost:3001/todos/$EXISTING_TODO_ID -H 'Content-Type: application/json' -d '{\"title\":\"Updated Title\",\"completed\":true}' | grep -q \"200\""
fi

# Test title validation in PUT request
if [ -n "$EXISTING_TODO_ID" ]; then
    run_test "PUT /todos/:id with empty title" "curl -sb cookies.txt -w '%{http_code}' -X PUT http://localhost:3001/todos/$EXISTING_TODO_ID -H 'Content-Type: application/json' -d '{\"title\":\"\"}' | grep -q \"400\""
fi

# Test DELETE /todos/:id with wrong user (after we've established separate sessions)
NEW_TODO_ID=$(curl -sb cookies.txt -X POST http://localhost:3001/todos -H 'Content-Type: application/json' -d '{"title":"Delete test","description":"Will be tested for deletion"}' | grep -o '"id":[0-9]*' | cut -d: -f2)
if [ -n "$NEW_TODO_ID" ]; then
    run_test "DELETE /todos/:id unauthorized access" "curl -sb cookies2.txt -w '%{http_code}' -X DELETE http://localhost:3001/todos/$NEW_TODO_ID | grep -q \"404\""
else
    echo "Could not create todo for delete test"
fi

# Test PUT /password success
run_test "PUT /password successful change" "curl -sb cookies.txt -w '%{http_code}' -X PUT http://localhost:3001/password -H 'Content-Type: application/json' -d '{\"old_password\":\"password123\",\"new_password\":\"newpassword123\"}' | grep -q \"200\""

# Verify that old password no longer works after changing it
run_test "Confirm old password was changed" "curl -s -w '%{http_code}' -X POST http://localhost:3001/login -H 'Content-Type: application/json' -d '{\"username\":\"testuser\",\"password\":\"password123\"}' | grep -q \"401\""

# Login again with new password to confirm it works
curl -s -c cookies_new.txt -X POST http://localhost:3001/login -H 'Content-Type: application/json' -d '{"username":"testuser","password":"newpassword123"}' >/dev/null
run_test "Login with new password" "curl -sb cookies_new.txt -w '%{http_code}' http://localhost:3001/me | grep -q \"200\""

# Test logout functionality
run_test "POST /logout" "curl -sb cookies_new.txt -w '%{http_code}' -X POST http://localhost:3001/logout | grep -q \"200\""

# Confirm that after logout, session is invalid
run_test "Access after logout" "curl -sb cookies_new.txt -w '%{http_code}' http://localhost:3001/me | grep -q \"401\""

# Clean up background process
kill $SERVER_PID 2>/dev/null

# Print test results
echo "------------------------"
echo "Tests passed: $TESTS_PASSED/$TESTS_TOTAL"

if [ $TESTS_PASSED -eq $TESTS_TOTAL ]; then
    echo "ALL TESTS PASSED!"
    exit 0
else
    echo "SOME TESTS FAILED!"
    exit 1
fi