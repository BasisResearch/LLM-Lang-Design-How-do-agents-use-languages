#!/bin/bash
set -e

echo "Starting server on port 8888..."
./run.sh --port 8888 > server.log 2>&1 &
SERVER_PID=$!

echo "Waiting for server to start..."
for i in {1..30}; do
  if curl -s http://localhost:8888/me > /dev/null 2>&1; then
    echo "Server is ready!"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "Server failed to start in time. Log:"
    cat server.log
    kill $SERVER_PID 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

BASE_URL="http://localhost:8888"
COOKIE_JAR=$(mktemp)

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  rm -f $COOKIE_JAR server.log
}
trap cleanup EXIT

echo "=== Testing Register ==="
# Test valid register
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | head -n -1)
if [ "$HTTP_CODE" != "201" ]; then
  echo "FAIL: Expected 201, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASS: Register success"

# Test invalid username (too short)
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: Expected 400, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Invalid username too short"

# Test invalid username (invalid chars)
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "test@user", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: Expected 400, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Invalid username chars"

# Test password too short
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "short"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: Expected 400, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Password too short"

# Test duplicate username
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "409" ]; then
  echo "FAIL: Expected 409, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Duplicate username"

echo "=== Testing Login ==="
# Test invalid credentials
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpassword"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "401" ]; then
  echo "FAIL: Expected 401, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Invalid credentials"

# Test valid login
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -c "$COOKIE_JAR" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | head -n -1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $HTTP_CODE. Body: $BODY"
  exit 1
fi
echo "PASS: Login success"

echo "=== Testing /me ==="
RES=$(curl -sS -w "\n%{http_code}" -X GET "$BASE_URL/me" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $HTTP_CODE"
  exit 1
fi
echo "PASS: /me success"

# Test /me without auth
RES=$(curl -sS -w "\n%{http_code}" -X GET "$BASE_URL/me")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "401" ]; then
  echo "FAIL: Expected 401, got $HTTP_CODE"
  exit 1
fi
echo "PASS: /me without auth returns 401"

echo "=== Testing PUT /password ==="
# Test old password mismatch
RES=$(curl -sS -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR" \
  -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "401" ]; then
  echo "FAIL: Expected 401, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Put password old password mismatch"

# Test new password too short
RES=$(curl -sS -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR" \
  -d '{"old_password": "password123", "new_password": "short"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: Expected 400, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Put password new password too short"

# Test valid password change
RES=$(curl -sS -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR" \
  -d '{"old_password": "password123", "new_password": "newpassword123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Put password success"

echo "=== Testing Todos ==="
# Test create todo
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR" \
  -d '{"title": "My first todo", "description": "Test description"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "201" ]; then
  echo "FAIL: Expected 201, got $HTTP_CODE"
  exit 1
fi
TODO_BODY=$(echo "$RES" | head -n -1)
TODO_ID=$(echo "$TODO_BODY" | sed -n 's/.*"id":\s*\([0-9]*\).*/\1/p')
echo "PASS: Create todo success (ID=$TODO_ID)"

# Test create todo with empty title
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR" \
  -d '{"title": "", "description": "Test description"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: Expected 400, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Create todo with empty title returns 400"

# Test get todos
RES=$(curl -sS -w "\n%{http_code}" -X GET "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Get todos success"

# Test get specific todo
RES=$(curl -sS -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Get specific todo success"

# Test update todo
RES=$(curl -sS -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR" \
  -d '{"title": "Updated title", "completed": true}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Update todo success"

# Test update todo with empty title
RES=$(curl -sS -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR" \
  -d '{"title": ""}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "400" ]; then
  echo "FAIL: Expected 400, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Update todo with empty title returns 400"

# Test get todo that doesn't exist
RES=$(curl -sS -w "\n%{http_code}" -X GET "$BASE_URL/todos/99999" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "404" ]; then
  echo "FAIL: Expected 404, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Get non-existent todo returns 404"

# Test delete todo
RES=$(curl -sS -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "204" ]; then
  echo "FAIL: Expected 204, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Delete todo success"

# Test delete non-existent todo
RES=$(curl -sS -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "404" ]; then
  echo "FAIL: Expected 404, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Delete non-existent todo returns 404"

echo "=== Testing Logout ==="
RES=$(curl -sS -w "\n%{http_code}" -X POST "$BASE_URL/logout" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $HTTP_CODE"
  exit 1
fi
echo "PASS: Logout success"

# Test /me after logout
RES=$(curl -sS -w "\n%{http_code}" -X GET "$BASE_URL/me" \
  -H "Content-Type: application/json" \
  -b "$COOKIE_JAR")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" != "401" ]; then
  echo "FAIL: Expected 401 after logout, got $HTTP_CODE"
  exit 1
fi
echo "PASS: /me after logout returns 401"

echo "=== ALL TESTS PASSED ==="