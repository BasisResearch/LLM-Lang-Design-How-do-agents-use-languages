#!/bin/bash
set -e

PORT=8888
BASE_URL="http://127.0.0.1:$PORT"

echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 1

cleanup() {
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null || true
    exit 1
}
trap cleanup EXIT

pass() {
    echo "✅ PASS: $1"
}

fail() {
    echo "❌ FAIL: $1"
    echo "Expected: $2"
    echo "Got: $3"
    exit 1
}

# Test 1: Register a new user
echo "Testing POST /register..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "201" ] || fail "Register should return 201" "201" "$CODE"
echo "$BODY" | grep -q '"id":1' || fail "Register should return id 1" '"id":1' "$BODY"
echo "$BODY" | grep -q '"username":"testuser"' || fail "Register should return username" '"username":"testuser"' "$BODY"
pass "POST /register"

# Test 2: Register with invalid username (too short)
echo "Testing POST /register with invalid username..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "400" ] || fail "Invalid username should return 400" "400" "$CODE"
pass "POST /register invalid username"

# Test 3: Register with short password
echo "Testing POST /register with short password..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username": "validuser", "password": "short"}')
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "400" ] || fail "Short password should return 400" "400" "$CODE"
pass "POST /register short password"

# Test 4: Register duplicate username
echo "Testing POST /register duplicate username..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "409" ] || fail "Duplicate username should return 409" "409" "$CODE"
pass "POST /register duplicate username"

# Test 5: Login
echo "Testing POST /login..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}' \
    -c cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "200" ] || fail "Login should return 200" "200" "$CODE"
grep -q "session_id" cookies.txt || fail "Login should set session_id cookie" "session_id" "$(cat cookies.txt)"
pass "POST /login"

# Test 6: Login with invalid credentials
echo "Testing POST /login with invalid credentials..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "401" ] || fail "Invalid credentials should return 401" "401" "$CODE"
pass "POST /login invalid credentials"

# Test 7: GET /me
echo "Testing GET /me..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
BODY=$(echo "$RESP" | head -n 1)
[ "$CODE" = "200" ] || fail "GET /me should return 200" "200" "$CODE"
echo "$BODY" | grep -q '"id":1' || fail "GET /me should return id 1" '"id":1' "$BODY"
pass "GET /me"

# Test 8: GET /me without auth
echo "Testing GET /me without auth..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "401" ] || fail "GET /me without auth should return 401" "401" "$CODE"
pass "GET /me without auth"

# Test 9: PUT /password
echo "Testing PUT /password..."
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
    -H "Content-Type: application/json" \
    -b cookies.txt \
    -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "200" ] || fail "PUT /password should return 200" "200" "$CODE"
pass "PUT /password"

# Test 10: POST /todos
echo "Testing POST /todos..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
    -H "Content-Type: application/json" \
    -b cookies.txt \
    -d '{"title": "My first todo", "description": "This is a test"}')
CODE=$(echo "$RESP" | tail -n 1)
BODY=$(echo "$RESP" | head -n 1)
[ "$CODE" = "201" ] || fail "POST /todos should return 201" "201" "$CODE"
echo "$BODY" | grep -q '"id":1' || fail "POST /todos should return id 1" '"id":1' "$BODY"
echo "$BODY" | grep -q '"completed":false' || fail "POST /todos should return completed false" '"completed":false' "$BODY"
pass "POST /todos"

# Test 11: POST /todos with empty title
echo "Testing POST /todos with empty title..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
    -H "Content-Type: application/json" \
    -b cookies.txt \
    -d '{"title": "", "description": "test"}')
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "400" ] || fail "POST /todos with empty title should return 400" "400" "$CODE"
pass "POST /todos with empty title"

# Test 12: GET /todos
echo "Testing GET /todos..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
BODY=$(echo "$RESP" | head -n 1)
[ "$CODE" = "200" ] || fail "GET /todos should return 200" "200" "$CODE"
echo "$BODY" | grep -q '"title":"My first todo"' || fail "GET /todos should contain todo" '"title":"My first todo"' "$BODY"
pass "GET /todos"

