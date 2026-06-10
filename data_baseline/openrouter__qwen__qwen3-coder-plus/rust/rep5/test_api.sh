#!/bin/bash

set -e  # Exit on any error

echo "Starting server in background..."

# Start server on random free port
PORT=8081 
./target/debug/todo_server --port $PORT &
SERVER_PID=$!
sleep 2

echo "Testing API endpoints..."

# Set up a temporary cookie jar
COOKIE_JAR=$(mktemp)
trap "kill $SERVER_PID; rm $COOKIE_JAR; echo 'Server stopped'" EXIT

BASE_URL="http://localhost:$PORT"

echo "=== Test 1: Registration ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  "$BASE_URL/register")

if [ "$HTTP_CODE" -eq 201 ]; then
  USER_ID=$(jq -r '.id' response.json)
  echo "✓ Registration successful: User ID $USER_ID"
else
  echo "✗ Registration failed with HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

## Verify invalid registrations
echo "=== Test 2: Invalid Registration - Short Password ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"invaliduser","password":"short"}' \
  "$BASE_URL/register")

if [ "$HTTP_CODE" -eq 400 ]; then
  echo "✓ Password validation works"
else
  echo "✗ Password validation failed: Expected 400, got $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 3: Invalid Registration - Invalid Username ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"@invalid","password":"validpass123"}' \
  "$BASE_URL/register")

if [ "$HTTP_CODE" -eq 400 ]; then
  echo "✓ Username validation works"
else
  echo "✗ Username validation failed: Expected 400, got $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 4: Duplicate Username ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"anotherpass123"}' \
  "$BASE_URL/register")

if [ "$HTTP_CODE" -eq 409 ]; then
  echo "✓ Duplicate username blocked"
else
  echo "✗ Duplicate username not blocked: Expected 409, got $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 5: Login ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  "$BASE_URL/login")

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Login successful"
else
  echo "✗ Login failed with HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 6: Unauthenticated Access ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X GET "$BASE_URL/me")

if [ "$HTTP_CODE" -eq 401 ]; then
  echo "✓ Unauthenticated access blocked"
else
  echo "✗ Unauthenticated access not blocked: Expected 401, got $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 7: Authenticated Access (using cookies) ==="
# Store session cookie, then make authenticated request
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  -c $COOKIE_JAR \
  "$BASE_URL/login")

if [ "$HTTP_CODE" -ne 200 ]; then
  echo "✗ Login for session creation failed: $HTTP_CODE"
  exit 1
fi

HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X GET -b $COOKIE_JAR "$BASE_URL/me")

if [ "$HTTP_CODE" -eq 200 ]; then
  AUTH_USER_ID=$(jq -r '.id' response.json)
  AUTH_USERNAME=$(jq -r '.username' response.json)
  if [ "$AUTH_USER_ID" = "$USER_ID" ] && [ "$AUTH_USERNAME" = "testuser" ]; then
    echo "✓ Authenticated access works: User ID $AUTH_USER_ID"
  else
    echo "✗ Wrong user data returned: ID $AUTH_USER_ID, Username $AUTH_USERNAME (expected ID $USER_ID, User testuser)"
    cat response.json
    exit 1
  fi
else
  echo "✗ Authenticated access failed: HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 8: Create Todo ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"title":"First Todo","description":"My first todo item"}' \
  -b $COOKIE_JAR \
  "$BASE_URL/todos")

if [ "$HTTP_CODE" -eq 201 ]; then
  TODO_ID=$(jq -r '.id' response.json)
  echo "✓ Todo creation successful: Todo ID $TODO_ID"
else
  echo "✗ Todo creation failed with HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 9: List Todos ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X GET \
  -H "Content-Type: application/json" \
  -b $COOKIE_JAR \
  "$BASE_URL/todos")

if [ "$HTTP_CODE" -eq 200 ]; then
  TODO_COUNT=$(jq 'length' response.json)
  if [ "$TODO_COUNT" -eq 1 ]; then
    echo "✓ Todo listing works: Found $TODO_COUNT todo"
  else
    echo "✗ Todo count unexpected: Expected 1, got $TODO_COUNT"
    cat response.json
    exit 1
  fi
else
  echo "✗ Todo listing failed with HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 10: Get Specific Todo ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X GET \
  -b $COOKIE_JAR \
  "$BASE_URL/todos/$TODO_ID")

if [ "$HTTP_CODE" -eq 200 ]; then
  TODO_TITLE=$(jq -r '.title' response.json)
  if [ "$TODO_TITLE" = "First Todo" ]; then
    echo "✓ Specific todo retrieval works: Title '$TODO_TITLE'"
  else
    echo "✗ Wrong todo retrieved: Expected 'First Todo', got '$TODO_TITLE'"
    exit 1
  fi
else
  echo "✗ Specific todo retrieval failed: HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 11: Update Todo ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated Todo","description":"Modified description","completed":true}' \
  -b $COOKIE_JAR \
  "$BASE_URL/todos/$TODO_ID")

if [ "$HTTP_CODE" -eq 200 ]; then
  UPDATED_COMPLETED=$(jq -r '.completed' response.json)
  if [ "$UPDATED_COMPLETED" = "true" ]; then
    echo "✓ Todo update successful: Completed = True"
  else
    echo "✗ Todo update didn't apply changes correctly: Completed = $UPDATED_COMPLETED"
    exit 1
  fi
else
  echo "✗ Todo update failed with HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 12: Delete Todo ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X DELETE \
  -b $COOKIE_JAR \
  "$BASE_URL/todos/$TODO_ID")

if [ "$HTTP_CODE" -eq 204 ]; then
  echo "✓ Todo deletion successful"
else
  echo "✗ Todo deletion failed: HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 13: Change Password ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword123"}' \
  -b $COOKIE_JAR \
  "$BASE_URL/password")

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Password change successful"
else
  echo "✗ Password change failed: HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 14: Logout ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X POST \
  -b $COOKIE_JAR \
  "$BASE_URL/logout")

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Logout successful"
else
  echo "✗ Logout failed: HTTP $HTTP_CODE"
  cat response.json
  exit 1
fi

echo "=== Test 15: Verify Logged Out State ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X GET -b $COOKIE_JAR \
  "$BASE_URL/me")

if [ "$HTTP_CODE" -eq 401 ]; then
  echo "✓ Successfully logged out (auth now fails)"
else
  echo "✗ Still authenticated after logout: HTTP $HTTP_CODE"
  exit 1
fi

# Test login with new password to confirm the password really changed
echo "=== Test 16: Login After Password Change ==="
HTTP_CODE=$(curl -s -o response.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpassword123"}' \
  -c $COOKIE_JAR \
  "$BASE_URL/login")

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "✓ Can login with new password"
else
  echo "✗ Cannot login with new password: HTTP $HTTP_CODE"
  exit 1
fi

echo ""
echo "==================================="
echo "🎉 ALL TESTS PASSED! 🎉"
echo "==================================="
echo ""

kill $SERVER_PID
rm $COOKIE_JAR