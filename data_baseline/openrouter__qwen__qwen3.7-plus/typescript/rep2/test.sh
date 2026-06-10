#!/bin/bash
set -e

PORT=3001

# Start server in background
node dist/index.js --port $PORT &
SERVER_PID=$!
sleep 2

# Cleanup function
cleanup() {
  kill $SERVER_PID || true
}
trap cleanup EXIT

# Wait for server to be ready
for i in {1..10}; do
  if curl -s http://localhost:$PORT/me > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

COOKIE_JAR="/tmp/todo_cookies.txt"
> "$COOKIE_JAR"

# Test 1: Register
echo "Testing register..."
RES=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
  echo "FAIL: Register expected 201, got $CODE"
  exit 1
fi

# Test 2: Register duplicate
echo "Testing register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then
  echo "FAIL: Register duplicate expected 409, got $CODE"
  exit 1
fi

# Test 3: Register invalid username
echo "Testing register invalid username..."
RES=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: Register invalid username expected 400, got $CODE"
  exit 1
fi

# Test 4: Register short password
echo "Testing register short password..."
RES=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: Register short password expected 400, got $CODE"
  exit 1
fi

# Test 5: Login
echo "Testing login..."
RES=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  -c "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: Login expected 200, got $CODE"
  exit 1
fi

# Test 6: Login invalid credentials
echo "Testing login invalid credentials..."
RES=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: Login invalid credentials expected 401, got $CODE"
  exit 1
fi

# Test 7: GET /me
echo "Testing GET /me..."
RES=$(curl -s -w "\n%{http_code}" -X GET http://localhost:$PORT/me -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: GET /me expected 200, got $CODE"
  exit 1
fi

# Test 8: GET /me without auth
echo "Testing GET /me without auth..."
RES=$(curl -s -w "\n%{http_code}" -X GET http://localhost:$PORT/me)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: GET /me without auth expected 401, got $CODE"
  exit 1
fi

# Test 9: PUT /password
echo "Testing PUT /password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword123"}' \
  -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: PUT /password expected 200, got $CODE"
  exit 1
fi

# Test 10: PUT /password wrong old password
echo "Testing PUT /password wrong old password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword123"}' \
  -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: PUT /password wrong old password expected 401, got $CODE"
  exit 1
fi

# Test 11: Create Todo
echo "Testing POST /todos..."
RES=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "My Todo", "description": "Do something"}' \
  -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
  echo "FAIL: POST /todos expected 201, got $CODE"
  exit 1
fi

# Test 12: Create Todo without title
echo "Testing POST /todos without title..."
RES=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/todos \
  -H "Content-Type: application/json" \
  -d '{"description": "Do something"}' \
  -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: POST /todos without title expected 400, got $CODE"
  exit 1
fi

# Test 13: GET /todos
echo "Testing GET /todos..."
RES=$(curl -s -w "\n%{http_code}" -X GET http://localhost:$PORT/todos -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: GET /todos expected 200, got $CODE"
  exit 1
fi

# Test 14: GET /todos/:id
echo "Testing GET /todos/1..."
RES=$(curl -s -w "\n%{http_code}" -X GET http://localhost:$PORT/todos/1 -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: GET /todos/1 expected 200, got $CODE"
  exit 1
fi

# Test 15: GET /todos/:id not found
echo "Testing GET /todos/999..."
RES=$(curl -s -w "\n%{http_code}" -X GET http://localhost:$PORT/todos/999 -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
  echo "FAIL: GET /todos/999 expected 404, got $CODE"
  exit 1
fi

# Test 16: PUT /todos/:id
echo "Testing PUT /todos/1..."
RES=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/todos/1 \
  -H "Content-Type: application/json" \
  -d '{"completed": true}' \
  -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: PUT /todos/1 expected 200, got $CODE"
  exit 1
fi

# Test 17: DELETE /todos/:id
echo "Testing DELETE /todos/1..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE http://localhost:$PORT/todos/1 -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then
  echo "FAIL: DELETE /todos/1 expected 204, got $CODE"
  exit 1
fi

# Test 18: DELETE /todos/:id not found
echo "Testing DELETE /todos/1 again..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE http://localhost:$PORT/todos/1 -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
  echo "FAIL: DELETE /todos/1 again expected 404, got $CODE"
  exit 1
fi

# Test 19: Logout
echo "Testing POST /logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/logout -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: POST /logout expected 200, got $CODE"
  exit 1
fi

# Test 20: GET /me after logout
echo "Testing GET /me after logout..."
RES=$(curl -s -w "\n%{http_code}" -X GET http://localhost:$PORT/me -b "$COOKIE_JAR")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: GET /me after logout expected 401, got $CODE"
  exit 1
fi

echo "All tests passed!"
