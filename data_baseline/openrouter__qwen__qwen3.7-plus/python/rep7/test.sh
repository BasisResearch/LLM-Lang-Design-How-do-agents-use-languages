#!/bin/bash
set -e

PORT=8888
BASE_URL="http://localhost:$PORT"

# Start server in background
python3 server.py --port $PORT &
SERVER_PID=$!
sleep 2

# Function to cleanup
cleanup() {
    kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "Testing /register..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
BODY=$(echo "$RES" | head -n 1)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "201" ]; then
    echo "FAIL: /register expected 201, got $CODE. Body: $BODY"
    exit 1
fi
echo "PASS: /register"

echo "Testing /register invalid username..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: /register invalid username expected 400, got $CODE"
    exit 1
fi
echo "PASS: /register invalid username"

echo "Testing /register short password..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: /register short password expected 400, got $CODE"
    exit 1
fi
echo "PASS: /register short password"

echo "Testing /register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "409" ]; then
    echo "FAIL: /register duplicate expected 409, got $CODE"
    exit 1
fi
echo "PASS: /register duplicate"

echo "Testing /login..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /login expected 200, got $CODE"
    exit 1
fi
echo "PASS: /login"

echo "Testing /login invalid credentials..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /login invalid credentials expected 401, got $CODE"
    exit 1
fi
echo "PASS: /login invalid credentials"

echo "Testing /me..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /me expected 200, got $CODE"
    exit 1
fi
echo "PASS: /me"

echo "Testing /me without auth..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /me without auth expected 401, got $CODE"
    exit 1
fi
echo "PASS: /me without auth"

echo "Testing PUT /password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: PUT /password expected 200, got $CODE"
    exit 1
fi
echo "PASS: PUT /password"

echo "Testing PUT /password wrong old password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "wrong", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: PUT /password wrong old password expected 401, got $CODE"
    exit 1
fi
echo "PASS: PUT /password wrong old password"

echo "Testing PUT /password short new password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: PUT /password short new password expected 400, got $CODE"
    exit 1
fi
echo "PASS: PUT /password short new password"

echo "Testing POST /todos..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "My Todo", "description": "Do this"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "201" ]; then
    echo "FAIL: POST /todos expected 201, got $CODE"
    exit 1
fi
echo "PASS: POST /todos"

echo "Testing POST /todos missing title..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description": "Do this"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: POST /todos missing title expected 400, got $CODE"
    exit 1
fi
echo "PASS: POST /todos missing title"

echo "Testing GET /todos..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos expected 200, got $CODE"
    exit 1
fi
echo "PASS: GET /todos"

echo "Testing GET /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/1" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos/:id expected 200, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/:id"

echo "Testing GET /todos/:id not found..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/999" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: GET /todos/:id not found expected 404, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/:id not found"

echo "Testing PUT /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: PUT /todos/:id expected 200, got $CODE"
    exit 1
fi
echo "PASS: PUT /todos/:id"

echo "Testing PUT /todos/:id empty title..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: PUT /todos/:id empty title expected 400, got $CODE"
    exit 1
fi
echo "PASS: PUT /todos/:id empty title"

echo "Testing DELETE /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/1" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "204" ]; then
    echo "FAIL: DELETE /todos/:id expected 204, got $CODE"
    exit 1
fi
echo "PASS: DELETE /todos/:id"

echo "Testing DELETE /todos/:id not found..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/1" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: DELETE /todos/:id not found expected 404, got $CODE"
    exit 1
fi
echo "PASS: DELETE /todos/:id not found"

echo "Testing /logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /logout expected 200, got $CODE"
    exit 1
fi
echo "PASS: /logout"

echo "Testing /me after logout..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /me after logout expected 401, got $CODE"
    exit 1
fi
echo "PASS: /me after logout"

# Test ID enumeration prevention (another user's todo)
echo "Testing ID enumeration prevention..."
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "otheruser", "password": "password123"}' > /dev/null
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "otheruser", "password": "password123"}' -c cookies3.txt > /dev/null
curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies3.txt -d '{"title": "Other User Todo"}' > /dev/null

curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' -c cookies2.txt > /dev/null

RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/2" -b cookies2.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: ID enumeration prevention GET expected 404, got $CODE"
    exit 1
fi
echo "PASS: ID enumeration prevention GET"

RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/2" -H "Content-Type: application/json" -b cookies2.txt -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: ID enumeration prevention PUT expected 404, got $CODE"
    exit 1
fi
echo "PASS: ID enumeration prevention PUT"

RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/2" -b cookies2.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: ID enumeration prevention DELETE expected 404, got $CODE"
    exit 1
fi
echo "PASS: ID enumeration prevention DELETE"

echo "All tests passed!"
