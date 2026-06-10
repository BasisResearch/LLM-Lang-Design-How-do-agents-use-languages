#!/bin/bash

# Start server in background
./run.sh --port 8888 &
SERVER_PID=$!
sleep 3

# Helper function for curl
curl_json() {
    curl -s -w "\nHTTP_CODE:%{http_code}" "$@"
}

echo "Testing POST /register..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST http://localhost:8888/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESP" | sed '/HTTP_CODE:/d')
if [ "$HTTP_CODE" != "201" ]; then
    echo "FAIL: POST /register expected 201, got $HTTP_CODE. Body: $BODY"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: POST /register"

echo "Testing POST /register with duplicate username..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST http://localhost:8888/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "409" ]; then
    echo "FAIL: POST /register duplicate expected 409, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: POST /register duplicate"

echo "Testing POST /login..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST http://localhost:8888/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
BODY=$(echo "$RESP" | sed '/HTTP_CODE:/d')
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAIL: POST /login expected 200, got $HTTP_CODE. Body: $BODY"
    kill $SERVER_PID
    exit 1
fi
COOKIE=$(echo "$RESP" | grep -i "set-cookie" | sed 's/.*session_id=\([^;]*\).*/\1/')
echo "Got session cookie: $COOKIE"

echo "Testing GET /me..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X GET http://localhost:8888/me \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$COOKIE")
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAIL: GET /me expected 200, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: GET /me"

echo "Testing POST /todos..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST http://localhost:8888/todos \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$COOKIE" \
  -d '{"title": "My Todo", "description": "Do this"}')
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "201" ]; then
    echo "FAIL: POST /todos expected 201, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
TODO_ID=$(echo "$RESP" | sed '/HTTP_CODE:/d' | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "Created todo with ID: $TODO_ID"

echo "Testing GET /todos..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X GET http://localhost:8888/todos \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$COOKIE")
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAIL: GET /todos expected 200, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: GET /todos"

echo "Testing GET /todos/:id..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X GET http://localhost:8888/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$COOKIE")
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAIL: GET /todos/:id expected 200, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: GET /todos/:id"

echo "Testing PUT /todos/:id..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT http://localhost:8888/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$COOKIE" \
  -d '{"completed": true, "title": "Updated Todo"}')
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAIL: PUT /todos/:id expected 200, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: PUT /todos/:id"

echo "Testing PUT /password..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X PUT http://localhost:8888/password \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$COOKIE" \
  -d '{"old_password": "password123", "new_password": "newpassword123"}')
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAIL: PUT /password expected 200, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: PUT /password"

echo "Testing DELETE /todos/:id..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X DELETE http://localhost:8888/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$COOKIE")
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "204" ]; then
    echo "FAIL: DELETE /todos/:id expected 204, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: DELETE /todos/:id"

echo "Testing POST /logout..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST http://localhost:8888/logout \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$COOKIE")
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "200" ]; then
    echo "FAIL: POST /logout expected 200, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: POST /logout"

echo "Testing GET /me after logout (should be 401)..."
RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X GET http://localhost:8888/me \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$COOKIE")
HTTP_CODE=$(echo "$RESP" | grep "HTTP_CODE:" | cut -d: -f2)
if [ "$HTTP_CODE" != "401" ]; then
    echo "FAIL: GET /me after logout expected 401, got $HTTP_CODE"
    kill $SERVER_PID
    exit 1
fi
echo "PASS: GET /me after logout"

kill $SERVER_PID
echo "All tests passed!"