#!/bin/bash
set -e

PORT=8888

# Start server in background
./run.sh --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 1

# Helper function to run test
run_test() {
    local name="$1"
    local expected_code="$2"
    local expected_body="$3"
    shift 3
    
    echo "Testing: $name"
    response=$(curl -s -w "\n%{http_code}" "$@")
    body=$(echo "$response" | sed '$d')
    code=$(echo "$response" | tail -n 1)
    
    if [ "$code" != "$expected_code" ]; then
        echo "  FAILED: Expected code $expected_code, got $code"
        echo "  Body: $body"
        kill $SERVER_PID 2>/dev/null || true
        exit 1
    fi
    
    if [ -n "$expected_body" ]; then
        if ! echo "$body" | grep -q "$expected_body"; then
            echo "  FAILED: Expected body to contain '$expected_body'"
            echo "  Body: $body"
            kill $SERVER_PID 2>/dev/null || true
            exit 1
        fi
    fi
    echo "  PASSED"
}

# Test 1: Register user
run_test "Register valid user" "201" '{"id":1,"username":"testuser"}' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:$PORT/register

# Test 2: Register invalid username
run_test "Register invalid username" "400" 'Invalid username' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"ab","password":"password123"}' \
    http://localhost:$PORT/register

# Test 3: Register short password
run_test "Register short password" "400" 'Password too short' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser2","password":"short"}' \
    http://localhost:$PORT/register

# Test 4: Register duplicate username
run_test "Register duplicate username" "409" 'Username already exists' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:$PORT/register

# Test 5: Login valid
COOKIE=$(curl -s -c - -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:$PORT/login | grep -i "set-cookie" | awk '{print $NF}')

run_test "Login valid" "200" '{"id":1,"username":"testuser"}' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:$PORT/login

# Test 6: Login invalid
run_test "Login invalid" "401" 'Invalid credentials' \
    -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"wrongpassword"}' \
    http://localhost:$PORT/login

# Test 7: GET /me without auth
run_test "GET /me without auth" "401" 'Authentication required' \
    http://localhost:$PORT/me

# Test 8: GET /me with auth
run_test "GET /me with auth" "200" '{"id":1,"username":"testuser"}' \
    -H "Cookie: $COOKIE" \
    http://localhost:$PORT/me

# Test 9: PUT /password invalid old
run_test "PUT /password invalid old" "401" 'Invalid credentials' \
    -X PUT -H "Content-Type: application/json" -H "Cookie: $COOKIE" \
    -d '{"old_password":"wrong","new_password":"newpassword123"}' \
    http://localhost:$PORT/password

# Test 10: PUT /password short new
run_test "PUT /password short new" "400" 'Password too short' \
    -X PUT -H "Content-Type: application/json" -H "Cookie: $COOKIE" \
    -d '{"old_password":"password123","new_password":"short"}' \
    http://localhost:$PORT/password

# Test 11: PUT /password valid
run_test "PUT /password valid" "200" '{}' \
    -X PUT -H "Content-Type: application/json" -H "Cookie: $COOKIE" \
    -d '{"old_password":"password123","new_password":"newpassword123"}' \
    http://localhost:$PORT/password

# Test 12: POST /todos missing title
run_test "POST /todos missing title" "400" 'Title is required' \
    -X POST -H "Content-Type: application/json" -H "Cookie: $COOKIE" \
    -d '{"description":"test"}' \
    http://localhost:$PORT/todos

# Test 13: POST /todos valid
run_test "POST /todos valid" "201" '"title":"My Todo"' \
    -X POST -H "Content-Type: application/json" -H "Cookie: $COOKIE" \
    -d '{"title":"My Todo","description":"Test description"}' \
    http://localhost:$PORT/todos

# Test 14: GET /todos
run_test "GET /todos" "200" '"title":"My Todo"' \
    -H "Cookie: $COOKIE" \
    http://localhost:$PORT/todos

# Test 15: GET /todos/1
run_test "GET /todos/1" "200" '"title":"My Todo"' \
    -H "Cookie: $COOKIE" \
    http://localhost:$PORT/todos/1

# Test 16: GET /todos/999 (not found)
run_test "GET /todos/999 not found" "404" 'Todo not found' \
    -H "Cookie: $COOKIE" \
    http://localhost:$PORT/todos/999

# Test 17: PUT /todos/1 partial update
run_test "PUT /todos/1 partial update" "200" '"completed":true' \
    -X PUT -H "Content-Type: application/json" -H "Cookie: $COOKIE" \
    -d '{"completed":true}' \
    http://localhost:$PORT/todos/1

# Test 18: PUT /todos/1 empty title
run_test "PUT /todos/1 empty title" "400" 'Title is required' \
    -X PUT -H "Content-Type: application/json" -H "Cookie: $COOKIE" \
    -d '{"title":""}' \
    http://localhost:$PORT/todos/1

# Test 19: DELETE /todos/1
response=$(curl -s -w "%{http_code}" -X DELETE -H "Cookie: $COOKIE" http://localhost:$PORT/todos/1)
if [ "$response" != "204" ]; then
    echo "FAILED: DELETE /todos/1 expected 204, got $response"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi
echo "Testing: DELETE /todos/1"
echo "  PASSED"

# Test 20: DELETE /todos/1 again (not found)
run_test "DELETE /todos/1 again not found" "404" 'Todo not found' \
    -X DELETE -H "Cookie: $COOKIE" \
    http://localhost:$PORT/todos/1

# Test 21: POST /logout
run_test "POST /logout" "200" '{}' \
    -X POST -H "Cookie: $COOKIE" \
    http://localhost:$PORT/logout

# Test 22: GET /me after logout
run_test "GET /me after logout" "401" 'Authentication required' \
    -H "Cookie: $COOKIE" \
    http://localhost:$PORT/me

echo ""
echo "All tests passed!"
kill $SERVER_PID 2>/dev/null || true
exit 0