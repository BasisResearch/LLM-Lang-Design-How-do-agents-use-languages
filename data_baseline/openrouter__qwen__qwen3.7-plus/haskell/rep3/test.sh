#!/bin/bash
set -e

PORT=8899
HOST="http://localhost:$PORT"

echo "Building project..."
cabal build

echo "Starting server on port $PORT..."
cabal run todo-app -- --port $PORT &
SERVER_PID=$!
sleep 3

cleanup() {
  echo "Cleaning up..."
  kill $SERVER_PID 2>/dev/null || true
  rm -f cookies.txt
}
trap cleanup EXIT

echo "Testing POST /register"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "201" ]; then
  echo "FAILED: Expected 201, got $CODE. Body: ${RES%$'\n'*}"
  exit 1
fi
echo "PASS: POST /register"

echo "Testing POST /register (invalid username)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then
  echo "FAILED: Expected 400, got $CODE"
  exit 1
fi
echo "PASS: POST /register (invalid username)"

echo "Testing POST /register (duplicate)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "409" ]; then
  echo "FAILED: Expected 409, got $CODE"
  exit 1
fi
echo "PASS: POST /register (duplicate)"

echo "Testing POST /login"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "PASS: POST /login"

echo "Testing POST /login (invalid credentials)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "401" ]; then
  echo "FAILED: Expected 401, got $CODE"
  exit 1
fi
echo "PASS: POST /login (invalid credentials)"

echo "Testing GET /me"
RES=$(curl -s -w "\n%{http_code}" -X GET "$HOST/me" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "PASS: GET /me"

echo "Testing GET /me (no auth)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$HOST/me")
CODE=${RES##*$'\n'}
if [ "$CODE" != "401" ]; then
  echo "FAILED: Expected 401, got $CODE"
  exit 1
fi
echo "PASS: GET /me (no auth)"

echo "Testing PUT /password"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$HOST/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "PASS: PUT /password"

echo "Testing PUT /password (short new password)"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$HOST/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then
  echo "FAILED: Expected 400, got $CODE"
  exit 1
fi
echo "PASS: PUT /password (short new password)"

echo "Testing POST /todos"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "Buy milk", "description": "Get 2 liters"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "201" ]; then
  echo "FAILED: Expected 201, got $CODE"
  exit 1
fi
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
echo "PASS: POST /todos (ID: $TODO_ID)"

echo "Testing POST /todos (missing title)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description": "No title"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then
  echo "FAILED: Expected 400, got $CODE"
  exit 1
fi
echo "PASS: POST /todos (missing title)"

echo "Testing GET /todos"
RES=$(curl -s -w "\n%{http_code}" -X GET "$HOST/todos" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "PASS: GET /todos"

echo "Testing GET /todos/:id"
RES=$(curl -s -w "\n%{http_code}" -X GET "$HOST/todos/$TODO_ID" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "PASS: GET /todos/:id"

echo "Testing GET /todos/:id (not found)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$HOST/todos/9999" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "404" ]; then
  echo "FAILED: Expected 404, got $CODE"
  exit 1
fi
echo "PASS: GET /todos/:id (not found)"

echo "Testing PUT /todos/:id"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$HOST/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "PASS: PUT /todos/:id"

echo "Testing PUT /todos/:id (empty title)"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$HOST/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then
  echo "FAILED: Expected 400, got $CODE"
  exit 1
fi
echo "PASS: PUT /todos/:id (empty title)"

echo "Testing DELETE /todos/:id"
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$HOST/todos/$TODO_ID" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "204" ]; then
  echo "FAILED: Expected 204, got $CODE"
  exit 1
fi
echo "PASS: DELETE /todos/:id"

echo "Testing DELETE /todos/:id (not found)"
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$HOST/todos/9999" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "404" ]; then
  echo "FAILED: Expected 404, got $CODE"
  exit 1
fi
echo "PASS: DELETE /todos/:id (not found)"

echo "Testing POST /logout"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/logout" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then
  echo "FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "PASS: POST /logout"

echo "Testing GET /me after logout"
RES=$(curl -s -w "\n%{http_code}" -X GET "$HOST/me" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "401" ]; then
  echo "FAILED: Expected 401 after logout, got $CODE"
  exit 1
fi
echo "PASS: GET /me after logout"

echo "ALL TESTS PASSED!"
trap - EXIT
kill $SERVER_PID 2>/dev/null || true
rm -f cookies.txt
exit 0
