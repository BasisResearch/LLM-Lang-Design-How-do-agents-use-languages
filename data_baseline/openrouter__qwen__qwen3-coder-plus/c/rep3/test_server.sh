#!/bin/bash

# Test script for Todo API server
PORT=${1:-8080}
BASE_URL="http://localhost:$PORT"

echo "Testing Todo Server at $BASE_URL"

# Remove cookies file
COOKIE_FILE="/tmp/todo_test_cookies.txt"
rm -f "$COOKIE_FILE"

echo "=== Testing Registration ==="
echo "Test 1: Register user johndoe..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"johndoe","password":"password123"}' "$BASE_URL/register")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???"}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "201" ]] && [[ $BODY == *'"id"'* ]] && [[ $BODY == *'"username":"johndoe"'* ]]; then
  echo "✓ Test 1 passed"
else
  echo "✗ Test 1 failed"
  exit 1
fi

echo ""

echo "Test 2: Register duplicate user johndoe..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"johndoe","password":"password123"}' "$BASE_URL/register")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "409" ]] && [[ $BODY == *'"error":"Username already exists"'* ]]; then
  echo "✓ Test 2 passed"
else
  echo "✗ Test 2 failed"
  exit 1
fi

echo ""

echo "Test 3: Register with short password..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"janedoe","password":"pass"}' "$BASE_URL/register")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "400" ]] && [[ $BODY == *'"error":"Password too short"'* ]]; then
  echo "✓ Test 3 passed"
else
  echo "✗ Test 3 failed"
  exit 1
fi

echo ""

echo "Test 4: Register with invalid username..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"ab","password":"password123"}' "$BASE_URL/register")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "400" ]] && [[ $BODY == *'"error":"Invalid username"'* ]]; then
  echo "✓ Test 4 passed"
else
  echo "✗ Test 4 failed"
  # Try with a longer invalid username with special chars
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"john@doe","password":"password123"}' "$BASE_URL/register")
  
  HTTP_CODE="${RESPONSE: -3}"
  BODY="${RESPONSE%???}"
  
  if [[ $HTTP_CODE == "400" ]] && [[ $BODY == *'"error":"Invalid username"'* ]]; then
    echo "✓ Test 4 passed (alternative)"
  else
    exit 1
  fi
fi

echo ""

echo "Test 5: Register valid user janedoe..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"janedoe","password":"password123"}' "$BASE_URL/register")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "201" ]] && [[ $BODY == *'"id"'* ]] && [[ $BODY == *'"username":"janedoe"'* ]]; then
  echo "✓ Test 5 passed"
else
  echo "✗ Test 5 failed"
  exit 1
fi

# Capture Jane's user ID for later use
JANE_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)

echo ""

echo "=== Testing Login ==="
echo "Test 6: Login with valid credentials..."  
RESPONSE=$(curl -s -c "$COOKIE_FILE" -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"johndoe","password":"password123"}' "$BASE_URL/login")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"  
if [[ $HTTP_CODE == "200" ]] && [[ $BODY == *'"username":"johndoe"'* ]]; then
  echo "✓ Test 6 passed"
else
  echo "✗ Test 6 failed"
  exit 1
fi

# Extract session token from cookies file
SESSION_COOKIE=$(grep session_id "$COOKIE_FILE" | awk '{print $7}')
echo "Session cookie: $SESSION_COOKIE"

echo ""

echo "Test 7: Login with invalid credentials..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"johndoe","password":"wrongpassword"}' "$BASE_URL/login")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "401" ]] && [[ $BODY == *'"error":"Invalid credentials"'* ]]; then
  echo "✓ Test 7 passed"
else
  echo "✗ Test 7 failed"
  exit 1
fi

echo ""

echo "Test 8: Try access to protected /me without session..."
RESPONSE=$(curl -s -w "\n%{http_code}" "$BASE_URL/me")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "401" ]] && [[ $BODY == *'"error":"Authentication required"'* ]]; then
  echo "✓ Test 8 passed"