# Test 13: GET /todos/:id
echo "Testing GET /todos/1..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/1" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
BODY=$(echo "$RESP" | head -n 1)
[ "$CODE" = "200" ] || fail "GET /todos/1 should return 200" "200" "$CODE"
echo "$BODY" | grep -q '"id":1' || fail "GET /todos/1 should return id 1" '"id":1' "$BODY"
pass "GET /todos/1"

# Test 14: GET /todos/:id not found
echo "Testing GET /todos/99..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/99" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "404" ] || fail "GET /todos/99 should return 404" "404" "$CODE"
pass "GET /todos/99"

# Test 15: PUT /todos/:id
echo "Testing PUT /todos/1..."
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/1" \
    -H "Content-Type: application/json" \
    -b cookies.txt \
    -d '{"completed": true, "title": "Updated title"}')
CODE=$(echo "$RESP" | tail -n 1)
BODY=$(echo "$RESP" | head -n 1)
[ "$CODE" = "200" ] || fail "PUT /todos/1 should return 200" "200" "$CODE"
echo "$BODY" | grep -q '"completed":true' || fail "PUT /todos/1 should return completed true" '"completed":true' "$BODY"
echo "$BODY" | grep -q '"title":"Updated title"' || fail "PUT /todos/1 should return updated title" '"title":"Updated title"' "$BODY"
pass "PUT /todos/1"

# Test 16: PUT /todos/:id with empty title
echo "Testing PUT /todos/1 with empty title..."
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/1" \
    -H "Content-Type: application/json" \
    -b cookies.txt \
    -d '{"title": ""}')
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "400" ] || fail "PUT /todos/1 with empty title should return 400" "400" "$CODE"
pass "PUT /todos/1 with empty title"

# Test 17: Create second user and verify isolation
echo "Testing user isolation..."
curl -s -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username": "user2", "password": "password123"}' > /dev/null
curl -s -X POST "$BASE_URL/login" \
    -H "Content-Type: application/json" \
    -d '{"username": "user2", "password": "password123"}' \
    -c cookies2.txt > /dev/null

# user2 should not see user1's todos
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies2.txt)
CODE=$(echo "$RESP" | tail -n 1)
BODY=$(echo "$RESP" | head -n 1)
[ "$CODE" = "200" ] || fail "GET /todos for user2 should return 200" "200" "$CODE"
echo "$BODY" | grep -q '\[\]' || fail "GET /todos for user2 should be empty" '[]' "$BODY"
pass "User isolation"

# Test 18: user2 trying to access user1's todo should return 404
echo "Testing cross-user todo access..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/1" -b cookies2.txt)
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "404" ] || fail "Cross-user todo access should return 404" "404" "$CODE"
pass "Cross-user todo access returns 404"

# Test 19: DELETE /todos/:id
echo "Testing DELETE /todos/1..."
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/1" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "204" ] || fail "DELETE /todos/1 should return 204" "204" "$CODE"
pass "DELETE /todos/1"

# Test 20: GET /todos after delete
echo "Testing GET /todos after delete..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
BODY=$(echo "$RESP" | head -n 1)
[ "$CODE" = "200" ] || fail "GET /todos after delete should return 200" "200" "$CODE"
echo "$BODY" | grep -q '\[\]' || fail "GET /todos after delete should be empty" '[]' "$BODY"
pass "GET /todos after delete"

# Test 21: POST /logout
echo "Testing POST /logout..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "200" ] || fail "POST /logout should return 200" "200" "$CODE"
pass "POST /logout"

# Test 22: GET /me after logout
echo "Testing GET /me after logout..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
[ "$CODE" = "401" ] || fail "GET /me after logout should return 401" "401" "$CODE"
pass "GET /me after logout"

echo ""
echo "🎉 All tests passed!"
trap - EXIT
kill $SERVER_PID 2>/dev/null || true
exit 0