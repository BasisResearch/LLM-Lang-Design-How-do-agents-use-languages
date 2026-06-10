#!/bin/bash

PORT=8765
BASE_URL="http://localhost:$PORT"

# Start the server in background
./run.sh --port $PORT &
SERVER_PID=$!

# Function to cleanup
cleanup() {
  kill $SERVER_PID 2>/dev/null
  exit 1
}
trap cleanup EXIT

# Wait for server to start
sleep 2

echo "=== Testing Server on $PORT ==="

# Test 1: Register a new user
echo "Test 1: Register user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "201" ] && echo "$BODY" | grep -q '"username"'; then
  echo "PASS: Register user"
else
  echo "FAIL: Register user - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 2: Register with invalid username (too short)
echo "Test 2: Register invalid username"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "400" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Register invalid username"
else
  echo "FAIL: Register invalid username - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 3: Register with short password
echo "Test 3: Register short password"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "short"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "400" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Register short password"
else
  echo "FAIL: Register short password - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 4: Register existing username
echo "Test 4: Register existing username"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "409" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Register existing username"
else
  echo "FAIL: Register existing username - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 5: Login
echo "Test 5: Login"
RES=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "200" ] && echo "$BODY" | grep -q '"username"'; then
  echo "PASS: Login"
else
  echo "FAIL: Login - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 6: Login with invalid credentials
echo "Test 6: Login with invalid credentials"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpassword"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "401" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Login with invalid credentials"
else
  echo "FAIL: Login with invalid credentials - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 7: GET /me
echo "Test 7: GET /me"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$BASE_URL/me")
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "200" ] && echo "$BODY" | grep -q '"username"'; then
  echo "PASS: GET /me"
else
  echo "FAIL: GET /me - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 8: GET /me without auth
echo "Test 8: GET /me without auth"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "401" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: GET /me without auth"
else
  echo "FAIL: GET /me without auth - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 9: Change password
echo "Test 9: Change password"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" = "200" ]; then
  echo "PASS: Change password"
else
  echo "FAIL: Change password - HTTP $HTTP_CODE, Body: $RES"
  exit 1
fi

# Test 10: Change password with wrong old password
echo "Test 10: Change password with wrong old password"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "anotherpassword123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "401" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Change password with wrong old password"
else
  echo "FAIL: Change password with wrong old password - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 11: Change password with short new password
echo "Test 11: Change password with short new password"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -d '{"old_password": "newpassword123", "new_password": "short"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "400" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Change password with short new password"
else
  echo "FAIL: Change password with short new password - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 12: Create todo
echo "Test 12: Create todo"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -d '{"title": "My first todo", "description": "This is a test"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "201" ] && echo "$BODY" | grep -q '"title"' && echo "$BODY" | grep -q '"completed": false'; then
  echo "PASS: Create todo"
else
  echo "FAIL: Create todo - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 13: Create todo without title
echo "Test 13: Create todo without title"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -d '{"description": "No title"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "400" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Create todo without title"
else
  echo "FAIL: Create todo without title - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 14: Create todo with empty title
echo "Test 14: Create todo with empty title"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -d '{"title": "", "description": "Empty title"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "400" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Create todo with empty title"
else
  echo "FAIL: Create todo with empty title - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 15: Get todos
echo "Test 15: Get todos"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$BASE_URL/todos")
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "200" ] && echo "$BODY" | grep -q '"title"'; then
  echo "PASS: Get todos"
else
  echo "FAIL: Get todos - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 16: Get specific todo
echo "Test 16: Get specific todo"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$BASE_URL/todos/1")
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "200" ] && echo "$BODY" | grep -q '"title"'; then
  echo "PASS: Get specific todo"
else
  echo "FAIL: Get specific todo - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 17: Get specific todo that doesn't exist
echo "Test 17: Get specific todo that doesn't exist"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$BASE_URL/todos/999")
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "404" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Get specific todo that doesn't exist"
else
  echo "FAIL: Get specific todo that doesn't exist - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 18: Update todo
echo "Test 18: Update todo"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/1" \
  -H "Content-Type: application/json" \
  -d '{"completed": true, "description": "Updated description"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "200" ] && echo "$BODY" | grep -q '"completed": true' && echo "$BODY" | grep -q '"description": "Updated description"'; then
  echo "PASS: Update todo"
else
  echo "FAIL: Update todo - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 19: Update todo with empty title
echo "Test 19: Update todo with empty title"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/1" \
  -H "Content-Type: application/json" \
  -d '{"title": ""}')
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "400" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Update todo with empty title"
else
  echo "FAIL: Update todo with empty title - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 20: Delete todo
echo "Test 20: Delete todo"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/1")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" = "204" ]; then
  echo "PASS: Delete todo"
else
  echo "FAIL: Delete todo - HTTP $HTTP_CODE"
  exit 1
fi

# Test 21: Get deleted todo
echo "Test 21: Get deleted todo"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$BASE_URL/todos/1")
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "404" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: Get deleted todo"
else
  echo "FAIL: Get deleted todo - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 22: Logout
echo "Test 22: Logout"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/logout")
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" = "200" ]; then
  echo "PASS: Logout"
else
  echo "FAIL: Logout - HTTP $HTTP_CODE, Body: $RES"
  exit 1
fi

# Test 23: GET /me after logout
echo "Test 23: GET /me after logout"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$BASE_URL/me")
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "401" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: GET /me after logout"
else
  echo "FAIL: GET /me after logout - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

# Test 24: Create second user to test isolation
echo "Test 24: Create second user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "user2", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" = "201" ]; then
  echo "PASS: Create second user"
else
  echo "FAIL: Create second user - HTTP $HTTP_CODE"
  exit 1
fi

# Test 25: Second user logs in
echo "Test 25: Second user logs in"
RES=$(curl -s -w "\n%{http_code}" -c cookies2.txt -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "user2", "password": "password123"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" = "200" ]; then
  echo "PASS: Second user logs in"
else
  echo "FAIL: Second user logs in - HTTP $HTTP_CODE"
  exit 1
fi

# Test 26: Second user creates todo
echo "Test 26: Second user creates todo"
RES=$(curl -s -w "\n%{http_code}" -b cookies2.txt -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -d '{"title": "User 2 todo"}')
HTTP_CODE=$(echo "$RES" | tail -n1)
if [ "$HTTP_CODE" = "201" ]; then
  echo "PASS: Second user creates todo"
else
  echo "FAIL: Second user creates todo - HTTP $HTTP_CODE"
  exit 1
fi

# Test 27: First user tries to access second user's todo (should be 404)
echo "Test 27: First user tries to access second user's todo"
# Re-login first user
curl -s -c cookies.txt -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newpassword123"}' > /dev/null

RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET "$BASE_URL/todos/2")
HTTP_CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$HTTP_CODE" = "404" ] && echo "$BODY" | grep -q '"error"'; then
  echo "PASS: First user tries to access second user's todo"
else
  echo "FAIL: First user tries to access second user's todo - HTTP $HTTP_CODE, Body: $BODY"
  exit 1
fi

echo "=== All tests passed! ==="
rm -f cookies.txt cookies2.txt
trap - EXIT
kill $SERVER_PID 2>/dev/null
exit 0
