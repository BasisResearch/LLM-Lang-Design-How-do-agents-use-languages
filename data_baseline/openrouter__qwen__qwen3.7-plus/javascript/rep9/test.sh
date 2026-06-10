#!/bin/bash
set -e

PORT=3030
BASE_URL="http://localhost:$PORT"

echo "Starting server on port $PORT..."
./run.sh --port "$PORT" &
SERVER_PID=$!
sleep 2

cleanup() {
  echo "Cleaning up..."
  kill $SERVER_PID 2>/dev/null || true
  rm -f cookies.txt
}
trap cleanup EXIT

assert_status() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  local body="$4"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $name - Expected status $expected, got $actual. Body: $body"
    exit 1
  fi
}

assert_body() {
  local name="$1"
  local expected="$2"
  local body="$3"
  if ! echo "$body" | grep -q "$expected"; then
    echo "FAIL: $name - Expected body to contain '$expected'. Got: $body"
    exit 1
  fi
}

echo "1. Register user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H 'Content-Type: application/json' -d '{"username":"testuser","password":"password123"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Register user" "201" "$STATUS" "$BODY"
assert_body "Register user" '"username":"testuser"' "$BODY"
echo "PASS"

echo "2. Register invalid username"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H 'Content-Type: application/json' -d '{"username":"ab","password":"password123"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Register invalid username" "400" "$STATUS" "$BODY"
assert_body "Register invalid username" '"Invalid username"' "$BODY"
echo "PASS"

echo "3. Register short password"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H 'Content-Type: application/json' -d '{"username":"testuser2","password":"123"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Register short password" "400" "$STATUS" "$BODY"
assert_body "Register short password" '"Password too short"' "$BODY"
echo "PASS"

echo "4. Register existing user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H 'Content-Type: application/json' -d '{"username":"testuser","password":"password123"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Register existing user" "409" "$STATUS" "$BODY"
assert_body "Register existing user" '"Username already exists"' "$BODY"
echo "PASS"

echo "5. Login"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H 'Content-Type: application/json' -c cookies.txt -d '{"username":"testuser","password":"password123"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Login" "200" "$STATUS" "$BODY"
assert_body "Login" '"username":"testuser"' "$BODY"
echo "PASS"

echo "6. Login invalid credentials"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H 'Content-Type: application/json' -d '{"username":"testuser","password":"wrongpass"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Login invalid" "401" "$STATUS" "$BODY"
assert_body "Login invalid" '"Invalid credentials"' "$BODY"
echo "PASS"

echo "7. Get /me"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Get /me" "200" "$STATUS" "$BODY"
assert_body "Get /me" '"username":"testuser"' "$BODY"
echo "PASS"

echo "8. Get /me no auth"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Get /me no auth" "401" "$STATUS" "$BODY"
assert_body "Get /me no auth" '"Authentication required"' "$BODY"
echo "PASS"

echo "9. Change password"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H 'Content-Type: application/json' -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Change password" "200" "$STATUS" "$BODY"
assert_body "Change password" '{}' "$BODY"
echo "PASS"

echo "10. Change password wrong old"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H 'Content-Type: application/json' -b cookies.txt -d '{"old_password":"wrong","new_password":"newpassword123"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Change password wrong old" "401" "$STATUS" "$BODY"
assert_body "Change password wrong old" '"Invalid credentials"' "$BODY"
echo "PASS"

echo "11. Create todo"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H 'Content-Type: application/json' -b cookies.txt -d '{"title":"My first todo","description":"Details here"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Create todo" "201" "$STATUS" "$BODY"
assert_body "Create todo" '"title":"My first todo"' "$BODY"
echo "PASS"

echo "12. Create todo missing title"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H 'Content-Type: application/json' -b cookies.txt -d '{"description":"Details here"}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Create todo missing title" "400" "$STATUS" "$BODY"
assert_body "Create todo missing title" '"Title is required"' "$BODY"
echo "PASS"

echo "13. Get todos"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Get todos" "200" "$STATUS" "$BODY"
assert_body "Get todos" '"My first todo"' "$BODY"
echo "PASS"

echo "14. Get specific todo"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/1" -b cookies.txt)
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Get specific todo" "200" "$STATUS" "$BODY"
assert_body "Get specific todo" '"My first todo"' "$BODY"
echo "PASS"

echo "15. Get specific todo not found"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/999" -b cookies.txt)
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Get specific todo not found" "404" "$STATUS" "$BODY"
assert_body "Get specific todo not found" '"Todo not found"' "$BODY"
echo "PASS"

echo "16. Update todo"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/1" -H 'Content-Type: application/json' -b cookies.txt -d '{"completed":true}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Update todo" "200" "$STATUS" "$BODY"
assert_body "Update todo" '"completed":true' "$BODY"
echo "PASS"

echo "17. Update todo empty title"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/1" -H 'Content-Type: application/json' -b cookies.txt -d '{"title":""}')
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Update todo empty title" "400" "$STATUS" "$BODY"
assert_body "Update todo empty title" '"Title is required"' "$BODY"
echo "PASS"

echo "18. Delete todo"
STATUS=$(curl -s -w '%{http_code}' -o /dev/null -X DELETE "$BASE_URL/todos/1" -b cookies.txt)
assert_status "Delete todo" "204" "$STATUS" ""
echo "PASS"

echo "19. Delete todo not found"
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/1" -b cookies.txt)
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Delete todo not found" "404" "$STATUS" "$BODY"
assert_body "Delete todo not found" '"Todo not found"' "$BODY"
echo "PASS"

echo "20. Logout"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Logout" "200" "$STATUS" "$BODY"
assert_body "Logout" '{}' "$BODY"
echo "PASS"

echo "21. Get /me after logout"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
STATUS="${RES##*$'\n'}"; BODY="${RES%$'\n'*}"
assert_status "Get /me after logout" "401" "$STATUS" "$BODY"
assert_body "Get /me after logout" '"Authentication required"' "$BODY"
echo "PASS"

echo "All tests passed successfully!"