#!/bin/bash
set -e

PORT=8765
BASE_URL="http://localhost:$PORT"

echo "Starting server..."
python3 server.py --port $PORT &
SERVER_PID=$!
sleep 2

_cleanup() {
    echo "Stopping server..."
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt
}
trap _cleanup EXIT

echo "Testing /register..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
BODY=$(echo "$RES" | head -n 1)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "201" ]; then
    echo "FAIL: /register expected 201, got $CODE. Body: $BODY"
    exit 1
fi
echo "PASS: /register"

echo "Testing /register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "409" ]; then
    echo "FAIL: /register duplicate expected 409, got $CODE"
    exit 1
fi
echo "PASS: /register duplicate"

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

echo "Testing /login..."
RES=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
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
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /me expected 200, got $CODE"
    exit 1
fi
echo "PASS: /me"

echo "Testing /me without auth..."
RES=$(curl -s -w "\n%{http_code}" "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /me without auth expected 401, got $CODE"
    exit 1
fi
echo "PASS: /me without auth"

echo "Testing /password..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /password expected 200, got $CODE"
    exit 1
fi
echo "PASS: /password"

echo "Testing /password invalid old..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "wrong", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /password invalid old expected 401, got $CODE"
    exit 1
fi
echo "PASS: /password invalid old"

echo "Testing /password short new..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: /password short new expected 400, got $CODE"
    exit 1
fi
echo "PASS: /password short new"

echo "Testing POST /todos..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Test desc"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "201" ]; then
    echo "FAIL: POST /todos expected 201, got $CODE"
    exit 1
fi
echo "PASS: POST /todos"

echo "Testing POST /todos missing title..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"description": "Test desc"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: POST /todos missing title expected 400, got $CODE"
    exit 1
fi
echo "PASS: POST /todos missing title"

echo "Testing GET /todos..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos expected 200, got $CODE"
    exit 1
fi
echo "PASS: GET /todos"

echo "Testing GET /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/1")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos/1 expected 200, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/1"

echo "Testing GET /todos/:id not found..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/999")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: GET /todos/999 expected 404, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/999"

echo "Testing PUT /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: PUT /todos/1 expected 200, got $CODE"
    exit 1
fi
echo "PASS: PUT /todos/1"

echo "Testing PUT /todos/:id empty title..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then
    echo "FAIL: PUT /todos/1 empty title expected 400, got $CODE"
    exit 1
fi
echo "PASS: PUT /todos/1 empty title"

echo "Testing DELETE /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/1")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "204" ]; then
    echo "FAIL: DELETE /todos/1 expected 204, got $CODE"
    exit 1
fi
echo "PASS: DELETE /todos/1"

echo "Testing DELETE /todos/:id not found..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/1")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: DELETE /todos/1 not found expected 404, got $CODE"
    exit 1
fi
echo "PASS: DELETE /todos/1 not found"

echo "Testing /logout..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/logout")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /logout expected 200, got $CODE"
    exit 1
fi
echo "PASS: /logout"

echo "Testing /me after logout..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /me after logout expected 401, got $CODE"
    exit 1
fi
echo "PASS: /me after logout"

echo "ALL TESTS PASSED!"
