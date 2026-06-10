#!/bin/bash

set -e

PORT=8765

# Start the server in the background
./server --port $PORT &
SERVER_PID=$!
sleep 1

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    exit 1
}
trap cleanup EXIT
trap 'kill $SERVER_PID 2>/dev/null || true; exit 0' INT TERM

CURL="curl -s -o /tmp/resp_body.txt -w '%{http_code}' -c cookies.txt -b cookies.txt"

echo "Testing /register..."
CODE=$($CURL -X POST http://127.0.0.1:$PORT/register -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
BODY=$(cat /tmp/resp_body.txt)
if [ "$CODE" != "201" ]; then
    echo "FAIL: /register expected 201, got $CODE"
    echo "Body: $BODY"
    exit 1
fi
if ! echo "$BODY" | grep -q '"username":"testuser"'; then
    echo "FAIL: /register body incorrect"
    echo "$BODY"
    exit 1
fi
echo "PASS: /register"

echo "Testing /register duplicate..."
CODE=$($CURL -X POST http://127.0.0.1:$PORT/register -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
BODY=$(cat /tmp/resp_body.txt)
if [ "$CODE" != "409" ]; then
    echo "FAIL: /register duplicate expected 409, got $CODE"
    echo "Body: $BODY"
    exit 1
fi
if ! echo "$BODY" | grep -q '"error":"Username already exists"'; then
    echo "FAIL: /register duplicate body incorrect"
    echo "$BODY"
    exit 1
fi
echo "PASS: /register duplicate"

echo "Testing /register invalid username..."
CODE=$($CURL -X POST http://127.0.0.1:$PORT/register -H "Content-Type: application/json" -d '{"username":"ab","password":"password12"}')
if [ "$CODE" != "400" ]; then
    echo "FAIL: /register invalid username expected 400, got $CODE"
    exit 1
fi
echo "PASS: /register invalid username"

echo "Testing /register short password..."
CODE=$($CURL -X POST http://127.0.0.1:$PORT/register -H "Content-Type: application/json" -d '{"username":"testuser2","password":"short"}')
if [ "$CODE" != "400" ]; then
    echo "FAIL: /register short password expected 400, got $CODE"
    exit 1
fi
echo "PASS: /register short password"

echo "Testing /login..."
> cookies.txt
CODE=$($CURL -X POST http://127.0.0.1:$PORT/login -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
BODY=$(cat /tmp/resp_body.txt)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /login expected 200, got $CODE"
    echo "Body: $BODY"
    exit 1
fi
if ! grep -q "session_id=" cookies.txt; then
    echo "FAIL: /login missing session_id cookie"
    exit 1
fi
echo "PASS: /login"

echo "Testing /login invalid..."
> cookies.txt
CODE=$($CURL -X POST http://127.0.0.1:$PORT/login -H "Content-Type: application/json" -d '{"username":"testuser","password":"wrongpassword"}')
if [ "$CODE" != "401" ]; then
    echo "FAIL: /login invalid expected 401, got $CODE"
    exit 1
fi
echo "PASS: /login invalid"

echo "Testing /me..."
CODE=$($CURL -X GET http://127.0.0.1:$PORT/me)
BODY=$(cat /tmp/resp_body.txt)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /me expected 200, got $CODE"
    exit 1
fi
if ! echo "$BODY" | grep -q '"username":"testuser"'; then
    echo "FAIL: /me body incorrect"
    echo "$BODY"
    exit 1
fi
echo "PASS: /me"

echo "Testing /me unauthenticated..."
> cookies.txt
CODE=$($CURL -X GET http://127.0.0.1:$PORT/me)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /me unauthenticated expected 401, got $CODE"
    exit 1
fi
echo "PASS: /me unauthenticated"

echo "Testing /password..."
CODE=$($CURL -X PUT http://127.0.0.1:$PORT/password -H "Content-Type: application/json" -d '{"old_password":"password123","new_password":"newpassword123"}')
if [ "$CODE" != "200" ]; then
    echo "FAIL: /password expected 200, got $CODE"
    exit 1
fi
echo "PASS: /password"

echo "Testing /password invalid old..."
CODE=$($CURL -X PUT http://127.0.0.1:$PORT/password -H "Content-Type: application/json" -d '{"old_password":"wrong","new_password":"newpassword123"}')
if [ "$CODE" != "401" ]; then
    echo "FAIL: /password invalid old expected 401, got $CODE"
    exit 1
fi
echo "PASS: /password invalid old"

echo "Testing /password short new..."
CODE=$($CURL -X PUT http://127.0.0.1:$PORT/password -H "Content-Type: application/json" -d '{"old_password":"newpassword123","new_password":"short"}')
if [ "$CODE" != "400" ]; then
    echo "FAIL: /password short new expected 400, got $CODE"
    exit 1
fi
echo "PASS: /password short new"

echo "Re-login after password change..."
> cookies.txt
CODE=$($CURL -X POST http://127.0.0.1:$PORT/login -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}')
if [ "$CODE" != "200" ]; then
    echo "FAIL: re-login expected 200, got $CODE"
    exit 1
fi
echo "PASS: re-login"

echo "Testing POST /todos..."
CODE=$($CURL -X POST http://127.0.0.1:$PORT/todos -H "Content-Type: application/json" -d '{"title":"My First Todo","description":"This is a description"}')
BODY=$(cat /tmp/resp_body.txt)
if [ "$CODE" != "201" ]; then
    echo "FAIL: POST /todos expected 201, got $CODE"
    exit 1
fi
if ! echo "$BODY" | grep -q '"title":"My First Todo"'; then
    echo "FAIL: POST /todos body incorrect"
    echo "$BODY"
    exit 1
fi
echo "PASS: POST /todos"

echo "Testing POST /todos missing title..."
CODE=$($CURL -X POST http://127.0.0.1:$PORT/todos -H "Content-Type: application/json" -d '{"description":"No title"}')
if [ "$CODE" != "400" ]; then
    echo "FAIL: POST /todos missing title expected 400, got $CODE"
    exit 1
fi
echo "PASS: POST /todos missing title"

echo "Testing POST /todos empty title..."
CODE=$($CURL -X POST http://127.0.0.1:$PORT/todos -H "Content-Type: application/json" -d '{"title":""}')
if [ "$CODE" != "400" ]; then
    echo "FAIL: POST /todos empty title expected 400, got $CODE"
    exit 1
fi
echo "PASS: POST /todos empty title"

echo "Testing GET /todos..."
CODE=$($CURL -X GET http://127.0.0.1:$PORT/todos)
BODY=$(cat /tmp/resp_body.txt)
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos expected 200, got $CODE"
    exit 1
fi
if ! echo "$BODY" | grep -q '"title":"My First Todo"'; then
    echo "FAIL: GET /todos body incorrect"
    echo "$BODY"
    exit 1
fi
echo "PASS: GET /todos"

echo "Testing GET /todos/:id..."
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | head -n1 | grep -o '[0-9]*')
CODE=$($CURL -X GET http://127.0.0.1:$PORT/todos/$TODO_ID)
BODY=$(cat /tmp/resp_body.txt)
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos/:id expected 200, got $CODE"
    exit 1
fi
if ! echo "$BODY" | grep -q '"id":'$TODO_ID; then
    echo "FAIL: GET /todos/:id body incorrect"
    echo "$BODY"
    exit 1
fi
echo "PASS: GET /todos/:id"

echo "Testing GET /todos/:id not found..."
CODE=$($CURL -X GET http://127.0.0.1:$PORT/todos/99999)
if [ "$CODE" != "404" ]; then
    echo "FAIL: GET /todos/:id not found expected 404, got $CODE"
    exit 1
fi
echo "PASS: GET /todos/:id not found"

echo "Testing PUT /todos/:id..."
CODE=$($CURL -X PUT http://127.0.0.1:$PORT/todos/$TODO_ID -H "Content-Type: application/json" -d '{"title":"Updated Title","completed":true}')
BODY=$(cat /tmp/resp_body.txt)
if [ "$CODE" != "200" ]; then
    echo "FAIL: PUT /todos/:id expected 200, got $CODE"
    exit 1
fi
if ! echo "$BODY" | grep -q '"title":"Updated Title"'; then
    echo "FAIL: PUT /todos/:id body incorrect"
    echo "$BODY"
    exit 1
fi
if ! echo "$BODY" | grep -q '"completed":true'; then
    echo "FAIL: PUT /todos/:id completed incorrect"
    echo "$BODY"
    exit 1
fi
echo "PASS: PUT /todos/:id"

echo "Testing PUT /todos/:id empty title..."
CODE=$($CURL -X PUT http://127.0.0.1:$PORT/todos/$TODO_ID -H "Content-Type: application/json" -d '{"title":""}')
if [ "$CODE" != "400" ]; then
    echo "FAIL: PUT /todos/:id empty title expected 400, got $CODE"
    exit 1
fi
echo "PASS: PUT /todos/:id empty title"

echo "Testing DELETE /todos/:id..."
CODE=$($CURL -X DELETE http://127.0.0.1:$PORT/todos/$TODO_ID)
if [ "$CODE" != "204" ]; then
    echo "FAIL: DELETE /todos/:id expected 204, got $CODE"
    exit 1
fi
echo "PASS: DELETE /todos/:id"

echo "Testing DELETE /todos/:id not found (after delete)..."
CODE=$($CURL -X DELETE http://127.0.0.1:$PORT/todos/$TODO_ID)
if [ "$CODE" != "404" ]; then
    echo "FAIL: DELETE /todos/:id not found expected 404, got $CODE"
    exit 1
fi
echo "PASS: DELETE /todos/:id not found"

echo "Testing /logout..."
CODE=$($CURL -X POST http://127.0.0.1:$PORT/logout)
if [ "$CODE" != "200" ]; then
    echo "FAIL: /logout expected 200, got $CODE"
    exit 1
fi
echo "PASS: /logout"

echo "Testing /me after logout..."
CODE=$($CURL -X GET http://127.0.0.1:$PORT/me)
if [ "$CODE" != "401" ]; then
    echo "FAIL: /me after logout expected 401, got $CODE"
    exit 1
fi
echo "PASS: /me after logout"

echo "Testing ID enumeration prevention (other user's todo)..."
# Create second user
> cookies.txt
$CURL -X POST http://127.0.0.1:$PORT/register -H "Content-Type: application/json" -d '{"username":"user2","password":"password123"}'
$CURL -X POST http://127.0.0.1:$PORT/login -H "Content-Type: application/json" -d '{"username":"user2","password":"password123"}'

# user2 tries to access todo 1 (belongs to testuser)
CODE=$($CURL -X GET http://127.0.0.1:$PORT/todos/1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: ID enumeration prevention expected 404, got $CODE"
    exit 1
fi
echo "PASS: ID enumeration prevention"

echo ""
echo "========================================="
echo "ALL TESTS PASSED!"
echo "========================================="

# Clean up trap and exit normally
trap - EXIT
kill $SERVER_PID 2>/dev/null || true
exit 0