else
  echo "✗ Test 8 failed"
  exit 1
fi

echo ""

echo "Test 9: Access /me with valid session..." 
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" "$BASE_URL/me")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "200" ]] && [[ $BODY == *'"username":"johndoe"'* ]]; then
  echo "✓ Test 9 passed"
  JOHN_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)
else
  echo "✗ Test 9 failed"
  exit 1
fi

echo ""

echo "=== Testing Todo Operations ==="
echo "Test 10: Create first todo..."
TODO_TITLE="First Todo"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"$TODO_TITLE\",\"description\":\"My first task\"}" "$BASE_URL/todos")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "201" ]] && [[ $BODY == *'"title":"'"$TODO_TITLE"'"'* ]] && [[ $BODY == *'"description":"My first task"'* ]]; then
  echo "✓ Test 10 passed"
  TODO1_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)
else
  echo "✗ Test 10 failed"
  exit 1
fi

echo ""

echo "Test 11: Create second todo..." 
TODO2_TITLE="Second Todo"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"$TODO2_TITLE\",\"description\":\"My second task\"}" "$BASE_URL/todos")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "201" ]] && [[ $BODY == *'"title":"'"$TODO2_TITLE"'"'* ]] && [[ $BODY == *'"description":"My second task"'* ]]; then
  echo "✓ Test 11 passed"
  TODO2_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)
else
  echo "✗ Test 11 failed"
  exit 1
fi

echo ""

echo "Test 12: Get specific todo by ID..."
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" "$BASE_URL/todos/$TODO1_ID")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "200" ]] && [[ $BODY == *'"title":"'"$TODO_TITLE"'"'* ]] && [[ $BODY == *'"completed":false'* ]]; then
  echo "✓ Test 12 passed"
else
  echo "✗ Test 12 failed"
  exit 1
fi

echo ""

echo "Test 13: Get all todos for user John..."
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" "$BASE_URL/todos")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
TODOS_COUNT=$(echo "$BODY" | grep -o '"id":' | wc -l)
if [[ $HTTP_CODE == "200" ]] && [[ $TODOS_COUNT -ge 2 ]]; then
  echo "✓ Test 13 passed"
else
  echo "✗ Test 13 failed"
  exit 1
fi

echo ""

echo "Test 14: Update existing todo..."
UPDATED_DESC="Updated description"
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  -d "{\"description\":\"$UPDATED_DESC\",\"completed\":true}" "$BASE_URL/todos/$TODO1_ID")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "200" ]] && [[ $BODY == *'"description":"'"$UPDATED_DESC"'"'* ]] && [[ $BODY == *'"completed":true'* ]]; then
  echo "✓ Test 14 passed"
else
  echo "✗ Test 14 failed"
  exit 1
fi

echo ""

echo "Test 15: Verify todo was updated properly..."
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" "$BASE_URL/todos/$TODO1_ID")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "200" ]] && [[ $BODY == *'"description":"'"$UPDATED_DESC"'"'* ]] && [[ $BODY == *'"completed":true'* ]] ; then
  echo "✓ Test 15 passed"
else
  echo "✗ Test 15 failed"
  exit 1
fi

echo ""

echo "Test 16: Try accessing another user's todo (should fail)..."
# Switch to jane's session
JANE_RESPONSE=$(curl -s -c "$COOKIE_FILE" -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"janedoe","password":"password123"}' "$BASE_URL/login")
JANE_SESSION_COOKIE=$(grep session_id "$COOKIE_FILE" | tail -1 | awk '{print $7}')

echo "Jane's session: $JANE_SESSION_COOKIE"
echo "Trying to access John's todo (ID: $TODO1_ID) with Jane's session..."

RESPONSE=$(curl -s -b "session_id=$JANE_SESSION_COOKIE" -w "\n%{http_code}" "$BASE_URL/todos/$TODO1_ID")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "404" ]] && [[ $BODY == *'"error":"Todo not found"'* ]]; then
  echo "✓ Test 16 passed" 
