#!/bin/bash
set -e

PORT=8080
BASE_URL="http://localhost:$PORT"

echo "Starting server..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 2

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Testing /register (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
  echo "FAIL: /register valid, got $CODE, body: $(echo "$RES" | sed '$d')"
  exit 1
fi
echo "PASS: /register valid"

echo "Testing /register (invalid username)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: /register invalid username, got $CODE"
  exit 1
fi
echo "PASS: /register invalid username"

echo "Testing /register (password too short)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: /register password too short, got $CODE"
  exit 1
fi
echo "PASS: /register password too short"

echo "Testing /register (duplicate)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then
  echo "FAIL: /register duplicate, got $CODE"
  exit 1
fi
echo "PASS: /register duplicate"

echo "Testing /login (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: /login valid, got $CODE, body: $(echo "$RES" | sed '$d')"
  exit 1
fi
echo "PASS: /login valid"

echo "Testing /login (invalid creds)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: /login invalid creds, got $CODE"
  exit 1
fi
echo "PASS: /login invalid creds"

echo "Testing /me (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: /me valid, got $CODE"
  exit 1
fi
echo "PASS: /me valid"

echo "Testing /me (no auth)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: /me no auth, got $CODE"
  exit 1
fi
echo "PASS: /me no auth"

echo "Testing /password (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: /password valid, got $CODE"
  exit 1
fi
echo "PASS: /password valid"

echo "Testing /password (wrong old password)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: /password wrong old password, got $CODE"
  exit 1
fi
echo "PASS: /password wrong old password"

echo "Testing /password (new password too short)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: /password new password too short, got $CODE"
  exit 1
fi
echo "PASS: /password new password too short"

echo "Testing /todos (empty)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: /todos empty, got $CODE"
  exit 1
fi
echo "PASS: /todos empty"

echo "Testing /todos (create)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "Buy milk", "description": "From the store"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
  echo "FAIL: /todos create, got $CODE, body: $(echo "$RES" | sed '$d')"
  exit 1
fi
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
echo "PASS: /todos create (ID: $TODO_ID)"

echo "Testing /todos (create without title)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description": "From the store"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: /todos create without title, got $CODE"
  exit 1
fi
echo "PASS: /todos create without title"

echo "Testing /todos/:id (get)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: /todos/:id get, got $CODE"
  exit 1
fi
echo "PASS: /todos/:id get"

echo "Testing /todos/:id (get not found)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/9999" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
  echo "FAIL: /todos/:id get not found, got $CODE"
  exit 1
fi
echo "PASS: /todos/:id get not found"

echo "Testing /todos/:id (update)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: /todos/:id update, got $CODE"
  exit 1
fi
echo "PASS: /todos/:id update"

echo "Testing /todos/:id (update empty title)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: /todos/:id update empty title, got $CODE"
  exit 1
fi
echo "PASS: /todos/:id update empty title"

echo "Testing /todos/:id (delete)..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then
  echo "FAIL: /todos/:id delete, got $CODE"
  exit 1
fi
echo "PASS: /todos/:id delete"

echo "Testing /todos/:id (delete not found)..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
  echo "FAIL: /todos/:id delete not found, got $CODE"
  exit 1
fi
echo "PASS: /todos/:id delete not found"

echo "Testing /logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: /logout, got $CODE"
  exit 1
fi
echo "PASS: /logout"

echo "Testing /me after logout..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: /me after logout, got $CODE"
  exit 1
fi
echo "PASS: /me after logout"

echo "ALL TESTS PASSED!"