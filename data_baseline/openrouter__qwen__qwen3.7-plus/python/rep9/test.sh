#!/bin/bash
set -e

PORT=${1:-8080}
BASE_URL="http://127.0.0.1:$PORT"

echo "Starting server on port $PORT..."
python3 app.py --port "$PORT" &
SERVER_PID=$!
sleep 2

cleanup() {
    echo "Stopping server..."
    kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Running tests..."

check_req() {
    local method=$1
    local path=$2
    local data=$3
    local expected_status=$4
    local cookie=$5
    local expected_body=$6
    
    local args=("-s" "-w" "\n%{http_code}" "-X" "$method" "$BASE_URL$path")
    if [ -n "$data" ]; then
        args+=("-H" "Content-Type: application/json" "-d" "$data")
    fi
    if [ -n "$cookie" ]; then
        args+=("-b" "session_id=$cookie")
    fi
    
    local response
    response=$(curl "${args[@]}")
    
    local http_code="${response##*$'\n'}"
    local body="${response%$'\n'*}"
    
    if [ "$http_code" != "$expected_status" ]; then
        echo "FAIL: $method $path"
        echo "Expected status: $expected_status, got: $http_code"
        echo "Response body: $body"
        exit 1
    fi
    
    if [ -n "$expected_body" ]; then
        if ! echo "$body" | grep -qF "$expected_body"; then
            echo "FAIL: $method $path body check"
            echo "Expected to find: $expected_body"
            echo "Response body: $body"
            exit 1
        fi
    fi
    
    echo "$body"
}

echo "Test: Register"
check_req "POST" "/register" '{"username":"testuser", "password": "password123"}' "201" "" '"id":1'

echo "Test: Register invalid username"
check_req "POST" "/register" '{"username": "ab", "password": "password123"}' "400" "" '"error":"Invalid username"'

echo "Test: Register short password"
check_req "POST" "/register" '{"username": "testuser2", "password": "short"}' "400" "" '"error":"Password too short"'

echo "Test: Register duplicate"
check_req "POST" "/register" '{"username":"testuser", "password": "password123"}' "409" "" '"error":"Username already exists"'

echo "Test: Login"
curl -s -X POST "$BASE_URL/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"testuser", "password": "password123"}' \
    -c cookies.txt -w "%{http_code}" -o /dev/null | grep -q "200" || { echo "Login failed"; exit 1; }
SESSION_ID=$(grep session_id cookies.txt | tail -n 1 | awk '{print $NF}')
echo "Session ID: $SESSION_ID"

echo "Test: Login invalid"
check_req "POST" "/login" '{"username":"testuser", "password": "wrongpassword"}' "401" "" '"error":"Invalid credentials"'

echo "Test: Me"
check_req "GET" "/me" "" "200" "$SESSION_ID" '"username":"testuser"'

echo "Test: Me without auth"
check_req "GET" "/me" "" "401" "" '"error":"Authentication required"'

echo "Test: Change password"
check_req "PUT" "/password" '{"old_password": "password123", "new_password": "newpassword123"}' "200" "$SESSION_ID" '{}'

echo "Test: Change password wrong old"
check_req "PUT" "/password" '{"old_password": "wrong", "new_password": "newpassword123"}' "401" "$SESSION_ID" '"error":"Invalid credentials"'

echo "Test: Change password short new"
check_req "PUT" "/password" '{"old_password": "newpassword123", "new_password": "short"}' "400" "$SESSION_ID" '"error":"Password too short"'

echo "Test: Create todo"
RES=$(check_req "POST" "/todos" '{"title": "My Todo", "description": "Do this"}' "201" "$SESSION_ID" '"completed":false')
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
echo "Todo ID: $TODO_ID"

echo "Test: Create todo missing title"
check_req "POST" "/todos" '{"description": "No title"}' "400" "$SESSION_ID" '"error":"Title is required"'

echo "Test: Get todos"
check_req "GET" "/todos" "" "200" "$SESSION_ID" '"My Todo"'

echo "Test: Get specific todo"
check_req "GET" "/todos/$TODO_ID" "" "200" "$SESSION_ID" '"My Todo"'

echo "Test: Get specific todo not found"
check_req "GET" "/todos/999" "" "404" "$SESSION_ID" '"error":"Todo not found"'

echo "Test: Update todo"
check_req "PUT" "/todos/$TODO_ID" '{"completed":true}' "200" "$SESSION_ID" '"completed":true'

echo "Test: Update todo empty title"
check_req "PUT" "/todos/$TODO_ID" '{"title": ""}' "400" "$SESSION_ID" '"error":"Title is required"'

echo "Test: Delete todo"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b "session_id=$SESSION_ID")
if [ "$HTTP_CODE" != "204" ]; then
    echo "FAIL: DELETE /todos/$TODO_ID expected 204, got $HTTP_CODE"
    exit 1
fi

echo "Test: Delete todo not found"
check_req "DELETE" "/todos/$TODO_ID" "" "404" "$SESSION_ID" '"error":"Todo not found"'

echo "Test: Logout"
check_req "POST" "/logout" "" "200" "$SESSION_ID" '{}'

echo "Test: Me after logout"
check_req "GET" "/me" "" "401" "$SESSION_ID" '"error":"Authentication required"'

echo "All tests passed!"
