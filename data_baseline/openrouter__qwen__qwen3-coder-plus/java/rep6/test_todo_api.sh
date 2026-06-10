#!/bin/bash

export SERVER_PORT=${SERVER_PORT:-8083}
export SERVER_URL="http://localhost:${SERVER_PORT}"

echo "Starting Todo API server in background on port ${SERVER_PORT}..."
java -cp . Server --port "$SERVER_PORT" &
SERVER_PID=$!
sleep 2  # Give server time to start

echo "Testing API endpoints..."

set -e  # Exit immediately if any command fails

# Clear any previous cookies file
rm -f cookies.txt

echo "Test 1: Register new user"
curl -s -X POST "$SERVER_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}'
echo ""

echo "Test 2: Verify invalid username registration fails"
if curl -s -X POST "$SERVER_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username":"ab","password":"password123"}' | grep -q "error"; then
  echo "Expected validation failure occurred."
else
  echo "Expected validation failure was missing!"
  kill $SERVER_PID
  exit 1
fi

echo "Test 3: Login with registered user"
curl -s -X POST "$SERVER_URL/login" \
  -c cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}'
echo ""

echo "Test 4: Get user info"
curl -s -X GET "$SERVER_URL/me" \
  -b cookies.txt \
  -H "Content-Type: application/json"
echo ""

echo "Test 5: Create a new todo"
curl -s -X POST "$SERVER_URL/todos" \
  -b cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"title":"First todo","description":"This is my first todo item."}'
echo ""

echo "Test 6: Create another todo"
curl -s -X POST "$SERVER_URL/todos" \
  -b cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"title":"Second todo","description":"This is my second todo item."}'
echo ""

echo "Test 7: Get all todos"
curl -s -X GET "$SERVER_URL/todos" \
  -b cookies.txt \
  -H "Content-Type: application/json"
echo ""

echo "Test 8: Get a specific todo by ID (now should work!)"
TODO_RESPONSE=$(curl -s -X GET "$SERVER_URL/todos/1" \
  -b cookies.txt \
  -H "Content-Type: application/json")

if echo "$TODO_RESPONSE" | grep -q "First todo"; then
  echo "Successfully retrieved todo with ID 1"
else
  echo "Failed to retrieve todo 1: $TODO_RESPONSE"
  kill $SERVER_PID  
  exit 1
fi

echo "Test 9: Update the todo to mark as completed"
UPDATED_TODO=$(curl -s -X PUT "$SERVER_URL/todos/1" \
  -b cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"completed":true,"title":"Updated First todo"}')

if echo "$UPDATED_TODO" | grep -q '"completed":true'; then
  echo "Successfully updated todo as completed"
else
  echo "Failed to update todo 1: $UPDATED_TODO"
  kill $SERVER_PID
  exit 1
fi

echo "Test 10: Try updating with empty title (should fail)"
UPDATE_FAILURE=$(curl -s -w "%{http_code}" -X PUT "$SERVER_URL/todos/1" \
  -b cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"title":""}')

if [ "${UPDATE_FAILURE: -3}" = "400" ]; then
  HTTP_BODY="${UPDATE_FAILURE%???}"
  if echo "$HTTP_BODY" | grep -q "Title is required"; then
    echo "Correctly rejected update with empty title"
  else
    echo "Wrong error message when updating with empty title: $HTTP_BODY"
    kill $SERVER_PID
    exit 1
  fi
else
  echo "Should have failed to update with empty title, got: $UPDATE_FAILURE"
  kill $SERVER_PID
  exit 1
fi

echo "Test 11: Change password"
curl -s -X PUT "$SERVER_URL/password" \
  -b cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword456"}'
echo ""

echo "Test 12: Logout"
curl -s -X POST "$SERVER_URL/logout" \
  -b cookies.txt \
  -H "Content-Type: application/json"
echo ""

echo "Test 13: Attempt to access protected endpoint after logout (should fail)"
AUTH_FAIL_RESPONSE=$(curl -s -w "%{http_code}" -X GET "$SERVER_URL/me" \
  -b cookies.txt \
  -H "Content-Type: application/json")

if [ "${AUTH_FAIL_RESPONSE: -3}" = "401" ]; then
  HTTP_BODY="${AUTH_FAIL_RESPONSE%???}"
  if echo "$HTTP_BODY" | grep -q "Authentication required"; then
    echo "Authorization correctly denied access after logout"
  else
    echo "Wrong error message after logout: $HTTP_BODY"
    kill $SERVER_PID
    exit 1
  fi
else
  echo "Expected authorization to fail after logout, got: $AUTH_FAIL_RESPONSE"
  kill $SERVER_PID
  exit 1
fi

echo "Test 14: Verify delete works when logged back in"
curl -s -X POST "$SERVER_URL/login" \
  -c cookies.txt \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpassword456"}'
echo "Re-logged in with new password"

DELETE_RESULT=$(curl -s -w "%{http_code}" -X DELETE "$SERVER_URL/todos/2" \
  -b cookies.txt \
  -H "Content-Type: application/json")
if [ "${DELETE_RESULT: -3}" = "204" ]; then
  echo "Successfully deleted todo with ID 2"
else
  echo "Delete operation failed: $DELETE_RESULT"
  kill $SERVER_PID
  exit 1
fi

echo ""
echo "All tests passed!"

# Clean up
kill $SERVER_PID
rm -f cookies.txt