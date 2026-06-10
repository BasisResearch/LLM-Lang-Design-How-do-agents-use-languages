#!/bin/bash

# Clean up any orphaned server processes first
pkill -f "tsx src/server.ts" 2>/dev/null || true
sleep 1

PORT=3001
./run.sh --port $PORT &
SERVER_PID=$!

# Wait for server to be ready
sleep 2

BASE_URL="http://localhost:$PORT"

echo "=== Testing POST /register ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL: register expected 201, got $CODE"; echo "$RES"; exit 1; fi
echo "PASS: register"

echo "=== Testing POST /register (invalid username) ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: invalid username expected 400, got $CODE"; exit 1; fi
echo "PASS: invalid username"

echo "=== Testing POST /register (short password) ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: short password expected 400, got $CODE"; exit 1; fi
echo "PASS: short password"

echo "=== Testing POST /register (duplicate) ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then echo "FAIL: duplicate username expected 409, got $CODE"; exit 1; fi
echo "PASS: duplicate username"

echo "=== Testing POST /login ==="
RES=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: login expected 200, got $CODE"; exit 1; fi
echo "PASS: login"

echo "=== Testing POST /login (invalid credentials) ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: invalid login expected 401, got $CODE"; exit 1; fi
echo "PASS: invalid login"

echo "=== Testing GET /me ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: /me expected 200, got $CODE"; exit 1; fi
echo "PASS: /me"

echo "=== Testing GET /me (no auth) ==="
RES=$(curl -s -w "\n%{http_code}" "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: /me no auth expected 401, got $CODE"; exit 1; fi
echo "PASS: /me no auth"

echo "=== Testing PUT /password ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: /password expected 200, got $CODE"; exit 1; fi
echo "PASS: /password"

echo "=== Testing PUT /password (wrong old password) ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: /password wrong old expected 401, got $CODE"; exit 1; fi
echo "PASS: /password wrong old"

echo "=== Testing POST /todos ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Do this"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL: POST /todos expected 201, got $CODE"; exit 1; fi
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
echo "PASS: POST /todos (ID: $TODO_ID)"

echo "=== Testing POST /todos (empty title) ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "", "description": "Do this"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: POST /todos empty title expected 400, got $CODE"; exit 1; fi
echo "PASS: POST /todos empty title"

echo "=== Testing GET /todos ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: GET /todos expected 200, got $CODE"; exit 1; fi
echo "PASS: GET /todos"

echo "=== Testing GET /todos/:id ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: GET /todos/:id expected 200, got $CODE"; exit 1; fi
echo "PASS: GET /todos/:id"

echo "=== Testing PUT /todos/:id ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: PUT /todos/:id expected 200, got $CODE"; exit 1; fi
if ! echo "$RES" | grep -qE '"completed":\s*true'; then echo "FAIL: PUT /todos/:id did not update completed"; exit 1; fi
echo "PASS: PUT /todos/:id"

echo "=== Testing PUT /todos/:id (empty title) ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: PUT /todos/:id empty title expected 400, got $CODE"; exit 1; fi
echo "PASS: PUT /todos/:id empty title"

echo "=== Testing DELETE /todos/:id ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then echo "FAIL: DELETE /todos/:id expected 204, got $CODE"; exit 1; fi
echo "PASS: DELETE /todos/:id"

echo "=== Testing GET /todos/:id after delete ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "FAIL: GET deleted todo expected 404, got $CODE"; exit 1; fi
echo "PASS: GET deleted todo is 404"

echo "=== Testing cross-user isolation ==="
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' > /dev/null
curl -s -c cookies2.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' > /dev/null
TODO2_ID=$(curl -s -b cookies2.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "User 2 Todo"}' | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
curl -s -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' > /dev/null
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO2_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "FAIL: cross-user GET expected 404, got $CODE"; exit 1; fi
echo "PASS: cross-user GET is 404"
rm -f cookies2.txt

echo "=== Testing POST /logout ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/logout")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: POST /logout expected 200, got $CODE"; exit 1; fi
echo "PASS: POST /logout"

echo "=== Testing GET /me after logout ==="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: /me after logout expected 401, got $CODE"; exit 1; fi
echo "PASS: /me after logout is 401"

# Kill all related processes
pkill -f "tsx src/server.ts" 2>/dev/null || true
rm -f cookies.txt
echo "=== ALL TESTS PASSED ==="
