#!/bin/bash

PORT=8765

echo "Starting server on port $PORT..."
node server.js --port $PORT &
SERVER_PID=$!

# Give server time to start
sleep 1

cleanup() {
  echo "Cleaning up..."
  kill $SERVER_PID 2>/dev/null || true
  kill $(lsof -t -i:$PORT) 2>/dev/null || true
  rm -f /tmp/cookie.txt /tmp/cookie2.txt
}
trap cleanup EXIT

# Test helper
expect() {
  local desc=$1
  local expected_status=$2
  local expected_pattern=$3
  local status=$4
  local body=$5

  if [ "$status" -eq "$expected_status" ]; then
    if [ -z "$expected_pattern" ] || echo "$body" | grep -q "$expected_pattern"; then
      echo "✅ PASS: $desc"
    else
      echo "❌ FAIL: $desc"
      echo "  Expected pattern: $expected_pattern"
      echo "  Got body: $body"
      exit 1
    fi
  else
    echo "❌ FAIL: $desc"
    echo "  Expected status: $expected_status, Got: $status"
    echo "  Got body: $body"
    exit 1
  fi
}

do_post() {
  local url=$1
  local data=$2
  local cookie_file=$3
  local out_file="/tmp/out.txt"
  if [ -n "$cookie_file" ]; then
    curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$data" -b "$cookie_file" -c "$cookie_file" "$url" > "$out_file"
  else
    curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d "$data" -c "$cookie_file" "$url" > "$out_file"
  fi
  BODY=$(head -n -1 "$out_file")
  STATUS=$(tail -n 1 "$out_file")
}

do_get() {
  local url=$1
  local cookie_file=$2
  local out_file="/tmp/out.txt"
  if [ -n "$cookie_file" ]; then
    curl -s -w "\n%{http_code}" -b "$cookie_file" "$url" > "$out_file"
  else
    curl -s -w "\n%{http_code}" "$url" > "$out_file"
  fi
  BODY=$(head -n -1 "$out_file")
  STATUS=$(tail -n 1 "$out_file")
}

do_put() {
  local url=$1
  local data=$2
  local cookie_file=$3
  local out_file="/tmp/out.txt"
  curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -d "$data" -b "$cookie_file" "$url" > "$out_file"
  BODY=$(head -n -1 "$out_file")
  STATUS=$(tail -n 1 "$out_file")
}

do_delete() {
  local url=$1
  local cookie_file=$2
  local out_file="/tmp/out.txt"
  curl -s -w "\n%{http_code}" -X DELETE -b "$cookie_file" "$url" > "$out_file"
  BODY=$(head -n -1 "$out_file")
  STATUS=$(tail -n 1 "$out_file")
}

echo "=== Testing POST /register ==="
do_post "http://localhost:$PORT/register" '{"username": "testuser", "password": "password123"}' "/tmp/cookie.txt"
expect "Register valid user" 201 '"testuser"' "$STATUS" "$BODY"

do_post "http://localhost:$PORT/register" '{"username": "ab", "password": "password123"}' "/tmp/cookie.txt"
expect "Register short username" 400 'Invalid username' "$STATUS" "$BODY"

do_post "http://localhost:$PORT/register" '{"username": "user@", "password": "password123"}' "/tmp/cookie.txt"
expect "Register invalid chars username" 400 'Invalid username' "$STATUS" "$BODY"

do_post "http://localhost:$PORT/register" '{"username": "testuser2", "password": "short"}' "/tmp/cookie.txt"
expect "Register short password" 400 'Password too short' "$STATUS" "$BODY"

do_post "http://localhost:$PORT/register" '{"username": "testuser", "password": "password123"}' "/tmp/cookie.txt"
expect "Register existing username" 409 'Username already exists' "$STATUS" "$BODY"

echo "=== Testing POST /login ==="
do_post "http://localhost:$PORT/login" '{"username": "testuser", "password": "password123"}' "/tmp/cookie.txt"
expect "Login valid" 200 '"testuser"' "$STATUS" "$BODY"

do_post "http://localhost:$PORT/login" '{"username": "wronguser", "password": "password123"}' "/tmp/cookie.txt"
expect "Login invalid username" 401 'Invalid credentials' "$STATUS" "$BODY"

do_post "http://localhost:$PORT/login" '{"username": "testuser", "password": "wrongpass"}' "/tmp/cookie.txt"
expect "Login invalid password" 401 'Invalid credentials' "$STATUS" "$BODY"

echo "=== Testing GET /me ==="
do_get "http://localhost:$PORT/me" "/tmp/cookie.txt"
expect "Get me authenticated" 200 '"testuser"' "$STATUS" "$BODY"

