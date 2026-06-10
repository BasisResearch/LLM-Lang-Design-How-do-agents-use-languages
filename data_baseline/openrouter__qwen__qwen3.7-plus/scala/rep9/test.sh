#!/bin/bash

BASE_URL="http://localhost:8080"
COOKIE_JAR="cookies.txt"

# Clean up cookie jar
> $COOKIE_JAR

echo "=== Testing POST /register ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
echo "$RES"
if ! echo "$RES" | grep -q "201$"; then
  echo "FAIL: Register did not return 201"
  exit 1
fi

echo ""
echo "=== Testing POST /register (duplicate) ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
echo "$RES"
if ! echo "$RES" | grep -q "409$"; then
  echo "FAIL: Duplicate register did not return 409"
  exit 1
fi

echo ""
echo "=== Testing POST /register (invalid username) ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
echo "$RES"
if ! echo "$RES" | grep -q "400$"; then
  echo "FAIL: Invalid username did not return 400"
  exit 1
fi

echo ""
echo "=== Testing POST /register (short password) ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "short"}')
echo "$RES"
if ! echo "$RES" | grep -q "400$"; then
  echo "FAIL: Short password did not return 400"
  exit 1
fi

echo ""
echo "=== Testing POST /login ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -c $COOKIE_JAR \
  -d '{"username": "testuser", "password": "password123"}')
echo "$RES"
if ! echo "$RES" | grep -q "200$"; then
  echo "FAIL: Login did not return 200"
  exit 1
fi

echo ""
echo "=== Testing POST /login (invalid credentials) ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpassword"}')
echo "$RES"
if ! echo "$RES" | grep -q "401$"; then
  echo "FAIL: Invalid credentials did not return 401"
  exit 1
fi

echo ""
echo "=== Testing GET /me ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" \
  -b $COOKIE_JAR)
echo "$RES"
if ! echo "$RES" | grep -q "200$"; then
  echo "FAIL: GET /me did not return 200"
  exit 1
fi

echo ""
echo "=== Testing GET /me (no auth) ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
echo "$RES"
if ! echo "$RES" | grep -q "401$"; then
  echo "FAIL: GET /me without auth did not return 401"
  exit 1
fi

echo ""
echo "=== Testing PUT /password ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -b $COOKIE_JAR \
  -d '{"old_password": "password123", "new_password": "newpassword123"}')
echo "$RES"
if ! echo "$RES" | grep -q "200$"; then
  echo "FAIL: PUT /password did not return 200"
  exit 1
fi

echo ""
echo "=== Testing POST /todos ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b $COOKIE_JAR \
  -d '{"title": "My first todo", "description": "This is a test"}')
echo "$RES"
if ! echo "$RES" | grep -q "201$"; then
  echo "FAIL: POST /todos did not return 201"
  exit 1
fi
# Extract JSON body (everything except the last line which is the HTTP code)
JSON_BODY=$(echo "$RES" | sed '$d')
TODO_ID=$(echo "$JSON_BODY" | jq -r '.id')
echo "Created todo with ID: $TODO_ID"

echo ""
echo "=== Testing POST /todos (missing title) ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b $COOKIE_JAR \
  -d '{"description": "No title"}')
echo "$RES"
if ! echo "$RES" | grep -q "400$"; then
  echo "FAIL: POST /todos without title did not return 400"
  exit 1
fi

echo ""
echo "=== Testing GET /todos ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" \
  -b $COOKIE_JAR)
echo "$RES"
if ! echo "$RES" | grep -q "200$"; then
  echo "FAIL: GET /todos did not return 200"
  exit 1
fi

echo ""
echo "=== Testing GET /todos/:id ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" \
  -b $COOKIE_JAR)
echo "$RES"
if ! echo "$RES" | grep -q "200$"; then
  echo "FAIL: GET /todos/:id did not return 200"
  exit 1
fi

echo ""
echo "=== Testing GET /todos/:id (not found) ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/9999" \
  -b $COOKIE_JAR)
echo "$RES"
if ! echo "$RES" | grep -q "404$"; then
  echo "FAIL: GET /todos/9999 did not return 404"
  exit 1
fi

echo ""
echo "=== Testing PUT /todos/:id ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b $COOKIE_JAR \
  -d '{"completed": true}')
echo "$RES"
if ! echo "$RES" | grep -q "200$"; then
  echo "FAIL: PUT /todos/:id did not return 200"
  exit 1
fi

echo ""
echo "=== Testing PUT /todos/:id (empty title) ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b $COOKIE_JAR \
  -d '{"title": ""}')
echo "$RES"
if ! echo "$RES" | grep -q "400$"; then
  echo "FAIL: PUT /todos/:id with empty title did not return 400"
  exit 1
fi

echo ""
echo "=== Testing DELETE /todos/:id ==="
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" \
  -b $COOKIE_JAR)
echo "DELETE response code: $(echo "$RES" | tail -1)"
if ! echo "$RES" | grep -q "204$"; then
  echo "FAIL: DELETE /todos/:id did not return 204"
  exit 1
fi

echo ""
echo "=== Testing DELETE /todos/:id (already deleted) ==="
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" \
  -b $COOKIE_JAR)
echo "$RES"
if ! echo "$RES" | grep -q "404$"; then
  echo "FAIL: DELETE /todos/:id (already deleted) did not return 404"
  exit 1
fi

echo ""
echo "=== Testing POST /logout ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" \
  -b $COOKIE_JAR)
echo "$RES"
if ! echo "$RES" | grep -q "200$"; then
  echo "FAIL: POST /logout did not return 200"
  exit 1
fi

echo ""
echo "=== Testing GET /me after logout ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" \
  -b $COOKIE_JAR)
echo "$RES"
if ! echo "$RES" | grep -q "401$"; then
  echo "FAIL: GET /me after logout did not return 401"
  exit 1
fi

echo ""
echo "=== ALL TESTS PASSED ==="
rm -f $COOKIE_JAR