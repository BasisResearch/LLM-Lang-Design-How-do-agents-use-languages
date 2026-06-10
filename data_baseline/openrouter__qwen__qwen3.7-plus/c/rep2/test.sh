#!/bin/bash

PORT=8888
BASE_URL="http://localhost:$PORT"

# Function to kill server on exit
cleanup() {
    kill $SERVER_PID 2>/dev/null
    rm -f cookies.txt server.log
}
trap cleanup EXIT

# Start server in background
./run.sh --port $PORT > server.log 2>&1 &
SERVER_PID=$!
sleep 2

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "FAIL: Server failed to start"
    cat server.log
    exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0

check_result() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == *"$expected"* ]]; then
        echo "PASS: $test_name"
        ((PASS_COUNT++))
    else
        echo "FAIL: $test_name"
        echo "  Expected: $expected"
        echo "  Actual: $actual"
        ((FAIL_COUNT++))
    fi
}

echo "=== Testing Register ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_result "Register success 201" "201" "$CODE"
check_result "Register body" '"username":"testuser"' "$BODY"

echo "=== Testing Register Duplicate ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_result "Register duplicate 409" "409" "$CODE"
check_result "Register duplicate body" "Username already exists" "$BODY"

echo "=== Testing Register Invalid Username ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
check_result "Register invalid username 400" "400" "$CODE"

echo "=== Testing Register Short Password ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RESP" | tail -n1)
check_result "Register short password 400" "400" "$CODE"

echo "=== Testing Login ==="
RESP=$(curl -s -c cookies.txt -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_result "Login success 200" "200" "$CODE"
check_result "Login body" '"username":"testuser"' "$BODY"

echo "=== Testing Me ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" "$BASE_URL/me")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_result "Me success 200" "200" "$CODE"
check_result "Me body" '"id":1' "$BODY"

echo "=== Testing Create Todo ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Test desc"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)
check_result "Create Todo 201" "201" "$CODE"
check_result "Create Todo body" '"completed":false' "$BODY"

echo "=== Testing Get Todos ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" "$BASE_URL/todos")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_result "Get Todos 200" "200" "$CODE"
check_result "Get Todos body" '"title":"My Todo"' "$BODY"

echo "=== Testing Get Single Todo ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_result "Get Single Todo 200" "200" "$CODE"
check_result "Get Single Todo body" '"description":"Test desc"' "$BODY"

echo "=== Testing Get Single Todo Not Found ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" "$BASE_URL/todos/9999")
CODE=$(echo "$RESP" | tail -n1)
check_result "Get Single Todo Not Found 404" "404" "$CODE"

echo "=== Testing Update Todo ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"completed": true}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_result "Update Todo 200" "200" "$CODE"
check_result "Update Todo body" '"completed":true' "$BODY"

echo "=== Testing Update Todo Empty Title ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"title": ""}')
CODE=$(echo "$RESP" | tail -n1)
check_result "Update Todo Empty Title 400" "400" "$CODE"

echo "=== Testing Delete Todo ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/$TODO_ID")
check_result "Delete Todo 204" "204" "$CODE"

echo "=== Testing Delete Non-existent Todo ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/9999")
check_result "Delete Non-existent Todo 404" "404" "$CODE"

echo "=== Testing Change Password ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_result "Change Password 200" "200" "$CODE"

echo "=== Testing Change Password Wrong Old ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n1)
check_result "Change Password Wrong Old 401" "401" "$CODE"

echo "=== Testing Change Password Short New ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RESP" | tail -n1)
check_result "Change Password Short New 400" "400" "$CODE"

echo "=== Testing Logout ==="
RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" -X POST "$BASE_URL/logout")
CODE=$(echo "$RESP" | tail -n1)
check_result "Logout 200" "200" "$CODE"

echo "=== Testing Auth Required After Logout ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "$BASE_URL/me")
check_result "Auth Required After Logout 401" "401" "$CODE"

echo "=== Testing Unauthenticated Access ==="
CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/todos")
check_result "Unauthenticated Access 401" "401" "$CODE"

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
if [ $FAIL_COUNT -eq 0 ]; then
    echo "ALL TESTS PASSED!"
    exit 0
else
    echo "SOME TESTS FAILED!"
    exit 1
fi