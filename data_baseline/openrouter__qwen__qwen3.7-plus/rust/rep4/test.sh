#!/bin/bash
set -e

PORT=8080
BASE_URL="http://127.0.0.1:$PORT"

echo "Starting server..."
cargo build --release
./target/release/todo_app --port $PORT &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt cookies2.txt
}
trap cleanup EXIT

echo "Testing POST /register (success)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "201" ]; then
  echo "FAILED: Expected 201, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: POST /register (success)"

echo "Testing POST /register (invalid username)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "400" ] || [[ "$BODY" != *"Invalid username"* ]]; then
  echo "FAILED: Expected 400 Invalid username, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: POST /register (invalid username)"

echo "Testing POST /register (password too short)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "short"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "400" ] || [[ "$BODY" != *"Password too short"* ]]; then
  echo "FAILED: Expected 400 Password too short, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: POST /register (password too short)"

echo "Testing POST /register (username already exists)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "409" ] || [[ "$BODY" != *"Username already exists"* ]]; then
  echo "FAILED: Expected 409 Username already exists, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: POST /register (username already exists)"

echo "Testing POST /login (success)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  -c cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: POST /login (success)"

echo "Testing POST /login (invalid credentials)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpassword"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "401" ] || [[ "$BODY" != *"Invalid credentials"* ]]; then
  echo "FAILED: Expected 401 Invalid credentials, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: POST /login (invalid credentials)"

echo "Testing GET /me (success)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "200" ] || [[ "$BODY" != *"testuser"* ]]; then
  echo "FAILED: Expected 200 with testuser, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: GET /me (success)"

echo "Testing GET /me (no auth)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "401" ] || [[ "$BODY" != *"Authentication required"* ]]; then
  echo "FAILED: Expected 401 Authentication required, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: GET /me (no auth)"

echo "Testing PUT /password (success)"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"old_password": "password123", "new_password": "newpassword123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: PUT /password (success)"

echo "Testing PUT /password (invalid old password)"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"old_password": "wrongpassword", "new_password": "newpassword1234"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "401" ] || [[ "$BODY" != *"Invalid credentials"* ]]; then
  echo "FAILED: Expected 401 Invalid credentials, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: PUT /password (invalid old password)"

echo "Testing PUT /password (new password too short)"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"old_password": "newpassword123", "new_password": "short"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "400" ] || [[ "$BODY" != *"Password too short"* ]]; then
  echo "FAILED: Expected 400 Password too short, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: PUT /password (new password too short)"

echo "Testing POST /logout (success)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt -c cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: POST /logout (success)"

echo "Testing GET /me after logout"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "401" ] || [[ "$BODY" != *"Authentication required"* ]]; then
  echo "FAILED: Expected 401 Authentication required after logout, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: GET /me after logout"

# Re-login for todo tests
curl -s -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newpassword123"}' \
  -c cookies.txt > /dev/null

echo "Testing GET /todos (empty)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "200" ] || [ "$BODY" != "[]" ]; then
  echo "FAILED: Expected 200 [], got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: GET /todos (empty)"

echo "Testing POST /todos (success)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"title": "My First Todo", "description": "This is a test"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "201" ] || [[ "$BODY" != *"My First Todo"* ]]; then
  echo "FAILED: Expected 201, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)
echo "PASSED: POST /todos (success), Todo ID: $TODO_ID"

echo "Testing POST /todos (missing title)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"description": "No title"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "400" ] || [[ "$BODY" != *"Title is required"* ]]; then
  echo "FAILED: Expected 400 Title is required, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: POST /todos (missing title)"

echo "Testing POST /todos (empty title)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"title": "", "description": "No title"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "400" ] || [[ "$BODY" != *"Title is required"* ]]; then
  echo "FAILED: Expected 400 Title is required, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: POST /todos (empty title)"

echo "Testing GET /todos (with items)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "200" ] || [[ "$BODY" != *"My First Todo"* ]]; then
  echo "FAILED: Expected 200 with todo, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: GET /todos (with items)"

echo "Testing GET /todos/:id (success)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "200" ] || [[ "$BODY" != *"My First Todo"* ]]; then
  echo "FAILED: Expected 200, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: GET /todos/:id (success)"

echo "Testing GET /todos/:id (not found)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/9999" -b cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "404" ] || [[ "$BODY" != *"Todo not found"* ]]; then
  echo "FAILED: Expected 404 Todo not found, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: GET /todos/:id (not found)"

echo "Testing PUT /todos/:id (success)"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"completed": true}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "200" ] || [[ "$BODY" != *"\"completed\":true"* ]]; then
  echo "FAILED: Expected 200 with completed true, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: PUT /todos/:id (success)"

echo "Testing PUT /todos/:id (empty title)"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"title": ""}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "400" ] || [[ "$BODY" != *"Title is required"* ]]; then
  echo "FAILED: Expected 400 Title is required, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: PUT /todos/:id (empty title)"

echo "Testing DELETE /todos/:id (success)"
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "204" ]; then
  echo "FAILED: Expected 204, got $HTTP_CODE."
  exit 1
fi
echo "PASSED: DELETE /todos/:id (success)"

echo "Testing DELETE /todos/:id (not found)"
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "404" ] || [[ "$BODY" != *"Todo not found"* ]]; then
  echo "FAILED: Expected 404 Todo not found, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: DELETE /todos/:id (not found)"

# Create another user and try to access the first user's todo
# Need to create a new todo for testuser to get a valid ID
curl -s -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newpassword123"}' \
  -c cookies.txt > /dev/null

TODO_ID2_RES=$(curl -s -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"title": "Testuser Todo", "description": "Test"}')
TODO_ID2=$(echo "$TODO_ID2_RES" | grep -o '"id":[0-9]*' | cut -d':' -f2)

curl -s -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "password123"}' > /dev/null

curl -s -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "password123"}' \
  -c cookies2.txt > /dev/null

echo "Testing GET /todos/:id (other user's todo)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID2" -b cookies2.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "404" ] || [[ "$BODY" != *"Todo not found"* ]]; then
  echo "FAILED: Expected 404 Todo not found for other user's todo, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: GET /todos/:id (other user's todo)"

echo "Testing PUT /todos/:id (other user's todo)"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID2" \
  -H "Content-Type: application/json" \
  -b cookies2.txt \
  -d '{"completed": true}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "404" ] || [[ "$BODY" != *"Todo not found"* ]]; then
  echo "FAILED: Expected 404 Todo not found for other user's todo, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: PUT /todos/:id (other user's todo)"

echo "Testing DELETE /todos/:id (other user's todo)"
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID2" -b cookies2.txt)
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" != "404" ] || [[ "$BODY" != *"Todo not found"* ]]; then
  echo "FAILED: Expected 404 Todo not found for other user's todo, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASSED: DELETE /todos/:id (other user's todo)"

echo ""
echo "ALL TESTS PASSED!"