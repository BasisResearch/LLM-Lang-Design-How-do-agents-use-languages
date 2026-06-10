#!/bin/bash
set -e

PORT=8080

# Kill any existing server
pkill -f "scala-cli run Server.scala" || true
sleep 2

echo "Starting server in background..."
nohup scala-cli run Server.scala -- $PORT > /tmp/server.log 2>&1 &
SERVER_PID=$!
sleep 10

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE_URL="http://localhost:$PORT"

get_cookie() {
  echo "$1" | grep -i "set-cookie" | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r'
}

echo "Test 1: Register new user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ]; then
  echo "Test 1 FAILED: Expected 201, got $CODE. Body: $BODY"
  exit 1
fi
echo "Test 1 PASSED"

echo "Test 2: Register duplicate user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then
  echo "Test 2 FAILED: Expected 409, got $CODE"
  exit 1
fi
echo "Test 2 PASSED"

echo "Test 3: Login"
RES=$(curl -s -i -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
COOKIE=$(get_cookie "$RES")
CODE=$(echo "$RES" | grep -i "HTTP/" | tail -n1 | awk '{print $2}' | tr -d '\r')
if [ -z "$COOKIE" ] || [ "$CODE" != "200" ]; then
  echo "Test 3 FAILED: Expected 200 and Set-Cookie, got CODE=$CODE, COOKIE=$COOKIE"
  exit 1
fi
echo "Test 3 PASSED (Cookie: $COOKIE)"

echo "Test 4: GET /me (unauthorized)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "Test 4 FAILED: Expected 401, got $CODE"
  exit 1
fi
echo "Test 4 PASSED"

echo "Test 5: GET /me (authorized)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -H "Cookie: session_id=$COOKIE")
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ] || ! echo "$BODY" | grep -q '"username":"testuser"'; then
  echo "Test 5 FAILED: Expected 200 with username, got CODE=$CODE, BODY=$BODY"
  exit 1
fi
echo "Test 5 PASSED"

echo "Test 6: PUT /password"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "Test 6 FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "Test 6 PASSED"

echo "Test 7: Login with new password"
RES=$(curl -s -i -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}')
COOKIE2=$(get_cookie "$RES")
CODE=$(echo "$RES" | grep -i "HTTP/" | tail -n1 | awk '{print $2}' | tr -d '\r')
if [ -z "$COOKIE2" ] || [ "$CODE" != "200" ]; then
  echo "Test 7 FAILED: Expected 200 and Set-Cookie, got CODE=$CODE"
  exit 1
fi
echo "Test 7 PASSED"

echo "Test 8: POST /todos"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE2" -d '{"title": "Test Todo", "description": "This is a test"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ]; then
  echo "Test 8 FAILED: Expected 201, got $CODE. Body: $BODY"
  exit 1
fi
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)
echo "Test 8 PASSED (Todo ID: $TODO_ID)"

echo "Test 9: POST /todos with empty title"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE2" -d '{"title": "   ", "description": "This is a test"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "Test 9 FAILED: Expected 400, got $CODE"
  exit 1
fi
echo "Test 9 PASSED"

echo "Test 10: GET /todos"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -H "Cookie: session_id=$COOKIE2")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "Test 10 FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "Test 10 PASSED"

echo "Test 11: GET /todos/:id"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE2")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "Test 11 FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "Test 11 PASSED"

echo "Test 12: PUT /todos/:id"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE2" -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ] || ! echo "$BODY" | grep -q '"completed":true'; then
  echo "Test 12 FAILED: Expected 200 with completed=true, got CODE=$CODE, BODY=$BODY"
  exit 1
fi
echo "Test 12 PASSED"

echo "Test 13: PUT /todos/:id with empty title"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -H "Cookie: session_id=$COOKIE2" -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
  echo "Test 13 FAILED: Expected 400, got $CODE"
  exit 1
fi
echo "Test 13 PASSED"

echo "Test 14: DELETE /todos/:id"
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE2")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then
  echo "Test 14 FAILED: Expected 204, got $CODE"
  exit 1
fi
echo "Test 14 PASSED"

echo "Test 15: GET deleted /todos/:id"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE2")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
  echo "Test 15 FAILED: Expected 404, got $CODE"
  exit 1
fi
echo "Test 15 PASSED"

echo "Test 16: POST /logout"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -H "Cookie: session_id=$COOKIE2")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
  echo "Test 16 FAILED: Expected 200, got $CODE"
  exit 1
fi
echo "Test 16 PASSED"

echo "Test 17: GET /me after logout"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -H "Cookie: session_id=$COOKIE2")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
  echo "Test 17 FAILED: Expected 401, got $CODE"
  exit 1
fi
echo "Test 17 PASSED"

echo "All tests PASSED!"