#!/bin/bash
set -e

PORT=8888
BASE_URL="http://localhost:$PORT"

echo "Starting server..."
./run.sh --port $PORT > server.log 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt
    cat server.log || true
    rm -f server.log
}
trap cleanup EXIT

# Helper to get response and status code
get_response() {
    curl -s -w "\n%{http_code}" "$@"
}

check_status() {
    local response="$1"
    local expected_status="$2"
    local expected_body="$3"
    local status=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$status" != "$expected_status" ]; then
        echo "FAIL: Expected status $expected_status, got $status"
        echo "Body: $body"
        exit 1
    fi
    if [ -n "$expected_body" ]; then
        if ! echo "$body" | grep -q "$expected_body"; then
            echo "FAIL: Expected body to contain '$expected_body'"
            echo "Body: $body"
            exit 1
        fi
    fi
    echo "PASS: $expected_status $expected_body"
}

echo "=== Testing Register ==="
RES=$(get_response -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
check_status "$RES" "201" '"id":'

echo "=== Testing Register Invalid Username (too short) ==="
RES=$(get_response -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
check_status "$RES" "400" '"error":"Invalid username"'

echo "=== Testing Register Invalid Username (bad chars) ==="
RES=$(get_response -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"test@user","password":"password123"}')
check_status "$RES" "400" '"error":"Invalid username"'

echo "=== Testing Register Duplicate ==="
RES=$(get_response -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
check_status "$RES" "409" '"error":"Username already exists"'

echo "=== Testing Login ==="
RES=$(get_response -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
check_status "$RES" "200" '"id":'

echo "=== Testing Me ==="
RES=$(get_response -X GET "$BASE_URL/me" -b cookies.txt)
check_status "$RES" "200" '"username":"testuser"'

echo "=== Testing Create Todo ==="
RES=$(get_response -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title":"My Todo","description":"Do this"}')
check_status "$RES" "201" '"title":"My Todo"'

echo "=== Testing Create Todo Without Title ==="
RES=$(get_response -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description":"No title"}')
check_status "$RES" "400" '"error":"Title is required"'

echo "=== Testing Get Todos ==="
RES=$(get_response -X GET "$BASE_URL/todos" -b cookies.txt)
check_status "$RES" "200" '"My Todo"'

TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
echo "Extracted Todo ID: $TODO_ID"

echo "=== Testing Get Single Todo ==="
RES=$(get_response -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
check_status "$RES" "200" '"description":"Do this"'

echo "=== Testing Get Another User's Todo (should be 404) ==="
# Create another user and try to access the first user's todo
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"otheruser","password":"password123"}' -c cookies2.txt > /dev/null
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"otheruser","password":"password123"}' -c cookies2.txt > /dev/null
RES=$(get_response -X GET "$BASE_URL/todos/$TODO_ID" -b cookies2.txt)
check_status "$RES" "404" '"error":"Todo not found"'
rm -f cookies2.txt

echo "=== Testing Update Todo ==="
RES=$(get_response -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed":true}')
check_status "$RES" "200" '"completed":true'

echo "=== Testing Update Todo with Empty Title ==="
RES=$(get_response -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title":""}')
check_status "$RES" "400" '"error":"Title is required"'

echo "=== Testing Delete Todo ==="
RES=$(get_response -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
check_status "$RES" "204" ""

echo "=== Testing Get Deleted Todo ==="
RES=$(get_response -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
check_status "$RES" "404" '"error":"Todo not found"'

echo "=== Testing Logout ==="
RES=$(get_response -X POST "$BASE_URL/logout" -b cookies.txt)
check_status "$RES" "200" "{}"

echo "=== Testing Me After Logout ==="
RES=$(get_response -X GET "$BASE_URL/me" -b cookies.txt)
check_status "$RES" "401" '"error":"Authentication required"'

echo "=== Testing Change Password ==="
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt > /dev/null
RES=$(get_response -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
check_status "$RES" "200" "{}"

echo "=== Testing Login with New Password ==="
RES=$(get_response -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' -c cookies.txt)
check_status "$RES" "200" '"username":"testuser"'

echo "=== Testing Login with Old Password (should fail) ==="
RES=$(get_response -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
check_status "$RES" "401" '"error":"Invalid credentials"'

echo "=== Testing Password Too Short ==="
RES=$(get_response -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"newpassword123","new_password":"short"}')
check_status "$RES" "400" '"error":"Password too short"'

echo ""
echo "=== All tests passed successfully! ==="