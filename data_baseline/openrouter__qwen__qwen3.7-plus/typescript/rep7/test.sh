#!/bin/bash

PORT=$(( 3000 + RANDOM % 1000 ))
export PORT
echo "Starting server on port $PORT..."
npx tsx src/index.ts > server.log 2>&1 &
SERVER_PID=$!
sleep 2

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "FAIL: Server failed to start."
    cat server.log
    exit 1
fi

cleanup() {
    echo "Cleaning up server $SERVER_PID"
    kill -9 $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt server.log
}
trap cleanup EXIT

BASE_URL="http://127.0.0.1:$PORT"

echo "==== Testing /register ===="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
    echo "FAIL: Expected 201, got $CODE. Body: $(echo "$RES" | sed '$d')"
    exit 1
fi
echo "PASS: /register success"

RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: Expected 400 for short username, got $CODE"
    exit 1
fi
echo "PASS: /register invalid username"

RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: Expected 400 for short password, got $CODE"
    exit 1
fi
echo "PASS: /register short password"

RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then
    echo "FAIL: Expected 409 for existing username, got $CODE"
    exit 1
fi
echo "PASS: /register username exists"

echo "==== Testing /login ===="
RES=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Expected 200 for login, got $CODE"
    exit 1
fi
echo "PASS: /login success"

RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: Expected 401 for invalid credentials, got $CODE"
    exit 1
fi
echo "PASS: /login invalid credentials"

echo "==== Testing /me ===="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Expected 200 for /me, got $CODE"
    exit 1
fi
echo "PASS: /me success"

RES=$(curl -s -w "\n%{http_code}" "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: Expected 401 for /me without auth, got $CODE"
    exit 1
fi
echo "PASS: /me no auth"

echo "==== Testing /password ===="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Expected 200 for /password, got $CODE"
    exit 1
fi
echo "PASS: /password success"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: Expected 401 for invalid old password, got $CODE"
    exit 1
fi
echo "PASS: /password invalid old"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: Expected 400 for short new password, got $CODE"
    exit 1
fi
echo "PASS: /password short new"

echo "==== Testing /todos ===="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "Test Todo", "description": "This is a test"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
    echo "FAIL: Expected 201 for POST /todos, got $CODE"
    exit 1
fi
echo "PASS: POST /todos success"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"description": "No title"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: Expected 400 for missing title, got $CODE"
    exit 1
fi
echo "PASS: POST /todos missing title"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "", "description": "Empty title"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: Expected 400 for empty title, got $CODE"
    exit 1
fi
echo "PASS: POST /todos empty title"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Expected 200 for GET /todos, got $CODE"
    exit 1
fi
if ! echo "$RES" | grep -q '"title":"Test Todo"'; then
    echo "FAIL: Expected todo in GET /todos response"
    exit 1
fi
echo "PASS: GET /todos success"

echo "==== Testing /todos/:id ===="
RES=$(curl -s -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "Second Todo"}')
TODO2_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | cut -d':' -f2)
echo "Created todo ID: $TODO2_ID"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO2_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Expected 200 for GET /todos/:id, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/:id success"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/9999")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: Expected 404 for GET /todos/9999, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/9999 not found"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/$TODO2_ID" -H "Content-Type: application/json" -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Expected 200 for PUT /todos/:id, got $CODE"
    exit 1
fi
if ! echo "$RES" | grep -q '"completed":true'; then
    echo "FAIL: Expected completed:true in PUT /todos/:id response"
    exit 1
fi
echo "PASS: PUT /todos/:id success"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/$TODO2_ID" -H "Content-Type: application/json" -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: Expected 400 for PUT /todos/:id with empty title, got $CODE"
    exit 1
fi
echo "PASS: PUT /todos/:id empty title"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/$TODO2_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then
    echo "FAIL: Expected 204 for DELETE /todos/:id, got $CODE"
    exit 1
fi
echo "PASS: DELETE /todos/:id success"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO2_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: Expected 404 for deleted GET /todos/:id, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/:id deleted not found"

echo "==== Testing /logout ===="
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/logout")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Expected 200 for POST /logout, got $CODE"
    exit 1
fi
echo "PASS: POST /logout success"

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: Expected 401 for /me after logout, got $CODE"
    exit 1
fi
echo "PASS: /me after logout"

echo "==== ALL TESTS PASSED ===="
