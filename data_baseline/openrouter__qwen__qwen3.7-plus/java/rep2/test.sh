#!/bin/bash
set -e

PORT=8888
BASE_URL="http://localhost:$PORT"

# Start server in background
./run.sh --port $PORT > /dev/null 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt /tmp/curl_code /tmp/curl_body
    exit 1
}
trap cleanup EXIT

curl_req() {
    local response
    response=$(curl -s -w "%{http_code}" "$@")
    local code="${response: -3}"
    local body="${response%???}"
    echo "$code" > /tmp/curl_code
    echo "$body" > /tmp/curl_body
}

echo "Testing POST /register..."
curl_req -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}'
CODE=$(cat /tmp/curl_code)
BODY=$(cat /tmp/curl_body)
if [ "$CODE" != "201" ]; then echo "FAIL: register expected 201, got $CODE. Body: $BODY"; exit 1; fi
echo "PASS: register"

echo "Testing POST /register with invalid username..."
curl_req -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}'
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "400" ]; then echo "FAIL: invalid username expected 400, got $CODE"; exit 1; fi
echo "PASS: invalid username"

echo "Testing POST /register with short password..."
curl_req -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}'
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "400" ]; then echo "FAIL: short password expected 400, got $CODE"; exit 1; fi
echo "PASS: short password"

echo "Testing POST /register duplicate..."
curl_req -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}'
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "409" ]; then echo "FAIL: duplicate expected 409, got $CODE"; exit 1; fi
echo "PASS: duplicate"

echo "Testing POST /login..."
curl_req -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "200" ]; then echo "FAIL: login expected 200, got $CODE"; exit 1; fi
echo "PASS: login"

echo "Testing POST /login invalid..."
curl_req -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrong"}'
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "401" ]; then echo "FAIL: invalid login expected 401, got $CODE"; exit 1; fi
echo "PASS: invalid login"

echo "Testing GET /me..."
curl_req -X GET "$BASE_URL/me" -b cookies.txt
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "200" ]; then echo "FAIL: me expected 200, got $CODE"; exit 1; fi
echo "PASS: me"

echo "Testing GET /me without auth..."
curl_req -X GET "$BASE_URL/me"
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "401" ]; then echo "FAIL: unauth me expected 401, got $CODE"; exit 1; fi
echo "PASS: unauth me"

echo "Testing PUT /password..."
curl_req -X PUT "$BASE_URL/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}'
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "200" ]; then echo "FAIL: password change expected 200, got $CODE"; exit 1; fi
echo "PASS: password change"

echo "Testing POST /todos..."
curl_req -X POST "$BASE_URL/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Do this"}'
CODE=$(cat /tmp/curl_code)
BODY=$(cat /tmp/curl_body)
if [ "$CODE" != "201" ]; then echo "FAIL: create todo expected 201, got $CODE. Body: $BODY"; exit 1; fi
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "PASS: create todo (ID: $TODO_ID)"

echo "Testing GET /todos..."
curl_req -X GET "$BASE_URL/todos" -b cookies.txt
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "200" ]; then echo "FAIL: get todos expected 200, got $CODE"; exit 1; fi
echo "PASS: get todos"

echo "Testing GET /todos/:id..."
curl_req -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "200" ]; then echo "FAIL: get todo expected 200, got $CODE"; exit 1; fi
echo "PASS: get todo"

echo "Testing PUT /todos/:id..."
curl_req -X PUT "$BASE_URL/todos/$TODO_ID" -b cookies.txt -H "Content-Type: application/json" -d '{"completed": true}'
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "200" ]; then echo "FAIL: update todo expected 200, got $CODE"; exit 1; fi
echo "PASS: update todo"

echo "Testing PUT /todos/:id empty title..."
curl_req -X PUT "$BASE_URL/todos/$TODO_ID" -b cookies.txt -H "Content-Type: application/json" -d '{"title": ""}'
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "400" ]; then echo "FAIL: empty title expected 400, got $CODE"; exit 1; fi
echo "PASS: empty title"

echo "Testing DELETE /todos/:id..."
curl_req -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "204" ]; then echo "FAIL: delete todo expected 204, got $CODE"; exit 1; fi
echo "PASS: delete todo"

echo "Testing DELETE /todos/:id not found..."
curl_req -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "404" ]; then echo "FAIL: delete not found expected 404, got $CODE"; exit 1; fi
echo "PASS: delete not found"

echo "Testing POST /logout..."
curl_req -X POST "$BASE_URL/logout" -b cookies.txt
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "200" ]; then echo "FAIL: logout expected 200, got $CODE"; exit 1; fi
echo "PASS: logout"

echo "Testing GET /me after logout..."
curl_req -X GET "$BASE_URL/me" -b cookies.txt
CODE=$(cat /tmp/curl_code)
if [ "$CODE" != "401" ]; then echo "FAIL: me after logout expected 401, got $CODE"; exit 1; fi
echo "PASS: me after logout"

echo "ALL TESTS PASSED!"
trap - EXIT
kill $SERVER_PID 2>/dev/null || true
rm -f cookies.txt /tmp/curl_code /tmp/curl_body