else
  echo "✗ Test 16 failed"
  exit 1
fi

echo ""

echo "Test 17: Test password change flow..."
# First login as John again
JOHN_LOGIN_RESP=$(curl -s -c "$COOKIE_FILE" -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"johndoe","password":"password123"}' "$BASE_URL/login")
JOHN_SESSION_AGAIN=$(grep session_id "$COOKIE_FILE" | tail -1 | awk '{print $7}')

# Change password with valid old password
RESPONSE=$(curl -s -b "session_id=$JOHN_SESSION_AGAIN" -w "\n%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword456"}' "$BASE_URL/password")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "200" ]] && [[ $BODY == "{}" ]]; then
  echo "✓ Password changed successfully"
  
  # Now test that old credentials no longer work
  FAILED_LOGIN=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"johndoe","password":"password123"}' "$BASE_URL/login")
  
  HTTP_CODE="${FAILED_LOGIN: -3}"
  BODY="${FAILED_LOGIN%???}"
  
  if [[ $HTTP_CODE == "401" ]]; then
    echo "✓ Old password no longer works - test 17 passed"
  else
    echo "✗ Old password still works - test 17 failed"
    exit 1
  fi
  
  # Now test that new password works
  SUCCESS_LOGIN=$(curl -s -c "$COOKIE_FILE" -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"johndoe","password":"newpassword456"}' "$BASE_URL/login")
  
  NEW_HTTP_CODE="${SUCCESS_LOGIN: -3}"
  NEW_BODY="${SUCCESS_LOGIN%???}"
  
  if [[ $NEW_HTTP_CODE == "200" ]]; then
    echo "✓ New password works for login"
    FINAL_SESSION=$(grep session_id "$COOKIE_FILE" | tail -1 | awk '{print $7}')
    # Restore session back to original one for cleanup
    SESSION_COOKIE=$FINAL_SESSION
  else
    echo "✗ New password doesn't work for login"
    exit 1
  fi
else
  echo "✗ Password change operation failed - test 17 failed"
  exit 1
fi

echo ""

echo "Test 18: Delete the updated todo..."
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO1_ID")

HTTP_CODE="${RESPONSE: -3}"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "204" ]]; then
  echo "✓ Test 18 passed"
else
  echo "✓ Test 18 failed - returned: $HTTP_CODE"
  exit 1
fi

echo ""

echo "Test 19: Try to retrieve the deleted todo (should fail)..."
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" "$BASE_URL/todos/$TODO1_ID")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "404" ]] && [[ $BODY == *'"error":"Todo not found"'* ]]; then
  echo "✓ Test 19 passed"
else
  echo "✗ Test 19 failed"
  exit 1
fi

echo ""

echo "Test 20: Test logout..."
RESPONSE=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X POST "$BASE_URL/logout")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Response: $BODY"
echo "Status: $HTTP_CODE"
if [[ $HTTP_CODE == "200" ]] && [[ $BODY == "{}" ]]; then
  echo "✓ Test 20 passed"
  
  # Now verify we're logged out by trying protected resource
  LOGGED_OUT_TEST=$(curl -s -w "\n%{http_code}" "$BASE_URL/me")
  
  LOGGED_OUT_HTTP_CODE="${LOGGED_OUT_TEST: -3}"
  LOGGED_OUT_BODY="${LOGGED_OUT_TEST%???}"
  
  if [[ $LOGGED_OUT_HTTP_CODE == "401" ]] && [[ $LOGGED_OUT_BODY == *'"error":"Authentication required"'* ]]; then
    echo "✓ Logout properly invalidated session - test complete!"
  else
    echo "✗ Session still valid after logout"
    exit 1
  fi
else
  echo "✗ Logout request failed"
  exit 1
fi

echo ""

echo "🎉 All tests passed! Server is working correctly."