#!/bin/bash

echo "Testing the Todo API server..."

# Start the server in background
bash run.sh --port 3000 &
SERVER_PID=$!

# Wait a moment for the server to start
sleep 2

echo "Server started with PID $SERVER_PID"

# Test variables
BASE_URL="http://localhost:3000"
TEST_USER="testuser123"
TEST_PASS="strongpass123"
SESSION_COOKIE_FILE="/tmp/todo_test_cookies.txt"

# Clean up any existing cookie file
rm -f $SESSION_COOKIE_FILE

runTest() {
  local testName=$1
  local method=$2
  local endpoint=$3
  local data=$4
  local expectedStatus=$5
  local description=$6

  echo -n "Running test: $testName... "

  if [ "$data" != "none" ]; then
    RESPONSE=$(curl -s -w "%{http_code}" -X $method \
      -H "Content-Type: application/json" \
      --cookie $SESSION_COOKIE_FILE \
      --cookie-jar $SESSION_COOKIE_FILE \
      -d "$data" \
      "$BASE_URL$endpoint")
  else
    RESPONSE=$(curl -s -w "%{http_code}" -X $method \
      -H "Content-Type: application/json" \
      --cookie $SESSION_COOKIE_FILE \
      --cookie-jar $SESSION_COOKIE_FILE \
      "$BASE_URL$endpoint")
  fi

  HTTP_STATUS="${RESPONSE: -3}"
  RESPONSE_BODY="${RESPONSE%???}"

  if [ "$HTTP_STATUS" -eq "$expectedStatus" ]; then
    echo "✓ PASS ($HTTP_STATUS)"
  else
    echo "✗ FAIL (Expected: $expectedStatus, Got: $HTTP_STATUS)"
    echo "  Response: $RESPONSE_BODY"
  fi
}

# Run the tests
echo "Starting Test Suite..."

# Clean up cookies before starting
rm -f $SESSION_COOKIE_FILE

# Test 1: Register a new user
runTest "POST /register (valid)" "POST" "/register" "{\"username\": \"$TEST_USER\", \"password\": \"$TEST_PASS\"}" 201 "Valid registration"

# Wait slightly to ensure operations complete
sleep 1

# Test 2: Register with invalid username
runTest "POST /register (invalid username)" "POST" "/register" "{\"username\": \"ab\", \"password\": \"password123\"}" 400 "Username too short"

# Test 3: Register with short password 
runTest "POST /register (short password)" "POST" "/register" "{\"username\": \"user123abc\", \"password\": \"weak\"}" 400 "Password too short"

# Test 4: Register duplicate username
runTest "POST /register (duplicate user)" "POST" "/register" "{\"username\": \"$TEST_USER\", \"password\": \"$TEST_PASS\"}" 409 "Username already exists"

# Test 5: Login with valid credentials
runTest "POST /login (valid)" "POST" "/login" "{\"username\": \"$TEST_USER\", \"password\": \"$TEST_PASS\"}" 200 "Valid login"

# Test 6: Login with invalid credentials
runTest "POST /login (invalid)" "POST" "/login" "{\"username\": \"$TEST_USER\", \"password\": \"wrongpassword\"}" 401 "Invalid credentials"

# Test 7: Get user profile (/me) - requires authentication
runTest "GET /me (authenticated)" "GET" "/me" "none" 200 "Get user profile when authenticated"

# Test 8: Logout (authenticated)
runTest "POST /logout (authenticated)" "POST" "/logout" "none" 200 "Logout when authenticated"

# Wait for cookies to be processed
sleep 1

# Test 9: Try /me without authentication
rm -f $SESSION_COOKIE_FILE  # Clear cookies to simulate no auth
runTest "GET /me (unauthorized)" "GET" "/me" "none" 401 "Get user profile when unauthorized"

# Reauthenticate for further tests
curl -s -X POST \
  -H "Content-Type: application/json" \
  --cookie-jar $SESSION_COOKIE_FILE \
  -d "{\"username\": \"$TEST_USER\", \"password\": \"$TEST_PASS\"}" \
  "$BASE_URL/login" > /dev/null

# Test 10: Change password (authenticated)
runTest "PUT /password (authenticated)" "PUT" "/password" "{\"old_password\": \"$TEST_PASS\", \"new_password\": \"newStrongPass456\"}" 200 "Change password when authorized"

# Now change TEST_PASS since we updated it
TEST_PASS="newStrongPass456"
sleep 1

# Create a couple of test todos
TODO_TITLE1="My first task"
TODO_DESC1="A detailed description for my first task"
TODO_TITLE2="My second task" 
TODO_DESC2="Another task needing completion"

# Test 11: Create first todo
runTest "POST /todos (create)" "POST" "/todos" "{\"title\": \"$TODO_TITLE1\", \"description\": \"$TODO_DESC1\"}" 201 "Create a new todo"

# Capture the created todo id for future tests (we'll do manual curl and extraction for this example)
TODO_ID1=$(curl -s -X GET \
  -H "Content-Type: application/json" \
  --cookie $SESSION_COOKIE_FILE \
  "$BASE_URL/todos" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data[0]['id'])" 2>/dev/null || echo "1")

sleep 1

# Test 12: Create second todo
runTest "POST /todos (create second)" "POST" "/todos" "{\"title\": \"$TODO_TITLE2\", \"description\": \"$TODO_DESC2\"}" 201 "Create second todo"

sleep 1

TODO_ID2=$(curl -s -X GET \
  -H "Content-Type: application/json" \
  --cookie $SESSION_COOKIE_FILE \
  "$BASE_URL/todos" | python3 -c "import sys, json; data=json.load(sys.stdin); print([t for t in data if t['title'] == '\"$TODO_TITLE2\"'][0]['id']) 2>/dev/null 2>/dev/null || echo '2")

# Test 13: Get all todos
runTest "GET /todos (list all)" "GET" "/todos" "none" 200 "Get list of all user todos"

# Test 14: Get first specific todo by ID
runTest "GET /todos/:id (specific)" "GET" "/todos/$TODO_ID1" "none" 200 "Get specific todo"

# Test 15: Update specific todo
runTest "PUT /todos/:id (update)" "PUT" "/todos/$TODO_ID1" "{\"title\": \"Updated task title\", \"completed\": true}" 200 "Update specific todo"

sleep 1

# Test 16: Delete specific todo
runTest "DELETE /todos/:id (delete)" "DELETE" "/todos/$TODO_ID2" "none" 204 "Delete specific todo"

# Wait for delete operation
sleep 1

# Try to get the deleted todo to confirm deletion
DELETED_RESPONSE=$(curl -s -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  --cookie $SESSION_COOKIE_FILE \
  "$BASE_URL/todos/$TODO_ID2")
DELETED_HTTP_CODE="${DELETED_RESPONSE: -3}"
if [ "$DELETED_HTTP_CODE" -eq "404" ]; then
  echo "✓ DELETE verification PASS - deleted todo correctly returns 404"
else
  echo "✗ DELETE verification FAIL - deleted todo should return 404 but returned $DELETED_HTTP_CODE"
fi

echo "Tests completed!"

# Cleanup - kill the server
kill $SERVER_PID 2>/dev/null

# Clean up temp files
rm -f $SESSION_COOKIE_FILE