#!/bin/bash
set -e

echo "Starting server in background..."
./run.sh --port 8086 &
SERVER_PID=$!
sleep 4

BASE_URL="http://localhost:8086"

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  rm -f /tmp/cookies.txt /tmp/cookies2.txt
}
trap cleanup EXIT

get_status() {
  curl -s -o /tmp/body.txt -w "%{http_code}" "$@"
}

echo "Testing POST /register..."
STATUS=$(get_status -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
if [ "$STATUS" -ne 201 ]; then
  echo "FAIL: POST /register expected 201, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: POST /register"

echo "Testing POST /register (duplicate)..."
STATUS=$(get_status -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
if [ "$STATUS" -ne 409 ]; then
  echo "FAIL: POST /register duplicate expected 409, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: POST /register (duplicate)"

echo "Testing POST /register (invalid username)..."
STATUS=$(get_status -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
if [ "$STATUS" -ne 400 ]; then
  echo "FAIL: POST /register invalid username expected 400, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: POST /register (invalid username)"

echo "Testing POST /register (short password)..."
STATUS=$(get_status -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
if [ "$STATUS" -ne 400 ]; then
  echo "FAIL: POST /register short password expected 400, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: POST /register (short password)"

echo "Testing POST /login..."
STATUS=$(get_status -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c /tmp/cookies.txt)
if [ "$STATUS" -ne 200 ]; then
  echo "FAIL: POST /login expected 200, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: POST /login"

echo "Testing GET /me..."
STATUS=$(get_status -X GET "$BASE_URL/me" -b /tmp/cookies.txt)
if [ "$STATUS" -ne 200 ]; then
  echo "FAIL: GET /me expected 200, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: GET /me"

echo "Testing POST /todos..."
curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"title": "My Todo", "description": "A test todo"}' -w "%{http_code}" -o /tmp/todo.txt > /tmp/status.txt
STATUS=$(cat /tmp/status.txt)
if [ "$STATUS" -ne 201 ]; then
  echo "FAIL: POST /todos expected 201, got $STATUS. Body: $(cat /tmp/todo.txt)"
  exit 1
fi
TODO_ID=$(grep -o '"id":[0-9]*' /tmp/todo.txt | cut -d: -f2)
echo "PASS: POST /todos (ID: $TODO_ID)"

echo "Testing GET /todos..."
STATUS=$(get_status -X GET "$BASE_URL/todos" -b /tmp/cookies.txt)
if [ "$STATUS" -ne 200 ]; then
  echo "FAIL: GET /todos expected 200, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: GET /todos"

echo "Testing GET /todos/:id..."
STATUS=$(get_status -X GET "$BASE_URL/todos/$TODO_ID" -b /tmp/cookies.txt)
if [ "$STATUS" -ne 200 ]; then
  echo "FAIL: GET /todos/:id expected 200, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: GET /todos/:id"

echo "Testing PUT /todos/:id..."
STATUS=$(get_status -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"completed": true}')
if [ "$STATUS" -ne 200 ]; then
  echo "FAIL: PUT /todos/:id expected 200, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: PUT /todos/:id"

echo "Testing PUT /password..."
STATUS=$(get_status -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
if [ "$STATUS" -ne 200 ]; then
  echo "FAIL: PUT /password expected 200, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: PUT /password"

echo "Testing DELETE /todos/:id..."
STATUS=$(get_status -X DELETE "$BASE_URL/todos/$TODO_ID" -b /tmp/cookies.txt)
if [ "$STATUS" -ne 204 ]; then
  echo "FAIL: DELETE /todos/:id expected 204, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: DELETE /todos/:id"

echo "Testing POST /logout..."
STATUS=$(get_status -X POST "$BASE_URL/logout" -b /tmp/cookies.txt)
if [ "$STATUS" -ne 200 ]; then
  echo "FAIL: POST /logout expected 200, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: POST /logout"

echo "Testing GET /me after logout (should be 401)..."
STATUS=$(get_status -X GET "$BASE_URL/me" -b /tmp/cookies.txt)
if [ "$STATUS" -ne 401 ]; then
  echo "FAIL: GET /me after logout expected 401, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: GET /me after logout"

echo "Testing GET /todos/:id for another user (should be 404)..."
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' > /dev/null
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' -c /tmp/cookies2.txt > /dev/null
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' -c /tmp/cookies.txt > /dev/null
curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b /tmp/cookies.txt -d '{"title": "User1 Todo"}' -w "%{http_code}" -o /tmp/todo2.txt > /tmp/status2.txt
NEW_TODO_ID=$(grep -o '"id":[0-9]*' /tmp/todo2.txt | cut -d: -f2)

STATUS=$(get_status -X GET "$BASE_URL/todos/$NEW_TODO_ID" -b /tmp/cookies2.txt)
if [ "$STATUS" -ne 404 ]; then
  echo "FAIL: GET /todos/:id for another user expected 404, got $STATUS. Body: $(cat /tmp/body.txt)"
  exit 1
fi
echo "PASS: GET /todos/:id for another user"

echo ""
echo "========================================="
echo "All tests passed successfully!"
echo "========================================="
