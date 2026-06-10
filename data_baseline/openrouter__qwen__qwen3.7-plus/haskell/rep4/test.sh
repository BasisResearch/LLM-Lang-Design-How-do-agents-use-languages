#!/bin/bash
set -e

PORT=${1:-8080}
BASE="http://localhost:$PORT"
COOKIE=""

echo "=== Starting Tests ==="

# Helper function to extract cookie
get_cookie() {
  COOKIE=$(echo "$1" | grep -i "set-cookie" | sed 's/.*session_id=\([^;]*\).*/\1/' | tr -d '\r')
}

# 1. Register a user
echo "1. Testing POST /register (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "201" ]; then
  echo "FAIL: Expected 201, got $CODE"
  echo "Body: $BODY"
  exit 1
fi
echo "PASS: register 201"

# 2. Register with invalid username
echo "2. Testing POST /register (invalid username)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "400" ]; then
  echo "FAIL: Expected 400, got $CODE"
  exit 1
fi
if [[ "$BODY" != *"Invalid username"* ]]; then
  echo "FAIL: Expected 'Invalid username' in body"
  exit 1
fi
echo "PASS: register invalid username 400"

# 3. Register with short password
echo "3. Testing POST /register (short password)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "400" ]; then
  echo "FAIL: Expected 400, got $CODE"
  exit 1
fi
if [[ "$BODY" != *"Password too short"* ]]; then
  echo "FAIL: Expected 'Password too short' in body"
  exit 1
fi
echo "PASS: register short password 400"

# 4. Register existing user
echo "4. Testing POST /register (existing user)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "409" ]; then
  echo "FAIL: Expected 409, got $CODE"
  exit 1
fi
if [[ "$BODY" != *"Username already exists"* ]]; then
  echo "FAIL: Expected 'Username already exists' in body"
  exit 1
fi
echo "PASS: register existing user 409"

# 5. Login
echo "5. Testing POST /login"
RESP=$(curl -s -i -X POST "$BASE/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | grep "HTTP/" | awk '{print $2}' | tr -d '\r')
if [ "$CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $CODE"
  exit 1
fi
get_cookie "$RESP"
if [ -z "$COOKIE" ]; then
  echo "FAIL: No session cookie received"
  exit 1
fi
echo "PASS: login 200 (cookie: $COOKIE)"

# 6. Login with invalid credentials
echo "6. Testing POST /login (invalid credentials)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "401" ]; then
  echo "FAIL: Expected 401, got $CODE"
  exit 1
fi
if [[ "$BODY" != *"Invalid credentials"* ]]; then
  echo "FAIL: Expected 'Invalid credentials' in body"
  exit 1
fi
echo "PASS: login invalid credentials 401"

# 7. GET /me without auth
echo "7. Testing GET /me (no auth)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me")
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: Expected 401, got $CODE"
  exit 1
fi
echo "PASS: /me no auth 401"

# 8. GET /me with auth
echo "8. Testing GET /me (with auth)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" \
  -H "Cookie: session_id=$COOKIE")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $CODE"
  echo "Body: $BODY"
  exit 1
fi
if [[ "$BODY" != *"testuser"* ]]; then
  echo "FAIL: Expected 'testuser' in body"
  exit 1
fi
echo "PASS: /me with auth 200"

# 9. PUT /password
echo "9. Testing PUT /password"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" \
  -H "Cookie: session_id=$COOKIE" \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $CODE"
  exit 1
fi
echo "PASS: /password 200"

# 10. POST /todos
echo "10. Testing POST /todos"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" \
  -H "Cookie: session_id=$COOKIE" \
  -H "Content-Type: application/json" \
  -d '{"title": "My first todo", "description": "This is a test"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "201" ]; then
  echo "FAIL: Expected 201, got $CODE"
  exit 1
fi
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
echo "PASS: POST /todos 201 (id: $TODO_ID)"

