#!/bin/bash

set -e

PORT=8766
BASE_URL="http://localhost:$PORT"

echo "Starting server on port $PORT..."
python3 server.py --port $PORT &
SERVER_PID=$!
sleep 1

cleanup() {
  echo "Stopping server..."
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Test 1: Register user 1 ==="
RESP=$(curl -sS -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser1", "password":"password123"}' "$BASE_URL/register")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "201" ]; then
  echo "FAIL: Register user 1"
  exit 1
fi

echo "=== Test 2: Register duplicate user (should be 409) ==="
RESP=$(curl -sS -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser1", "password":"password123"}' "$BASE_URL/register")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "409" ]; then
  echo "FAIL: Register duplicate user"
  exit 1
fi

echo "=== Test 3: Register with short password (should be 400) ==="
RESP=$(curl -sS -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser2", "password":"short"}' "$BASE_URL/register")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: Register with short password"
  exit 1
fi

echo "=== Test 4: Register with invalid username (should be 400) ==="
RESP=$(curl -sS -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"invalid-user!", "password":"password123"}' "$BASE_URL/register")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: Register with invalid username"
  exit 1
fi

echo "=== Test 5: Login user 1 ==="
RESP=$(curl -sS -w "\n%{http_code}" -c cookies1.txt -X POST -H "Content-Type: application/json" -d '{"username":"testuser1", "password":"password123"}' "$BASE_URL/login")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: Login user 1"
  exit 1
fi
COOKIE1=$(grep 'session_id' cookies1.txt | awk '{print $7}')
echo "Got COOKIE1: $COOKIE1"

echo "=== Test 6: GET /me ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" "$BASE_URL/me")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "200" ] || ! echo "$BODY" | grep -q '"username": "testuser1"'; then
  echo "FAIL: GET /me"
  exit 1
fi

echo "=== Test 7: GET /me without auth (should be 401) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=invalid" "$BASE_URL/me")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "401" ]; then
  echo "FAIL: GET /me without auth"
  exit 1
fi

echo "=== Test 8: Create Todo 1 ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X POST -H "Content-Type: application/json" -d '{"title":"Buy groceries", "description":"Milk, eggs, bread"}' "$BASE_URL/todos")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "201" ] || ! echo "$BODY" | grep -q '"title": "Buy groceries"'; then
  echo "FAIL: Create Todo 1"
  exit 1
fi

echo "=== Test 9: Create Todo 2 (missing description, defaults to empty) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X POST -H "Content-Type: application/json" -d '{"title":"Walk the dog"}' "$BASE_URL/todos")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "201" ] || ! echo "$BODY" | grep -q '"title": "Walk the dog"'; then
  echo "FAIL: Create Todo 2"
  exit 1
fi

echo "=== Test 10: Create Todo 3 (missing title, should be 400) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X POST -H "Content-Type: application/json" -d '{"description":"Missing title"}' "$BASE_URL/todos")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: Create Todo without title"
  exit 1
fi

echo "=== Test 11: GET /todos ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" "$BASE_URL/todos")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "200" ] || ! echo "$BODY" | grep -q '"title": "Buy groceries"'; then
  echo "FAIL: GET /todos"
  exit 1
fi

echo "=== Test 12: PUT /todos/1 (update completed and title) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X PUT -H "Content-Type: application/json" -d '{"completed": true, "title": "Buy groceries (updated)"}' "$BASE_URL/todos/1")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "200" ] || ! echo "$BODY" | grep -q '"completed": true'; then
  echo "FAIL: PUT /todos/1"
  exit 1
fi

echo "=== Test 13: PUT /todos/1 with empty title (should be 400) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X PUT -H "Content-Type: application/json" -d '{"title": ""}' "$BASE_URL/todos/1")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: PUT /todos/1 with empty title"
  exit 1
fi

echo "=== Test 14: GET /todos/999 (should be 404) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" "$BASE_URL/todos/999")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "404" ]; then
  echo "FAIL: GET /todos/999"
  exit 1
fi

echo "=== Test 15: Register user 2 and login ==="
curl -sS -c cookies2.txt -X POST -H "Content-Type: application/json" -d '{"username":"testuser2", "password":"password123"}' "$BASE_URL/register" > /dev/null
RESP=$(curl -sS -w "\n%{http_code}" -c cookies2_login.txt -X POST -H "Content-Type: application/json" -d '{"username":"testuser2", "password":"password123"}' "$BASE_URL/login")
echo "Login user 2 HTTP: $(echo "$RESP" | tail -n1), Body: $(echo "$RESP" | head -n -1)"
COOKIE2=$(grep 'session_id' cookies2_login.txt | awk '{print $7}')
echo "Got COOKIE2: $COOKIE2"

echo "=== Test 16: User 2 GET /todos/1 (should be 404, not 403) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE2" "$BASE_URL/todos/1")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "404" ]; then
  echo "FAIL: User 2 GET /todos/1 (should be 404)"
  exit 1
fi

echo "=== Test 17: User 2 PUT /todos/1 (should be 404) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE2" -X PUT -H "Content-Type: application/json" -d '{"completed": false}' "$BASE_URL/todos/1")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "404" ]; then
  echo "FAIL: User 2 PUT /todos/1 (should be 404)"
  exit 1
fi

echo "=== Test 18: User 2 DELETE /todos/1 (should be 404) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE2" -X DELETE "$BASE_URL/todos/1")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "404" ]; then
  echo "FAIL: User 2 DELETE /todos/1 (should be 404)"
  exit 1
fi

echo "=== Test 19: DELETE /todos/2 ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X DELETE "$BASE_URL/todos/2")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "204" ]; then
  echo "FAIL: DELETE /todos/2 (should be 204)"
  exit 1
fi

echo "=== Test 20: PUT /password ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X PUT -H "Content-Type: application/json" -d '{"old_password":"password123", "new_password":"newpassword123"}' "$BASE_URL/password")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: PUT /password"
  exit 1
fi

echo "=== Test 21: Login with new password ==="
RESP=$(curl -sS -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser1", "password":"newpassword123"}' "$BASE_URL/login")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: Login with new password"
  exit 1
fi

echo "=== Test 22: Login with old password (should be 401) ==="
RESP=$(curl -sS -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser1", "password":"password123"}' "$BASE_URL/login")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "401" ]; then
  echo "FAIL: Login with old password should fail"
  exit 1
fi

echo "=== Test 23: PUT /password with wrong old password (should be 401) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X PUT -H "Content-Type: application/json" -d '{"old_password":"wrongpassword", "new_password":"newpassword123"}' "$BASE_URL/password")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "401" ]; then
  echo "FAIL: PUT /password with wrong old password"
  exit 1
fi

echo "=== Test 24: PUT /password with short new password (should be 400) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X PUT -H "Content-Type: application/json" -d '{"old_password":"newpassword123", "new_password":"short"}' "$BASE_URL/password")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: PUT /password with short new password"
  exit 1
fi

echo "=== Test 25: POST /logout ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" -X POST "$BASE_URL/logout")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: POST /logout"
  exit 1
fi

echo "=== Test 26: GET /me after logout (should be 401) ==="
RESP=$(curl -sS -w "\n%{http_code}" -b "session_id=$COOKIE1" "$BASE_URL/me")
HTTP_CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | head -n -1)
echo "HTTP: $HTTP_CODE, Body: $BODY"
if [ "$HTTP_CODE" != "401" ]; then
  echo "FAIL: GET /me after logout"
  exit 1
fi

# Clean up test files
rm -f cookies1.txt cookies2.txt cookies2_login.txt

echo -e "\n✅ All tests passed!"