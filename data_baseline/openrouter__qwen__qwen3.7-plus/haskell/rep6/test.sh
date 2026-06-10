#!/bin/bash
set -e

PORT=3042
echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 2

# Function to cleanup
cleanup() {
  echo "Stopping server..."
  kill $SERVER_PID 2>/dev/null || true
  exit $1
}
trap 'cleanup 1' ERR
trap 'cleanup 0' EXIT

BASE="http://localhost:$PORT"

echo "=== Testing /register ==="
# Success
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ]; then echo "FAIL: register expected 201, got $CODE. Body: $BODY"; exit 1; fi
echo "PASS: register"

# Duplicate username
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then echo "FAIL: register dup expected 409, got $CODE"; exit 1; fi
echo "PASS: register duplicate"

# Invalid username
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: register invalid username expected 400, got $CODE"; exit 1; fi
echo "PASS: register invalid username"

# Password too short
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: register short password expected 400, got $CODE"; exit 1; fi
echo "PASS: register short password"

echo "=== Testing /login ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: login expected 200, got $CODE"; exit 1; fi
echo "PASS: login"

# Invalid credentials
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: login invalid expected 401, got $CODE"; exit 1; fi
echo "PASS: login invalid"

echo "=== Testing /me ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: /me expected 200, got $CODE"; exit 1; fi
echo "PASS: /me"

echo "=== Testing /password ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}' -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: /password expected 200, got $CODE"; exit 1; fi
echo "PASS: /password"

# Update cookies with new login
curl -s -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' -c cookies.txt > /dev/null

echo "=== Testing /todos ==="
# Create todo
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "A test todo"}' -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL: create todo expected 201, got $CODE"; exit 1; fi
TODO_ID=$(echo "$RES" | head -n -1 | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "PASS: create todo (ID: $TODO_ID)"

# Title required
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -H "Content-Type: application/json" -d '{"title": "", "description": "test"}' -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: create todo empty title expected 400, got $CODE"; exit 1; fi
echo "PASS: create todo empty title"

# List todos
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: list todos expected 200, got $CODE"; exit 1; fi
echo "PASS: list todos"

# Get specific todo
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: get todo expected 200, got $CODE"; exit 1; fi
echo "PASS: get todo"

# Update todo
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"completed": true}' -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: update todo expected 200, got $CODE"; exit 1; fi
echo "PASS: update todo"

# Update todo empty title
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"title": ""}' -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: update todo empty title expected 400, got $CODE"; exit 1; fi
echo "PASS: update todo empty title"

# Delete todo
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then echo "FAIL: delete todo expected 204, got $CODE"; exit 1; fi
echo "PASS: delete todo"

# Get deleted todo (should be 404)
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "FAIL: get deleted todo expected 404, got $CODE"; exit 1; fi
echo "PASS: get deleted todo (404)"

echo "=== Testing /logout ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/logout" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: logout expected 200, got $CODE"; exit 1; fi
echo "PASS: logout"

# Try to access /me after logout
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: /me after logout expected 401, got $CODE"; exit 1; fi
echo "PASS: /me after logout (401)"

echo "=== ALL TESTS PASSED ==="