#!/bin/bash
set -e

PORT=8888
BASE_URL="http://localhost:$PORT"

# Start server in background
cargo build --release --quiet
./target/release/todo_app --port "$PORT" &
SERVER_PID=$!

# Wait for server to start
sleep 2

# Function to cleanup
cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    exit 1
}
trap cleanup EXIT

echo "Testing POST /register (valid)..."
RESP=$(curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
echo "$RESP" | grep -q '"id":1' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing POST /register (invalid username)..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
echo "$RESP" | grep -q '400' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing POST /register (password too short)..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
echo "$RESP" | grep -q '400' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing POST /register (username exists)..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
echo "$RESP" | grep -q '409' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing POST /login (valid)..."
RESP=$(curl -s -i -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
COOKIE=$(echo "$RESP" | grep -i "Set-Cookie" | grep -o "session_id=[^;]*" | cut -d= -f2)
echo "$RESP" | grep -q '"id":1' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing GET /me (valid)..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -H "Cookie: session_id=$COOKIE")
echo "$RESP" | grep -q '"id":1' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing GET /me (invalid cookie)..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -H "Cookie: session_id=invalid")
echo "$RESP" | grep -q '401' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing PUT /password (valid)..."
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE" -d '{"old_password": "password123", "new_password": "newpassword123"}')
echo "$RESP" | grep -q '200' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing PUT /password (wrong old password)..."
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE" -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}')
echo "$RESP" | grep -q '401' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing PUT /password (new password too short)..."
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE" -d '{"old_password": "newpassword123", "new_password": "short"}')
echo "$RESP" | grep -q '400' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing POST /todos (valid)..."
RESP=$(curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE" -d '{"title": "My Todo", "description": "Do this"}')
TODO_ID=$(echo "$RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
echo "$RESP" | grep -q '"title":"My Todo"' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing GET /todos..."
RESP=$(curl -s -X GET "$BASE_URL/todos" -H "Cookie: session_id=$COOKIE")
echo "$RESP" | grep -q '"title":"My Todo"' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing GET /todos/:id (valid)..."
RESP=$(curl -s -X GET "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE")
echo "$RESP" | grep -q '"title":"My Todo"' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing PUT /todos/:id (valid)..."
RESP=$(curl -s -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE" -d '{"completed": true}')
echo "$RESP" | grep -q '"completed":true' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing PUT /todos/:id (empty title)..."
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE" -d '{"title": ""}')
echo "$RESP" | grep -q '400' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing DELETE /todos/:id..."
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE")
echo "$RESP" | grep -q '204' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing GET /todos/:id (after delete)..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE")
echo "$RESP" | grep -q '404' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing POST /logout..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -H "Cookie: session_id=$COOKIE")
echo "$RESP" | grep -q '200' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing GET /me (after logout)..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -H "Cookie: session_id=$COOKIE")
echo "$RESP" | grep -q '401' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "Testing GET /todos/:id (other user's todo)..."
# Create user 2
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' > /dev/null
RESP2=$(curl -s -i -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}')
COOKIE2=$(echo "$RESP2" | grep -i "Set-Cookie" | grep -o "session_id=[^;]*" | cut -d= -f2)

# Create todo for user 2
RESP=$(curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE2" -d '{"title": "User2 Todo"}')
TODO_ID2=$(echo "$RESP" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

# User 1 tries to get user 2's todo (login user1 again)
RESP1=$(curl -s -i -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}')
COOKIE1=$(echo "$RESP1" | grep -i "Set-Cookie" | grep -o "session_id=[^;]*" | cut -d= -f2)

RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID2" -H "Cookie: session_id=$COOKIE1")
echo "$RESP" | grep -q '404' && echo "PASS" || { echo "FAIL: $RESP"; exit 1; }

echo "All tests passed!"
trap - EXIT
kill $SERVER_PID 2>/dev/null || true
