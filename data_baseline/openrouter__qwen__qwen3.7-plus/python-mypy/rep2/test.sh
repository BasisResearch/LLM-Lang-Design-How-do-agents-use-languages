#!/bin/bash

# Function to run a curl command and check the response
run_test() {
    local test_name=$1
    local expected_status=$2
    local expected_body=$3
    shift 3
    local cmd=("$@")
    
    echo -n "Testing $test_name... "
    # Run curl and capture stdout (body) and stderr (headers, etc)
    # But we need to extract status code and body.
    # We can use -w to get status code.
    response=$(curl -s -w "%{http_code}" "${cmd[@]}")
    body="${response:0:-3}"
    status="${response: -3}"
    
    if [ "$status" != "$expected_status" ]; then
        echo "FAILED (Expected status $expected_status, got $status)"
        echo "Body: $body"
        exit 1
    fi
    
    if [ -n "$expected_body" ]; then
        # Use jq to compare if expected_body is provided, otherwise just check status
        if ! echo "$body" | jq -e . >/dev/null 2>&1; then
            echo "FAILED (Invalid JSON)"
            echo "Body: $body"
            exit 1
        fi
        # A simple string match or jq match for expected parts
        # We'll just echo success if status matches and body is valid JSON (or empty for 204)
    fi
    
    echo "PASSED"
}

PORT=8765
HOST="http://127.0.0.1:$PORT"

# Start server in background
./run.sh --port "$PORT" &
SERVER_PID=$!
sleep 3

# Helper to make requests and check
test_register_valid() {
    echo -n "Test: Register valid user... "
    res=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "securepass123"}')
    status=$(echo "$res" | tail -n1)
    body=$(echo "$res" | sed '$d')
    if [ "$status" != "201" ]; then
        echo "FAILED (status $status)"
        echo "$body"
        exit 1
    fi
    echo "PASSED"
}

test_register_invalid_username() {
    echo -n "Test: Register invalid username... "
    res=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "securepass123"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "400" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "$res" | head -n-1 | grep -q '"error":"Invalid username"'
    if [ $? -ne 0 ]; then
        echo "FAILED (error message mismatch)"
        exit 1
    fi
    echo "PASSED"
}

test_register_short_password() {
    echo -n "Test: Register short password... "
    res=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "400" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "$res" | head -n-1 | grep -q '"error":"Password too short"'
    if [ $? -ne 0 ]; then
        echo "FAILED (error message mismatch)"
        exit 1
    fi
    echo "PASSED"
}

test_register_duplicate() {
    echo -n "Test: Register duplicate username... "
    res=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "securepass123"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "409" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "$res" | head -n-1 | grep -q '"error":"Username already exists"'
    if [ $? -ne 0 ]; then
        echo "FAILED (error message mismatch)"
        exit 1
    fi
    echo "PASSED"
}

test_login_success() {
    echo -n "Test: Login success... "
    res=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "securepass123"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "200" ]; then
        echo "FAILED (status $status)"
        echo "$res"
        exit 1
    fi
    echo "PASSED"
}

test_login_invalid() {
    echo -n "Test: Login invalid credentials... "
    res=$(curl -s -w "\n%{http_code}" -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpass"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "401" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "$res" | head -n-1 | grep -q '"error":"Invalid credentials"'
    if [ $? -ne 0 ]; then
        echo "FAILED (error message mismatch)"
        exit 1
    fi
    echo "PASSED"
}

test_me_success() {
    echo -n "Test: GET /me success... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$HOST/me")
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "200" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "PASSED"
}

test_me_unauthorized() {
    echo -n "Test: GET /me unauthorized... "
    res=$(curl -s -w "\n%{http_code}" -X GET "$HOST/me")
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "401" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "$res" | head -n-1 | grep -q '"error":"Authentication required"'
    if [ $? -ne 0 ]; then
        echo "FAILED (error message mismatch)"
        exit 1
    fi
    echo "PASSED"
}

test_change_password() {
    echo -n "Test: PUT /password success... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$HOST/password" -H "Content-Type: application/json" -d '{"old_password": "securepass123", "new_password": "newpassword123"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "200" ]; then
        echo "FAILED (status $status)"
        echo "$res"
        exit 1
    fi
    echo "PASSED"
}

