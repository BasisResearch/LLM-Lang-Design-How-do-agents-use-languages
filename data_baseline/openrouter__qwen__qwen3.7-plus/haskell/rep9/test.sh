#!/bin/bash
set -e

PORT=8080
BASE="http://localhost:$PORT"

echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!

# Wait for server to be ready
sleep 3

cleanup() {
  echo "Cleaning up server (PID $SERVER_PID)..."
  kill $SERVER_PID 2>/dev/null || true
  rm -f cookies.txt
}
trap cleanup EXIT

# Helper function to run curl and check status
check_curl() {
  local expected_code=$1
  local method=$2
  local url=$3
  local extra_args=$4
  local data=$5
  
  if [ -n "$data" ]; then
    RES=$(curl -s -w "\n%{http_code}" -X "$method" "$url" -H "Content-Type: application/json" $extra_args -d "$data")
  else
    RES=$(curl -s -w "\n%{http_code}" -X "$method" "$url" $extra_args)
  fi
  
  CODE=$(echo "$RES" | tail -n1)
  BODY=$(echo "$RES" | sed '$d')
  
  if [ "$CODE" != "$expected_code" ]; then
    echo "FAIL: $method $url expected $expected_code, got $CODE. Body: $BODY"
    exit 1
  fi
  echo "PASS: $method $url"
}

echo "=== Testing Register ==="
check_curl 201 POST "$BASE/register" "" '{"username": "testuser", "password": "password123"}'
check_curl 400 POST "$BASE/register" "" '{"username": "ab", "password": "password123"}'
check_curl 400 POST "$BASE/register" "" '{"username": "testuser2", "password": "short"}'
check_curl 409 POST "$BASE/register" "" '{"username": "testuser", "password": "password123"}'

echo "=== Testing Login ==="
check_curl 200 POST "$BASE/login" "-c cookies.txt" '{"username": "testuser", "password": "password123"}'
check_curl 401 POST "$BASE/login" "" '{"username": "testuser", "password": "wrongpassword"}'

echo "=== Testing /me ==="
check_curl 200 GET "$BASE/me" "-b cookies.txt" ""
check_curl 401 GET "$BASE/me" "" ""

echo "=== Testing /password ==="
check_curl 200 PUT "$BASE/password" "-b cookies.txt" '{"old_password": "password123", "new_password": "newpassword123"}'
check_curl 401 PUT "$BASE/password" "-b cookies.txt" '{"old_password": "wrong", "new_password": "newpassword123"}'

echo "=== Testing POST /todos ==="
check_curl 201 POST "$BASE/todos" "-b cookies.txt" '{"title": "My Todo", "description": "Do this"}'
check_curl 400 POST "$BASE/todos" "-b cookies.txt" '{"title": "", "description": "Do this"}'
check_curl 400 POST "$BASE/todos" "-b cookies.txt" '{"description": "Do this"}'

echo "=== Testing GET /todos ==="
check_curl 200 GET "$BASE/todos" "-b cookies.txt" ""

echo "=== Testing GET /todos/:id ==="
check_curl 200 GET "$BASE/todos/1" "-b cookies.txt" ""
check_curl 404 GET "$BASE/todos/999" "-b cookies.txt" ""

echo "=== Testing PUT /todos/:id ==="
check_curl 200 PUT "$BASE/todos/1" "-b cookies.txt" '{"completed": true}'
check_curl 400 PUT "$BASE/todos/1" "-b cookies.txt" '{"title": ""}'

echo "=== Testing DELETE /todos/:id ==="
check_curl 204 DELETE "$BASE/todos/1" "-b cookies.txt" ""
check_curl 404 DELETE "$BASE/todos/1" "-b cookies.txt" ""

echo "=== Testing Logout ==="
check_curl 200 POST "$BASE/logout" "-b cookies.txt" ""

echo "=== Testing /me after logout ==="
check_curl 401 GET "$BASE/me" "-b cookies.txt" ""

echo "=== ALL TESTS PASSED ==="