# 11. POST /todos with empty title
echo "11. Testing POST /todos (empty title)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" \
  -H "Cookie: session_id=$COOKIE" \
  -H "Content-Type: application/json" \
  -d '{"title": "", "description": "This is a test"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "400" ]; then
  echo "FAIL: Expected 400, got $CODE"
  exit 1
fi
if [[ "$BODY" != *"Title is required"* ]]; then
  echo "FAIL: Expected 'Title is required' in body"
  exit 1
fi
echo "PASS: POST /todos empty title 400"

# 12. GET /todos
echo "12. Testing GET /todos"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos" \
  -H "Cookie: session_id=$COOKIE")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $CODE"
  exit 1
fi
if [[ "$BODY" != *"My first todo"* ]]; then
  echo "FAIL: Expected 'My first todo' in body"
  exit 1
fi
echo "PASS: GET /todos 200"

# 13. GET /todos/:id
echo "13. Testing GET /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/$TODO_ID" \
  -H "Cookie: session_id=$COOKIE")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $CODE"
  exit 1
fi
if [[ "$BODY" != *"My first todo"* ]]; then
  echo "FAIL: Expected 'My first todo' in body"
  exit 1
fi
echo "PASS: GET /todos/:id 200"

# 14. PUT /todos/:id
echo "14. Testing PUT /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/$TODO_ID" \
  -H "Cookie: session_id=$COOKIE" \
  -H "Content-Type: application/json" \
  -d '{"completed": true}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
if [ "$CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $CODE"
  exit 1
fi
if [[ "$BODY" != *"true"* ]]; then
  echo "FAIL: Expected 'true' (completed) in body"
  exit 1
fi
echo "PASS: PUT /todos/:id 200"

# 15. DELETE /todos/:id
echo "15. Testing DELETE /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/todos/$TODO_ID" \
  -H "Cookie: session_id=$COOKIE")
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "204" ]; then
  echo "FAIL: Expected 204, got $CODE"
  exit 1
fi
echo "PASS: DELETE /todos/:id 204"

# 16. GET /todos/:id (should be 404 now)
echo "16. Testing GET /todos/:id (after delete)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/$TODO_ID" \
  -H "Cookie: session_id=$COOKIE")
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "404" ]; then
  echo "FAIL: Expected 404, got $CODE"
  exit 1
fi
echo "PASS: GET /todos/:id 404 after delete"

# 17. POST /logout
echo "17. Testing POST /logout"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE/logout" \
  -H "Cookie: session_id=$COOKIE")
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $CODE"
  exit 1
fi
echo "PASS: POST /logout 200"

# 18. GET /me (after logout, should be 401)
echo "18. Testing GET /me (after logout)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" \
  -H "Cookie: session_id=$COOKIE")
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: Expected 401, got $CODE"
  exit 1
fi
echo "PASS: GET /me 401 after logout"

# 19. Create another user to test 404 on other user's todo
echo "19. Testing other user's todo returns 404"
# Create user 2
curl -s -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' > /dev/null
# Login user 2
RESP2=$(curl -s -i -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}')
get_cookie "$RESP2"
COOKIE2="$COOKIE"
# User 2 creates a todo
RESP3=$(curl -s -X POST "$BASE/todos" -H "Cookie: session_id=$COOKIE2" -H "Content-Type: application/json" -d '{"title": "User 2 todo"}')
TODO_ID2=$(echo "$RESP3" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
# Login user 1
curl -s -i -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' > /tmp/login1.txt
get_cookie "$(cat /tmp/login1.txt)"
COOKIE1="$COOKIE"
# User 1 tries to get user 2's todo
RESP4=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/$TODO_ID2" -H "Cookie: session_id=$COOKIE1")
CODE4=$(echo "$RESP4" | tail -n1)
if [ "$CODE4" != "404" ]; then
  echo "FAIL: Expected 404 when accessing other user's todo, got $CODE4"
  exit 1
fi
echo "PASS: Other user's todo returns 404"

echo "=== ALL TESTS PASSED ==="