test_change_password_invalid_old() {
    echo -n "Test: PUT /password invalid old password... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$HOST/password" -H "Content-Type: application/json" -d '{"old_password": "wrongpass", "new_password": "newpassword123"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "401" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "PASSED"
}

test_create_todo() {
    echo -n "Test: POST /todos success... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$HOST/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Do something"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "201" ]; then
        echo "FAILED (status $status)"
        echo "$res"
        exit 1
    fi
    echo "$res" | head -n-1 | grep -q '"title":"My Todo"'
    if [ $? -ne 0 ]; then
        echo "FAILED (title mismatch)"
        exit 1
    fi
    echo "$res" | head -n-1 | grep -q '"completed":false'
    if [ $? -ne 0 ]; then
        echo "FAILED (completed mismatch)"
        exit 1
    fi
    echo "PASSED"
}

test_create_todo_no_title() {
    echo -n "Test: POST /todos no title... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$HOST/todos" -H "Content-Type: application/json" -d '{"description": "Do something"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "400" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "PASSED"
}

test_get_todos() {
    echo -n "Test: GET /todos success... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$HOST/todos")
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "200" ]; then
        echo "FAILED (status $status)"
        echo "$res"
        exit 1
    fi
    echo "PASSED"
}

test_get_todo() {
    echo -n "Test: GET /todos/1 success... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$HOST/todos/1")
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "200" ]; then
        echo "FAILED (status $status)"
        echo "$res"
        exit 1
    fi
    echo "PASSED"
}

test_get_todo_not_found() {
    echo -n "Test: GET /todos/999 not found... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$HOST/todos/999")
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "404" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "PASSED"
}

test_update_todo() {
    echo -n "Test: PUT /todos/1 success... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$HOST/todos/1" -H "Content-Type: application/json" -d '{"title": "Updated Title", "completed": true}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "200" ]; then
        echo "FAILED (status $status)"
        echo "$res"
        exit 1
    fi
    echo "$res" | head -n-1 | grep -q '"title":"Updated Title"'
    if [ $? -ne 0 ]; then
        echo "FAILED (title mismatch)"
        exit 1
    fi
    echo "$res" | head -n-1 | grep -q '"completed":true'
    if [ $? -ne 0 ]; then
        echo "FAILED (completed mismatch)"
        exit 1
    fi
    echo "PASSED"
}

test_update_todo_empty_title() {
    echo -n "Test: PUT /todos/1 empty title... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$HOST/todos/1" -H "Content-Type: application/json" -d '{"title": ""}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "400" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "PASSED"
}

test_delete_todo() {
    echo -n "Test: DELETE /todos/1 success... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$HOST/todos/1")
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "204" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "PASSED"
}

test_logout() {
    echo -n "Test: POST /logout success... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$HOST/logout")
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "200" ]; then
        echo "FAILED (status $status)"
        echo "$res"
        exit 1
    fi
    echo "PASSED"
}

test_todo_after_logout() {
    echo -n "Test: GET /todos after logout (should be 401)... "
    res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$HOST/todos")
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "401" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "PASSED"
}

test_cross_user_todo_not_found() {
    echo -n "Test: Register second user... "
    curl -s -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser3", "password": "securepass123"}' > /dev/null
    res=$(curl -s -w "\n%{http_code}" -c cookies2.txt -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser3", "password": "securepass123"}')
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "200" ]; then
        echo "FAILED (status $status)"
        exit 1
    fi
    echo "PASSED"
    
    echo -n "Test: User 2 cannot see User 1's todo (404)... "
    res=$(curl -s -w "\n%{http_code}" -b cookies2.txt -X GET "$HOST/todos/1")
    status=$(echo "$res" | tail -n1)
    if [ "$status" != "404" ]; then
        echo "FAILED (status $status, expected 404 to prevent enumeration)"
        exit 1
    fi
    echo "PASSED"
}

# Run all tests
test_register_valid
test_register_invalid_username
test_register_short_password
test_register_duplicate
test_login_success
test_login_invalid
test_me_success
test_me_unauthorized
test_change_password
test_change_password_invalid_old
test_create_todo
test_create_todo_no_title
test_get_todos
test_get_todo
test_get_todo_not_found
test_update_todo
test_update_todo_empty_title
test_delete_todo
test_logout
test_todo_after_logout
test_cross_user_todo_not_found

# Cleanup
kill $SERVER_PID
rm -f cookies.txt cookies2.txt

echo "All tests passed!"
