#!/bin/bash

# Test script for Todo App server API
# Note: This requires that the server is running on localhost:8080

SERVER_URL="localhost:8080"
COOKIES_FILE=$(mktemp)

echo "Starting tests for Todo App server..."

# Test registration
echo "Testing registration..."
NEW_USER_ID=$(curl -s -X POST http://$SERVER_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "securepassword"}' \
  -c $COOKIES_FILE | jq -r '.id')

if [ "$NEW_USER_ID" != "null" ] && [ -n "$NEW_USER_ID" ]; then
    echo "✓ Registration successful - User ID: $NEW_USER_ID"
else
    echo "✗ Registration failed"
    exit 1
fi

# Test login
echo "Testing login..."
LOGIN_RESULT=$(curl -s -X POST http://$SERVER_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "securepassword"}' \
  -b $COOKIES_FILE)

if echo "$LOGIN_RESULT" | jq -e '.id' >/dev/null 2>&1; then
    echo "✓ Login successful"
else
    echo "✗ Login failed: $LOGIN_RESULT"
    exit 1
fi

# Test get user info
echo "Testing get user info (/me)..."
ME_RESULT=$(curl -s -X GET http://$SERVER_URL/me \
  -b $COOKIES_FILE)

EXPECTED_ID=$(echo "$ME_RESULT" | jq -r '.id')
if [ "$EXPECTED_ID" = "$NEW_USER_ID" ]; then
    echo "✓ Get user info successful - User ID matches"
else
    echo "✗ Get user info failed - IDs don't match: expected $NEW_USER_ID, got $EXPECTED_ID"
    exit 1
fi

# Create a todo
echo "Testing creating a todo..."
TODO_DATA=$(curl -s -X POST http://$SERVER_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "First todo", "description": "My first task"}' \
  -b $COOKIES_FILE)

NEW_TODO_ID=$(echo "$TODO_DATA" | jq -r '.id')
if [ "$NEW_TODO_ID" != "null" ] && [ -n "$NEW_TODO_ID" ]; then
    echo "✓ Todo creation successful - Todo ID: $NEW_TODO_ID"
else
    echo "✗ Todo creation failed"
    exit 1
fi

# Test getting specific todo
echo "Testing getting specific todo..."
RETRIEVED_TODO=$(curl -s -X GET http://$SERVER_URL/todos/$NEW_TODO_ID \
  -b $COOKIES_FILE)

TODO_TITLE=$(echo "$RETRIEVED_TODO" | jq -r '.title')
if [ "$TODO_TITLE" = "First todo" ]; then
    echo "✓ Get specific todo successful"
else
    echo "✗ Get specific todo failed: title '$TODO_TITLE' doesn't match 'First todo'"
    exit 1
fi

# Test updating the todo
echo "Testing updating the todo..."
UPDATED_TODO=$(curl -s -X PUT http://$SERVER_URL/todos/$NEW_TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated todo", "completed": true}' \
  -b $COOKIES_FILE)

UPDATED_TITLE=$(echo "$UPDATED_TODO" | jq -r '.title')
UPDATED_COMPLETED=$(echo "$UPDATED_TODO" | jq -r '.completed')
if [ "$UPDATED_TITLE" = "Updated todo" ] && [ "$UPDATED_COMPLETED" = "true" ]; then
    echo "✓ Todo update successful"
else
    echo "✗ Todo update failed: title='$UPDATED_TITLE', completed='$UPDATED_COMPLETED'"
    exit 1
fi

# Test listing todos
echo "Testing listing all todos..."
TODO_LIST=$(curl -s -X GET http://$SERVER_URL/todos \
  -b $COOKIES_FILE)
LIST_COUNT=$(echo "$TODO_LIST" | jq -s 'length')
if [ "$LIST_COUNT" -ge 1 ]; then
    echo "✓ List todos successful - Found $LIST_COUNT todo(s)"
else
    echo "✗ List todos failed"
    exit 1
fi

# Test changing password
echo "Testing change password..."
CHANGE_PWD_RESULT=$(curl -s -X PUT http://$SERVER_URL/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "securepassword", "new_password": "newsecurepassword"}' \
  -b $COOKIES_FILE)

if echo "$CHANGE_PWD_RESULT" | jq -e '.' >/dev/null 2>&1; then
    echo "✓ Password change successful"
else
    echo "✗ Password change failed"
    exit 1
fi

# Try to log in with new password and verify we can still access user info
# First logout current session
curl -s -X POST http://$SERVER_URL/logout -b $COOKIES_FILE -c $COOKIES_FILE >/dev/null

# Log back in with new password
LOGIN_WITH_NEW_PWD=$(curl -s -X POST http://$SERVER_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newsecurepassword"}' \
  -b $COOKIES_FILE -c $COOKIES_FILE)

if echo "$LOGIN_WITH_NEW_PWD" | jq -e '.id' >/dev/null 2>&1; then
    echo "✓ Re-login with new password successful"
else
    echo "✗ Re-login with new password failed"
    exit 1
fi

# Verify we can still get our user info
NEW_ME_RESULT=$(curl -s -X GET http://$SERVER_URL/me -b $COOKIES_FILE)
NEW_EXPECTED_ID=$(echo "$NEW_ME_RESULT" | jq -r '.id')
if [ "$NEW_EXPECTED_ID" = "$NEW_USER_ID" ]; then
    echo "✓ Access to user info with new password successful"
else
    echo "✗ Access to user info with new password failed"
    exit 1
fi

# Test deleting the created todo
echo "Testing deleting the todo..."
DELETE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE http://$SERVER_URL/todos/$NEW_TODO_ID -b $COOKIES_FILE)

if [ "$DELETE_STATUS" -eq 204 ]; then
    echo "✓ Todo deletion successful"
else
    echo "✗ Todo deletion failed - Status: $DELETE_STATUS"
    exit 1
fi

# Try to get that todo again (should fail now)
GET_DELETED_TODO=$(curl -s -w "\n%{http_code}" -X GET http://$SERVER_URL/todos/$NEW_TODO_ID -b $COOKIES_FILE)
DELETED_STATUS=$(echo "$GET_DELETED_TODO" | tail -n1)
if [ "$DELETED_STATUS" -eq 404 ]; then
    echo "✓ Deleted todo cannot be retrieved (404 as expected)"
else
    echo "✗ Deleted todo can still be retrieved!"
    exit 1
fi

# Test unauthorized access to protected endpoints
echo "Testing unauthorized access..."
BAD_SESSION_FILE=$(mktemp)
UNAUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X GET http://$SERVER_URL/me -b $BAD_SESSION_FILE)
if [ "$UNAUTH_STATUS" -eq 401 ]; then
    echo "✓ Unauthorized access correctly blocked"
else
    echo "✗ Unauthorized access NOT blocked - Status: $UNAUTH_STATUS"
fi

# Cleanup
rm -f $COOKIES_FILE $BAD_SESSION_FILE
echo "All tests passed successfully!"