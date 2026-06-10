#!/bin/bash

# Test script for Todo App

PORT=3005
BASE_URL="http://localhost:$PORT"

echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 2

echo "Server started with PID $SERVER_PID"

# Helper to clean up
cleanup() {
    echo "Stopping server with PID $SERVER_PID..."
    kill $SERVER_PID
    wait $SERVER_PID 2>/dev/null
    exit 1
}

trap cleanup EXIT

pass() {
    echo "✅ PASS: $1"
}

fail() {
    echo "❌ FAIL: $1"
    exit 1
}

assert_status() {
    if [ "$1" -eq "$2" ]; then
        pass "$3 (status $2)"
    else
        fail "$3 expected $2, got $1"
    fi
}

# Test 1: Register a new user
echo "Test 1: Register new user"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_status "$STATUS" "201" "Register new user"
echo "$BODY" | grep -q '"id":1' || fail "Expected id 1"
echo "$BODY" | grep -q '"username":"testuser"' || fail "Expected username testuser"
pass "Register new user body matches"

# Test 2: Register with invalid username
echo "Test 2: Register with invalid username"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "400" "Invalid username"

# Test 3: Register with short password
echo "Test 3: Register with short password"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "short"}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "400" "Short password"

# Test 4: Register with duplicate username
echo "Test 4: Register with duplicate username"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "409" "Duplicate username"

# Test 5: Login with correct credentials
echo "Test 5: Login with correct credentials"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -c cookies.txt -d '{"username": "testuser", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_status "$STATUS" "200" "Login success"
echo "$BODY" | grep -q '"username":"testuser"' || fail "Expected username testuser"
pass "Login body matches"

# Check if cookie was set
grep -q "session_id" cookies.txt || fail "session_id cookie not set"

# Test 6: Login with invalid credentials
echo "Test 6: Login with invalid credentials"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "401" "Invalid credentials login"

# Test 7: Get /me
echo "Test 7: Get /me"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_status "$STATUS" "200" "Get /me success"
echo "$BODY" | grep -q '"username":"testuser"' || fail "Expected username testuser in /me"
pass "Get /me body matches"

# Test 8: GET /me without auth
echo "Test 8: Get /me without auth"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "401" "Get /me without auth"

# Test 9: PUT /password
echo "Test 9: PUT /password"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "200" "Change password success"

# Test 10: Change password with wrong old password
echo "Test 10: Change password with wrong old password"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password": "wrong", "new_password": "newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "401" "Change password with wrong password"

# Test 11: Change password with short new password
echo "Test 11: Change password with short new password"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "400" "Change password with short password"

# Create a second user for testing access control
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}')
RESP2=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -c cookies2.txt -d '{"username": "user2", "password": "password123"}')

# Test 12: POST /todos
echo "Test 12: POST /todos"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title": "My First Todo", "description": "This is a description"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_status "$STATUS" "201" "Create todo success"
echo "$BODY" | grep -q '"title":"My First Todo"' || fail "Expected title"
echo "$BODY" | grep -q '"completed":false' || fail "Expected completed false"
echo "$BODY" | grep -q '"created_at"' || fail "Expected created_at"
echo "$BODY" | grep -q '"updated_at"' || fail "Expected updated_at"
pass "Create todo body matches"

# Extract todo id
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)

# Test 13: POST /todos with missing title
echo "Test 13: POST /todos with missing title"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"description": "No title"}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "400" "Missing title"

# Test 14: POST /todos with empty title
echo "Test 14: POST /todos with empty title"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title": "   "}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "400" "Empty title"

# Test 15: GET /todos
echo "Test 15: GET /todos"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_status "$STATUS" "200" "Get todos"
echo "$BODY" | grep -q '"title":"My First Todo"' || fail "Expected todo in list"
pass "Get todos body matches"

# Test 16: GET /todos/:id
echo "Test 16: GET /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_status "$STATUS" "200" "Get specific todo"
echo "$BODY" | grep -q '"title":"My First Todo"' || fail "Expected todo details"
pass "Get specific todo body matches"

# Test 17: GET /todos/:id for another user's todo
# First, create a todo for user2
RESP_USER2_TODO=$(curl -s -X POST "$BASE_URL/todos" -b cookies2.txt -H "Content-Type: application/json" -d '{"title": "User 2 Todo"}')
USER2_TODO_ID=$(echo "$RESP_USER2_TODO" | grep -o '"id":[0-9]*' | cut -d':' -f2)

echo "Test 17: GET /todos/:id for another user's todo"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$USER2_TODO_ID" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "404" "Get another user's todo returns 404"

# Test 18: PUT /todos/:id (partial update)
echo "Test 18: PUT /todos/:id (partial update)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -b cookies.txt -H "Content-Type: application/json" -d '{"completed": true, "description": "Updated description"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_status "$STATUS" "200" "Update todo"
echo "$BODY" | grep -q '"completed":true' || fail "Expected completed true"
echo "$BODY" | grep -q '"description":"Updated description"' || fail "Expected updated description"
echo "$BODY" | grep -q '"title":"My First Todo"' || fail "Expected title to remain unchanged"
pass "Partial update body matches"

# Test 19: PUT /todos/:id with empty title
echo "Test 19: PUT /todos/:id with empty title"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -b cookies.txt -H "Content-Type: application/json" -d '{"title": "   "}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "400" "Update with empty title"

# Test 20: PUT /todos/:id for another user's todo
echo "Test 20: PUT /todos/:id for another user's todo"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$USER2_TODO_ID" -b cookies.txt -H "Content-Type: application/json" -d '{"title": "Hacked"}')
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "404" "Update another user's todo returns 404"

# Test 21: DELETE /todos/:id
echo "Test 21: DELETE /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "204" "Delete todo"

# Test 22: GET /todos/:id after deletion
echo "Test 22: GET /todos/:id after deletion"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "404" "Get deleted todo returns 404"

# Test 23: DELETE /todos/:id for another user's todo
echo "Test 23: DELETE /todos/:id for another user's todo"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$USER2_TODO_ID" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "404" "Delete another user's todo returns 404"

# Test 24: POST /logout
echo "Test 24: POST /logout"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "200" "Logout success"

# Test 25: GET /me after logout
echo "Test 25: GET /me after logout"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
STATUS=$(echo "$RESP" | tail -n1)
assert_status "$STATUS" "401" "Get /me after logout returns 401"

# Cleanup temporary files
rm -f cookies.txt cookies2.txt

echo ""
echo "🎉 All tests passed!"
trap - EXIT
kill $SERVER_PID
exit 0
