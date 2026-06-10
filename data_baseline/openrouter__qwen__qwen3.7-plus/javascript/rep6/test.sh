#!/bin/bash
set -e

PORT=3456
BASE="http://localhost:$PORT"

echo "Starting server..."
setsid node server.js --port $PORT > /tmp/server.log 2>&1 < /dev/null &
SERVER_PID=$!
sleep 2

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  rm -f cookies.txt cookies2.txt
}
trap cleanup EXIT

echo "Running tests..."

test_api() {
  local method=$1
  local path=$2
  local data=$3
  local expected_code=$4
  local expected_body_contains=$5
  local cookie_file=$6

  local curl_args=(-s -w 'DELIM%{http_code}' -X "$method" "$BASE$path")
  if [ -n "$cookie_file" ]; then
    curl_args+=(-b "$cookie_file")
  fi
  if [ -n "$data" ]; then
    curl_args+=(-d "$data")
  fi

  local RES=$(curl "${curl_args[@]}")
  local CODE="${RES##*DELIM}"
  local BODY="${RES%DELIM*}"

  if [ "$CODE" != "$expected_code" ]; then
    echo "FAIL: $method $path - expected code $expected_code, got $CODE"
    echo "BODY: $BODY"
    exit 1
  fi

  if [ -n "$expected_body_contains" ]; then
    if ! echo "$BODY" | grep -q "$expected_body_contains"; then
      echo "FAIL: $method $path - expected body to contain '$expected_body_contains'"
      echo "BODY: $BODY"
      exit 1
    fi
  fi
  
  echo "PASS: $method $path"
}

# 1. Register user (invalid username)
test_api POST /register '{"username": "ab", "password": "password123"}' 400 "Invalid username"

# 2. Register user (short password)
test_api POST /register '{"username": "user1", "password": "short"}' 400 "Password too short"

# 3. Register user (valid)
test_api POST /register '{"username": "user1", "password": "password123"}' 201 '"id":1'

# 4. Register same user
test_api POST /register '{"username": "user1", "password": "password123"}' 409 "Username already exists"

# 5. Login (invalid credentials)
test_api POST /login '{"username": "user1", "password": "wrongpassword"}' 401 "Invalid credentials"

# 6. Login (valid) - saves cookie
curl -s -c cookies.txt -X POST "$BASE/login" -d '{"username": "user1", "password": "password123"}' > /dev/null
echo "PASS: POST /login"

# 7. Access /me without cookie
test_api GET /me '' 401 "Authentication required"

# 8. Access /me with cookie
test_api GET /me '' 200 '"username":"user1"' "cookies.txt"

# 9. Change password (invalid old)
test_api PUT /password '{"old_password": "wrong", "new_password": "newpassword123"}' 401 "Invalid credentials" "cookies.txt"

# 10. Change password (short new)
test_api PUT /password '{"old_password": "password123", "new_password": "short"}' 400 "Password too short" "cookies.txt"

# 11. Change password (valid)
test_api PUT /password '{"old_password": "password123", "new_password": "newpassword123"}' 200 "{}" "cookies.txt"

# 12. Login with new password
curl -s -c cookies.txt -X POST "$BASE/login" -d '{"username": "user1", "password": "newpassword123"}' > /dev/null
echo "PASS: POST /login (new password)"

# 13. Create todo (missing title)
test_api POST /todos '{"description": "test"}' 400 "Title is required" "cookies.txt"

# 14. Create todo (empty title)
test_api POST /todos '{"title": "", "description": "test"}' 400 "Title is required" "cookies.txt"

# 15. Create todo (valid)
test_api POST /todos '{"title": "My Todo", "description": "Do this"}' 201 '"title":"My Todo"' "cookies.txt"

# 16. List todos
RES=$(curl -s -w 'DELIM%{http_code}' -b cookies.txt -X GET "$BASE/todos")
CODE="${RES##*DELIM}"
BODY="${RES%DELIM*}"
if [ "$CODE" != "200" ]; then echo "FAIL: Todo list, expected 200, got $CODE"; exit 1; fi
if ! echo "$BODY" | grep -q '"title":"My Todo"'; then echo "FAIL: Todo list body"; exit 1; fi
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
echo "PASS: GET /todos"

# 17. Get todo by ID (valid)
test_api GET /todos/$TODO_ID '' 200 '"title":"My Todo"' "cookies.txt"

# 18. Get todo by ID (invalid ID)
test_api GET /todos/999 '' 404 "Todo not found" "cookies.txt"

# 19. Update todo (invalid title)
test_api PUT /todos/$TODO_ID '{"title": ""}' 400 "Title is required" "cookies.txt"

# 20. Update todo (valid, partial)
test_api PUT /todos/$TODO_ID '{"completed": true}' 200 '"completed":true' "cookies.txt"

# 21. Delete todo (valid)
RES=$(curl -s -w 'DELIM%{http_code}' -b cookies.txt -X DELETE "$BASE/todos/$TODO_ID")
CODE="${RES##*DELIM}"
if [ "$CODE" != "204" ]; then echo "FAIL: Todo delete valid, expected 204, got $CODE"; exit 1; fi
echo "PASS: DELETE /todos/$TODO_ID"

# 22. Get deleted todo
test_api GET /todos/$TODO_ID '' 404 "Todo not found" "cookies.txt"

# 23. Register user2, login, try to access user1's todo
curl -s -X POST "$BASE/register" -d '{"username": "user2", "password": "password123"}' > /dev/null
curl -s -c cookies2.txt -X POST "$BASE/login" -d '{"username": "user2", "password": "password123"}' > /dev/null

# Recreate a todo for user1 to test ownership
curl -s -b cookies.txt -X POST "$BASE/todos" -d '{"title": "User1 Todo", "description": "test"}' > /dev/null
RES=$(curl -s -b cookies.txt -X GET "$BASE/todos")
TODO_ID_USER1=$(echo "$RES" | grep -o '"id":[0-9]*' | tail -1 | cut -d':' -f2)

RES=$(curl -s -w 'DELIM%{http_code}' -b cookies2.txt -X GET "$BASE/todos/$TODO_ID_USER1")
CODE="${RES##*DELIM}"
if [ "$CODE" != "404" ]; then echo "FAIL: Todo access other user, expected 404, got $CODE"; exit 1; fi
echo "PASS: GET /todos/$TODO_ID_USER1 (other user -> 404)"

# 24. Logout
RES=$(curl -s -w 'DELIM%{http_code}' -b cookies.txt -X POST "$BASE/logout")
CODE="${RES##*DELIM}"
if [ "$CODE" != "200" ]; then echo "FAIL: Logout, expected 200, got $CODE"; exit 1; fi
echo "PASS: POST /logout"

# 25. Access /me after logout
test_api GET /me '' 401 "Authentication required" "cookies.txt"

echo "ALL TESTS PASSED!"
