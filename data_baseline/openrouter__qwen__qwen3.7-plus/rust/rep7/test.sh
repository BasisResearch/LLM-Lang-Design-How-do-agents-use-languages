#!/bin/bash
set -e

PORT=8888
cargo build --release
./target/release/todo_app --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt
}
trap cleanup EXIT

BASE_URL="http://localhost:$PORT"

echo "Testing /register..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
    echo "FAIL: /register expected 201, got $CODE. Body: $(echo "$RES" | head -n -1)"
    exit 1
fi
echo "PASS: /register"

echo "Testing /register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then
    echo "FAIL: /register duplicate expected 409, got $CODE"
    exit 1
fi
echo "PASS: /register duplicate"

echo "Testing /login..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /login expected 200, got $CODE"
    exit 1
fi
echo "PASS: /login"

echo "Testing /me..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /me expected 200, got $CODE"
    exit 1
fi
echo "PASS: /me"

echo "Testing /me without auth..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /me without auth expected 401, got $CODE"
    exit 1
fi
echo "PASS: /me without auth"

echo "Testing /password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /password expected 200, got $CODE"
    exit 1
fi
echo "PASS: /password"

echo "Testing /password wrong old..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /password wrong old expected 401, got $CODE"
    exit 1
fi
echo "PASS: /password wrong old"

echo "Testing POST /todos..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title": "My First Todo", "description": "This is a test"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
    echo "FAIL: POST /todos expected 201, got $CODE"
    exit 1
fi
TODO_ID=$(echo "$RES" | head -n -1 | sed -n 's/.*"id": *\([0-9]*\).*/\1/p')
echo "PASS: POST /todos (ID: $TODO_ID)"

echo "Testing GET /todos..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos expected 200, got $CODE"
    exit 1
fi
echo "PASS: GET /todos"

echo "Testing GET /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos/:id expected 200, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/:id"

echo "Testing GET /todos/:id not found..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/9999" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: GET /todos/:id not found expected 404, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/:id not found"

echo "Testing PUT /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -b cookies.txt -H "Content-Type: application/json" -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: PUT /todos/:id expected 200, got $CODE"
    exit 1
fi
echo "PASS: PUT /todos/:id"

echo "Testing DELETE /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then
    echo "FAIL: DELETE /todos/:id expected 204, got $CODE"
    exit 1
fi
echo "PASS: DELETE /todos/:id"

echo "Testing DELETE /todos/:id again (should be 404)..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: DELETE /todos/:id again expected 404, got $CODE"
    exit 1
fi
echo "PASS: DELETE /todos/:id again"

echo "Testing /logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /logout expected 200, got $CODE"
    exit 1
fi
echo "PASS: /logout"

echo "Testing /me after logout..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /me after logout expected 401, got $CODE"
    exit 1
fi
echo "PASS: /me after logout"

echo "ALL TESTS PASSED!"