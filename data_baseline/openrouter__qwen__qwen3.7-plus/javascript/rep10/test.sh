#!/bin/bash
set -e

PORT=3000
BASE_URL="http://localhost:$PORT"

# Start server
node server.js --port $PORT &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt cookies2.txt
}
trap cleanup EXIT

check_response() {
    local expected_status=$1
    local expected_body=$2
    local actual_status=$3
    local actual_body=$4
    
    if [ "$actual_status" != "$expected_status" ]; then
        echo "FAIL: Expected status $expected_status, got $actual_status"
        echo "Body: $actual_body"
        exit 1
    fi
    if [ -n "$expected_body" ]; then
        if ! echo "$actual_body" | grep -qF "$expected_body"; then
            echo "FAIL: Expected body to contain '$expected_body', got '$actual_body'"
            exit 1
        fi
    fi
    echo "PASS"
}

echo "Testing POST /register"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 201 '"username":"testuser"' "$STATUS" "$BODY"

echo "Testing POST /register (duplicate)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 409 '"error":"Username already exists"' "$STATUS" "$BODY"

echo "Testing POST /register (invalid username)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"error":"Invalid username"' "$STATUS" "$BODY"

echo "Testing POST /register (short password)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser2","password":"short"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"error":"Password too short"' "$STATUS" "$BODY"

echo "Testing POST /login"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"username":"testuser"' "$STATUS" "$BODY"

echo "Testing POST /login (invalid credentials)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"wrongpassword"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 '"error":"Invalid credentials"' "$STATUS" "$BODY"

echo "Testing GET /me"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"username":"testuser"' "$STATUS" "$BODY"

echo "Testing GET /me (unauthorized)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 '"error":"Authentication required"' "$STATUS" "$BODY"

echo "Testing PUT /password"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '{}' "$STATUS" "$BODY"

echo "Testing PUT /password (wrong old password)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"wrong","new_password":"newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 '"error":"Invalid credentials"' "$STATUS" "$BODY"

echo "Testing PUT /password (short new password)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"newpassword123","new_password":"short"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"error":"Password too short"' "$STATUS" "$BODY"

echo "Testing POST /todos"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title":"My first todo","description":"This is a description"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 201 '"title":"My first todo"' "$STATUS" "$BODY"
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

echo "Testing POST /todos (missing title)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description":"No title"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"error":"Title is required"' "$STATUS" "$BODY"

echo "Testing POST /todos (empty title)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title":""}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"error":"Title is required"' "$STATUS" "$BODY"

echo "Testing GET /todos"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"title":"My first todo"' "$STATUS" "$BODY"

echo "Testing GET /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"title":"My first todo"' "$STATUS" "$BODY"

echo "Testing GET /todos/:id (not found)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/9999" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 404 '"error":"Todo not found"' "$STATUS" "$BODY"

echo "Testing PUT /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed":true,"title":"Updated title"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"completed":true' "$STATUS" "$BODY"
check_response 200 '"title":"Updated title"' "$STATUS" "$BODY"

echo "Testing PUT /todos/:id (empty title)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title":""}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"error":"Title is required"' "$STATUS" "$BODY"

echo "Testing PUT /todos/:id (not found)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/9999" -H "Content-Type: application/json" -b cookies.txt -d '{"title":"test"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 404 '"error":"Todo not found"' "$STATUS" "$BODY"

echo "Testing POST /logout"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '{}' "$STATUS" "$BODY"

echo "Testing GET /me (after logout)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 '"error":"Authentication required"' "$STATUS" "$BODY"

echo "Testing POST /todos (another user)"
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"user2","password":"password123"}' > /dev/null
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"user2","password":"password123"}' -c cookies2.txt > /dev/null
RESP2=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies2.txt -d '{"title":"User 2 todo"}')
STATUS2=$(echo "$RESP2" | tail -n1)
BODY2=$(echo "$RESP2" | sed '$d')
TODO2_ID=$(echo "$BODY2" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

echo "Testing GET /todos/:id (belongs to another user)"
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' -c cookies.txt > /dev/null
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO2_ID" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 404 '"error":"Todo not found"' "$STATUS" "$BODY"

echo "Testing DELETE /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO2_ID" -b cookies2.txt)
STATUS=$(echo "$RESP" | tail -n1)
check_response 204 "" "$STATUS" ""

echo "Testing DELETE /todos/:id (after deletion)"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO2_ID" -b cookies2.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 404 '"error":"Todo not found"' "$STATUS" "$BODY"

echo "All tests passed!"