do_get "http://localhost:$PORT/me" ""
expect "Get me unauthenticated" 401 'Authentication required' "$STATUS" "$BODY"

echo "=== Testing PUT /password ==="
do_put "http://localhost:$PORT/password" '{"old_password": "password123", "new_password": "newpassword123"}' "/tmp/cookie.txt"
expect "Change password valid" 200 '' "$STATUS" "$BODY"

do_put "http://localhost:$PORT/password" '{"old_password": "wrongpassword", "new_password": "newpassword123"}' "/tmp/cookie.txt"
expect "Change password wrong old" 401 'Invalid credentials' "$STATUS" "$BODY"

do_put "http://localhost:$PORT/password" '{"old_password": "newpassword123", "new_password": "short"}' "/tmp/cookie.txt"
expect "Change password short new" 400 'Password too short' "$STATUS" "$BODY"

echo "=== Testing POST /todos ==="
# Re-login with new password
do_post "http://localhost:$PORT/login" '{"username": "testuser", "password": "newpassword123"}' "/tmp/cookie.txt"

do_post "http://localhost:$PORT/todos" '{"title": "First todo"}' "/tmp/cookie.txt"
expect "Create todo" 201 '"First todo"' "$STATUS" "$BODY"
expect "Create todo has completed false" 201 '"completed":false' "$STATUS" "$BODY"

do_post "http://localhost:$PORT/todos" '{"title": "", "description": "test"}' "/tmp/cookie.txt"
expect "Create todo empty title" 400 'Title is required' "$STATUS" "$BODY"

do_post "http://localhost:$PORT/todos" '{"description": "no title"}' "/tmp/cookie.txt"
expect "Create todo no title" 400 'Title is required' "$STATUS" "$BODY"

echo "=== Testing GET /todos ==="
do_get "http://localhost:$PORT/todos" "/tmp/cookie.txt"
expect "Get todos" 200 '"First todo"' "$STATUS" "$BODY"

echo "=== Testing GET /todos/:id ==="
do_get "http://localhost:$PORT/todos/1" "/tmp/cookie.txt"
expect "Get todo by id" 200 '"First todo"' "$STATUS" "$BODY"

do_get "http://localhost:$PORT/todos/999" "/tmp/cookie.txt"
expect "Get non-existent todo" 404 'Todo not found' "$STATUS" "$BODY"

# Create second user to test 404 on other users' todos
do_post "http://localhost:$PORT/register" '{"username": "otheruser", "password": "password123"}' "/tmp/cookie2.txt"
do_post "http://localhost:$PORT/login" '{"username": "otheruser", "password": "password123"}' "/tmp/cookie2.txt"

do_get "http://localhost:$PORT/todos/1" "/tmp/cookie2.txt"
expect "Get other user's todo" 404 'Todo not found' "$STATUS" "$BODY"

echo "=== Testing PUT /todos/:id ==="
do_put "http://localhost:$PORT/todos/1" '{"completed": true}' "/tmp/cookie.txt"
expect "Update todo completed" 200 '"completed":true' "$STATUS" "$BODY"

do_put "http://localhost:$PORT/todos/1" '{"title": "Updated title"}' "/tmp/cookie.txt"
expect "Update todo title" 200 '"Updated title"' "$STATUS" "$BODY"

do_put "http://localhost:$PORT/todos/1" '{"title": ""}' "/tmp/cookie.txt"
expect "Update todo empty title" 400 'Title is required' "$STATUS" "$BODY"

do_put "http://localhost:$PORT/todos/999" '{"completed": true}' "/tmp/cookie.txt"
expect "Update non-existent todo" 404 'Todo not found' "$STATUS" "$BODY"

echo "=== Testing DELETE /todos/:id ==="
do_delete "http://localhost:$PORT/todos/1" "/tmp/cookie.txt"
expect "Delete todo" 204 '' "$STATUS" "$BODY"

do_get "http://localhost:$PORT/todos/1" "/tmp/cookie.txt"
expect "Get deleted todo" 404 'Todo not found' "$STATUS" "$BODY"

do_delete "http://localhost:$PORT/todos/999" "/tmp/cookie.txt"
expect "Delete non-existent todo" 404 'Todo not found' "$STATUS" "$BODY"

echo "=== Testing POST /logout ==="
# Get a token first
do_post "http://localhost:$PORT/login" '{"username": "testuser", "password": "newpassword123"}' "/tmp/cookie.txt"

do_post "http://localhost:$PORT/logout" '' "/tmp/cookie.txt"
expect "Logout" 200 '' "$STATUS" "$BODY"

do_get "http://localhost:$PORT/me" "/tmp/cookie.txt"
expect "Access after logout" 401 'Authentication required' "$STATUS" "$BODY"

echo "=== ALL TESTS PASSED ==="
