#!/bin/bash

# Kill any existing server on port 8080
fuser -k 8080/tcp 2>/dev/null || true
sleep 2
rm -f cookies.txt cookies2.txt

echo "Starting server..."
./run.sh --port 8080 > server.log 2>&1 &
SERVER_PID=$!

# Wait for server to be ready with a timeout
READY=0
for i in {1..30}; do
  if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/me | grep -q "401"; then
    READY=1
    break
  fi
  sleep 1
done

if [ $READY -eq 0 ]; then
  echo "FAIL: Server failed to start within 30 seconds"
  cat server.log
  kill $SERVER_PID 2>/dev/null || true
  exit 1
fi

echo "Server is ready. Running tests..."

# Helper function for testing
test_endpoint() {
  local name=$1
  local expected_status=$2
  local actual_status=$3
  local expected_body=$4
  local actual_body=$5
  
  if [ "$actual_status" != "$expected_status" ]; then
    echo "FAIL: $name"
    echo "  Expected status: $expected_status, got: $actual_status"
    echo "  Expected body to contain: $expected_body"
    echo "  Actual body: $actual_body"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
  fi
  if [ -n "$expected_body" ] && [[ "$actual_body" != *"$expected_body"* ]]; then
    echo "FAIL: $name"
    echo "  Expected body to contain: $expected_body"
    echo "  Actual body: $actual_body"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
  fi
  echo "PASS: $name"
}

BASE_URL="http://localhost:8080"

do_curl() {
  local res
  res=$(curl -s -w "\n%{http_code}" "$@")
  LAST_STATUS="${res##*$'\n'}"
  LAST_BODY="${res%$'\n'*}"
}

# Test 1: Register
do_curl -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}'
test_endpoint "Register valid user" "201" "$LAST_STATUS" '{"id":1,"username":"testuser"}' "$LAST_BODY"

# Test 2: Register duplicate
do_curl -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}'
test_endpoint "Register duplicate user" "409" "$LAST_STATUS" 'Username already exists' "$LAST_BODY"

# Test 3: Register invalid username (too short)
do_curl -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}'
test_endpoint "Register invalid username" "400" "$LAST_STATUS" 'Invalid username' "$LAST_BODY"

# Test 4: Register invalid username (special chars)
do_curl -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"test@user","password":"password123"}'
test_endpoint "Register invalid username (special chars)" "400" "$LAST_STATUS" 'Invalid username' "$LAST_BODY"

# Test 5: Register short password
do_curl -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser2","password":"short"}'
test_endpoint "Register short password" "400" "$LAST_STATUS" 'Password too short' "$LAST_BODY"

# Test 6: Login
do_curl -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}'
test_endpoint "Login valid" "200" "$LAST_STATUS" '{"id":1,"username":"testuser"}' "$LAST_BODY"

# Test 7: Login invalid
do_curl -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"wrongpass"}'
test_endpoint "Login invalid" "401" "$LAST_STATUS" 'Invalid credentials' "$LAST_BODY"

# Test 8: Me
do_curl -b cookies.txt -X GET "$BASE_URL/me"
test_endpoint "Me valid" "200" "$LAST_STATUS" '{"id":1,"username":"testuser"}' "$LAST_BODY"

# Test 9: Me unauthenticated
do_curl -X GET "$BASE_URL/me"
test_endpoint "Me unauthenticated" "401" "$LAST_STATUS" 'Authentication required' "$LAST_BODY"

# Test 10: Change Password
do_curl -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password":"password123","new_password":"newpassword123"}'
test_endpoint "Change password valid" "200" "$LAST_STATUS" '{}' "$LAST_BODY"

# Test 11: Change Password wrong old
do_curl -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password":"wrong","new_password":"newpassword123"}'
test_endpoint "Change password wrong old" "401" "$LAST_STATUS" 'Invalid credentials' "$LAST_BODY"

# Test 12: Change Password short new
do_curl -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password":"newpassword123","new_password":"short"}'
test_endpoint "Change password short new" "400" "$LAST_STATUS" 'Password too short' "$LAST_BODY"

# Test 13: Create Todo
do_curl -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title":"Buy milk","description":"From the store"}'
test_endpoint "Create todo" "201" "$LAST_STATUS" '"title":"Buy milk"' "$LAST_BODY"

# Test 14: Create Todo missing title
do_curl -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"description":"No title"}'
test_endpoint "Create todo missing title" "400" "$LAST_STATUS" 'Title is required' "$LAST_BODY"

# Test 15: Create Todo empty title
do_curl -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title":"   "}'
test_endpoint "Create todo empty title" "400" "$LAST_STATUS" 'Title is required' "$LAST_BODY"

# Test 16: List Todos
do_curl -b cookies.txt -X GET "$BASE_URL/todos"
test_endpoint "List todos" "200" "$LAST_STATUS" '"title":"Buy milk"' "$LAST_BODY"

# Test 17: Get Todo
do_curl -b cookies.txt -X GET "$BASE_URL/todos/1"
test_endpoint "Get todo" "200" "$LAST_STATUS" '"title":"Buy milk"' "$LAST_BODY"

# Test 18: Get Todo not found
do_curl -b cookies.txt -X GET "$BASE_URL/todos/999"
test_endpoint "Get todo not found" "404" "$LAST_STATUS" 'Todo not found' "$LAST_BODY"

# Test 19: Update Todo
do_curl -b cookies.txt -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"completed":true}'
test_endpoint "Update todo" "200" "$LAST_STATUS" '"completed":true' "$LAST_BODY"

# Test 20: Update Todo empty title
do_curl -b cookies.txt -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"title":""}'
test_endpoint "Update todo empty title" "400" "$LAST_STATUS" 'Title is required' "$LAST_BODY"

# Test 21: Delete Todo
do_curl -b cookies.txt -X DELETE "$BASE_URL/todos/1"
test_endpoint "Delete todo" "204" "$LAST_STATUS" "" "$LAST_BODY"

# Test 22: Delete Todo not found (already deleted)
do_curl -b cookies.txt -X DELETE "$BASE_URL/todos/1"
test_endpoint "Delete todo not found" "404" "$LAST_STATUS" 'Todo not found' "$LAST_BODY"

# Test 23: Logout
do_curl -b cookies.txt -X POST "$BASE_URL/logout"
test_endpoint "Logout" "200" "$LAST_STATUS" '{}' "$LAST_BODY"

# Test 24: Me after logout
do_curl -b cookies.txt -X GET "$BASE_URL/me"
test_endpoint "Me after logout" "401" "$LAST_STATUS" 'Authentication required' "$LAST_BODY"

# Test 25: ID Enumeration Prevention
do_curl -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"otheruser","password":"password123"}'
do_curl -c cookies2.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"otheruser","password":"password123"}'
do_curl -b cookies2.txt -X GET "$BASE_URL/todos/1"
test_endpoint "Other user cannot get todo" "404" "$LAST_STATUS" 'Todo not found' "$LAST_BODY"

do_curl -b cookies2.txt -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"title":"hacked"}'
test_endpoint "Other user cannot update todo" "404" "$LAST_STATUS" 'Todo not found' "$LAST_BODY"

do_curl -b cookies2.txt -X DELETE "$BASE_URL/todos/1"
test_endpoint "Other user cannot delete todo" "404" "$LAST_STATUS" 'Todo not found' "$LAST_BODY"

echo "==================================="
echo "All tests passed successfully!"
echo "==================================="

kill $SERVER_PID 2>/dev/null || true
rm -f cookies.txt cookies2.txt
exit 0