#!/bin/bash

PORT=3002
BASE_URL="http://localhost:$PORT"

echo "Starting server..."
./run.sh --port $PORT > /tmp/server.log 2>&1 &
SERVER_PID=$!
echo "Server started with PID $SERVER_PID"

# Wait for server to be ready
for i in {1..10}; do
    if curl -s http://localhost:$PORT/me > /dev/null 2>&1; then
        echo "Server is ready!"
        break
    fi
    sleep 1
done

cleanup() {
    echo "Cleaning up server (PID $SERVER_PID)..."
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt /tmp/server.log
}
trap cleanup EXIT

echo "Testing POST /register (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "201" ]; then echo "FAIL: register valid, expected 201, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: register valid"

echo "Testing POST /register (invalid username)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "FAIL: register invalid username, expected 400, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: register invalid username"

echo "Testing POST /register (password too short)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "FAIL: register short password, expected 400, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: register short password"

echo "Testing POST /register (username already exists)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "409" ]; then echo "FAIL: register exists, expected 409, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: register exists"

echo "Testing POST /login (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: login valid, expected 200, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: login valid"

echo "Testing POST /login (invalid credentials)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "FAIL: login invalid, expected 401, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: login invalid"

echo "Testing GET /me"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: me, expected 200, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: me"

echo "Testing PUT /password"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: password, expected 200, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: password"

echo "Testing PUT /password (old password invalid)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "wrong", "new_password": "newpassword123"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "FAIL: password invalid old, expected 401, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: password invalid old"

echo "Testing POST /todos"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "My Todo", "description": "Do this"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "201" ]; then echo "FAIL: create todo, expected 201, got $CODE, body: $BODY"; exit 1; fi
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "PASS: create todo (ID: $TODO_ID)"

echo "Testing POST /todos (empty title)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "", "description": "Do this"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "FAIL: create todo empty title, expected 400, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: create todo empty title"

echo "Testing GET /todos"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: get todos, expected 200, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: get todos"

echo "Testing GET /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: get todo, expected 200, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: get todo"

echo "Testing GET /todos/:id (not found)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/9999" -b cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "404" ]; then echo "FAIL: get todo not found, expected 404, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: get todo not found"

echo "Testing PUT /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: update todo, expected 200, got $CODE, body: $BODY"; exit 1; fi
if ! echo "$BODY" | grep -q '"completed":true'; then echo "FAIL: update todo body missing completed:true, body: $BODY"; exit 1; fi
echo "PASS: update todo"

echo "Testing PUT /todos/:id (empty title)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "FAIL: update todo empty title, expected 400, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: update todo empty title"

echo "Testing DELETE /todos/:id"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "204" ]; then echo "FAIL: delete todo, expected 204, got $CODE"; exit 1; fi
echo "PASS: delete todo"

echo "Testing DELETE /todos/:id (not found)"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "404" ]; then echo "FAIL: delete todo not found, expected 404, got $CODE"; exit 1; fi
echo "PASS: delete todo not found"

echo "Testing POST /logout"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: logout, expected 200, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: logout"

echo "Testing GET /me after logout"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "FAIL: me after logout, expected 401, got $CODE, body: $BODY"; exit 1; fi
echo "PASS: me after logout"

echo "=== ALL TESTS PASSED ==="
