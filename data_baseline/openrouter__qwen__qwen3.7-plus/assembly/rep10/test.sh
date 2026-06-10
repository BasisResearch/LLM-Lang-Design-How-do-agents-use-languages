#!/bin/bash

PORT=8888
URL="http://127.0.0.1:$PORT"

echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 1

# Helper function to run test
run_test() {
    local name=$1
    local expected_status=$2
    local actual_status=$3
    if [ "$expected_status" == "$actual_status" ]; then
        echo "✅ PASS: $name"
    else
        echo "❌ FAIL: $name (Expected $expected_status, got $actual_status)"
        cat /tmp/resp_body.txt
        echo ""
    fi
}

check_body_contains() {
    local name=$1
    local expected=$2
    local actual=$3
    if echo "$actual" | grep -q "$expected"; then
        echo "✅ PASS: $name"
    else
        echo "❌ FAIL: $name (Expected to contain '$expected', got: $actual)"
    fi
}

echo "Running tests..."

# 1. POST /register - success
RESP=$(curl -s -w "\n%{http_code}" -X POST "$URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "POST /register success" 201 "$STATUS"
check_body_contains "POST /register has id" '"id":1' "$BODY"
check_body_contains "POST /register has username" '"username":"testuser"' "$BODY"

# 2. POST /register - invalid username
RESP=$(curl -s -w "\n%{http_code}" -X POST "$URL/register" -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "POST /register invalid username (too short)" 400 "$STATUS"
check_body_contains "POST /register invalid username error" 'Invalid username' "$BODY"

# 3. POST /register - username exists
RESP=$(curl -s -w "\n%{http_code}" -X POST "$URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "POST /register username exists" 409 "$STATUS"

# 4. POST /register - password too short
RESP=$(curl -s -w "\n%{http_code}" -X POST "$URL/register" -H "Content-Type: application/json" -d '{"username":"testuser2","password":"short"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "POST /register password too short" 400 "$STATUS"

# 5. POST /login - success
RESP=$(curl -s -w "\n%{http_code}" -X POST "$URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c /tmp/cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "POST /login success" 200 "$STATUS"
check_body_contains "POST /login has id" '"id":1' "$BODY"

# 6. GET /me - success
RESP=$(curl -s -w "\n%{http_code}" -X GET "$URL/me" -b /tmp/cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "GET /me success" 200 "$STATUS"

# 7. GET /me - no auth
RESP=$(curl -s -w "\n%{http_code}" -X GET "$URL/me")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "GET /me no auth" 401 "$STATUS"

# 8. POST /todos - success
RESP=$(curl -s -w "\n%{http_code}" -X POST "$URL/todos" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"title":"My Todo","description":"Test desc"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "POST /todos success" 201 "$STATUS"
check_body_contains "POST /todos has title" '"title":"My Todo"' "$BODY"
check_body_contains "POST /todos has created_at" '"created_at"' "$BODY"

# 9. POST /todos - missing title
RESP=$(curl -s -w "\n%{http_code}" -X POST "$URL/todos" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"description":"Test"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "POST /todos missing title" 400 "$STATUS"

# 10. GET /todos - success
RESP=$(curl -s -w "\n%{http_code}" -X GET "$URL/todos" -b /tmp/cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "GET /todos success" 200 "$STATUS"
check_body_contains "GET /todos is array" '\[' "$BODY"

# 11. GET /todos/:id - success
RESP=$(curl -s -w "\n%{http_code}" -X GET "$URL/todos/1" -b /tmp/cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "GET /todos/:id success" 200 "$STATUS"

# 12. GET /todos/:id - not found
RESP=$(curl -s -w "\n%{http_code}" -X GET "$URL/todos/999" -b /tmp/cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "GET /todos/:id not found" 404 "$STATUS"

# 13. PUT /todos/:id - success
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$URL/todos/1" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"completed":true}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "PUT /todos/:id success" 200 "$STATUS"
check_body_contains "PUT /todos/:id has completed true" '"completed":true' "$BODY"

# 14. PUT /todos/:id - empty title
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$URL/todos/1" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"title":""}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "PUT /todos/:id empty title" 400 "$STATUS"

# 15. PUT /password - success
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$URL/password" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "PUT /password success" 200 "$STATUS"

# 16. PUT /password - invalid old password
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$URL/password" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"old_password":"wrong","new_password":"newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "PUT /password invalid old password" 401 "$STATUS"

# 17. DELETE /todos/:id - success
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$URL/todos/1" -b /tmp/cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
run_test "DELETE /todos/:id success" 204 "$STATUS"

# 18. DELETE /todos/:id - not found
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$URL/todos/1" -b /tmp/cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
run_test "DELETE /todos/:id not found" 404 "$STATUS"

# 19. POST /logout - success
RESP=$(curl -s -w "\n%{http_code}" -X POST "$URL/logout" -b /tmp/cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
run_test "POST /logout success" 200 "$STATUS"

# 20. GET /me after logout - should be 401
RESP=$(curl -s -w "\n%{http_code}" -X GET "$URL/me" -b /tmp/cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
run_test "GET /me after logout" 401 "$STATUS"

echo "Stopping server..."
kill $SERVER_PID 2>/dev/null
echo "Tests completed!"
