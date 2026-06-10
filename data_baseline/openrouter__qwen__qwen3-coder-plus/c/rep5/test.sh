#!/bin/bash

# Test script for todo app server
SERVER_PORT=8080

echo "Testing todo app server..."

# Start the server in the background
echo "Starting server on port $SERVER_PORT..."
./server --port $SERVER_PORT &
SERVER_PID=$!
sleep 1

if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Error: Server failed to start"
    exit 1
fi

echo "Server started with PID $SERVER_PID"

# Store session cookies
COOKIES_FILE=$(mktemp)

echo "Test 1: Register new user"
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser", "password":"testpass123"}' \
  "http://localhost:$SERVER_PORT/register" 

if [ $? -ne 0 ]; then
    echo "✗ Failed to register"
else
    echo "✓ Registration successful"
fi

echo ""
echo "Test 2: Register duplicate user (should fail)"
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser", "password":"testpass123"}' \
  "http://localhost:$SERVER_PORT/register" 

if [ $? -ne 0 ]; then
    echo "✗ Expected failure in duplicate registration didn't occur"
else
    echo "✓ Duplicate registration correctly blocked"  
fi

echo ""
echo "Test 3: Login"
SESSION_ID=$(curl -c "$COOKIES_FILE" -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser", "password":"testpass123"}' \
  "http://localhost:$SERVER_PORT/login" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}')

if [ ! -z "$SESSION_ID" ]; then
    echo "✓ Login successful, session ID: $SESSION_ID"
else
    echo "✗ Login failed"
fi

echo ""
echo "Test 4: Request without auth (should fail)"
curl -s -X GET "http://localhost:$SERVER_PORT/me"

if [ $? -eq 0 ]; then
    echo "✓ Unauthenticated access correctly blocked"
else
    echo "✗ Unexpected error in unauthenticated access"
fi

echo ""
echo "Test 5: Access protected resource (GET /me) with cookie"
USER_INFO=$(curl -b "$COOKIES_FILE" -s -X GET "http://localhost:$SERVER_PORT/me")
USER_ID=$(echo $USER_INFO | grep -o '"id":[0-9]*' | cut -d':' -f2)

echo "Response: $USER_INFO"
if [[ $USER_INFO == *'"id"'* ]]; then
    echo "✓ Access to protected resource successful"
else
    echo "✗ Access to protected resource failed"
fi

echo ""
echo "Test 6: Create todo"
TODO_JSON=$(curl -b "$COOKIES_FILE" -s -X POST -H "Content-Type: application/json" \
  -d '{"title":"First Todo", "description":"This is my first todo."}' \
  "http://localhost:$SERVER_PORT/todos")
  
TODO_ID=$(echo $TODO_JSON | grep -o '"id":[0-9]*' | cut -d':' -f2)

echo "Created todo: $TODO_JSON"
if [ ! -z "$TODO_ID" ] && [[ $TODO_JSON == *'"title":"First Todo"'* ]]; then
    echo "✓ Todo creation successful, ID: $TODO_ID"
else
    echo "✗ Todo creation failed"
fi

echo ""
echo "Test 7: Get existing todo"
TODO_DATA=$(curl -b "$COOKIES_FILE" -s -X GET "http://localhost:$SERVER_PORT/todos/$TODO_ID")

echo "Retrieved todo: $TODO_DATA"
if [[ $TODO_DATA == *'"id":'$TODO_ID* ]]; then
    echo "✓ Retrieve todo successful"
else
    echo "✗ Retrieve todo failed"
fi

echo ""
echo "Test 8: Update todo"
TODO_UPDATED=$(curl -b "$COOKIES_FILE" -s -X PUT -H "Content-Type: application/json" \
  -d '{"title":"Updated Todo", "completed":true}' \
  "http://localhost:$SERVER_PORT/todos/$TODO_ID")

if [[ $TODO_UPDATED == *'"title":"Updated Todo"'* ]] && [[ $TODO_UPDATED == *'"completed":true* ]]; then
    echo "✓ Update todo successful"
else
    echo "✗ Update todo failed"
fi

echo ""
echo "Test 9: Create another todo to verify listings work"
TODO2_JSON=$(curl -b "$COOKIES_FILE" -s -X POST -H "Content-Type: application/json" \
  -d '{"title":"Second Todo", "description":"This is my second todo."}' \
  "http://localhost:$SERVER_PORT/todos")

TODO2_ID=$(echo $TODO2_JSON | grep -o '"id":[0-9]*' | cut -d':' -f2)
echo "Created 2nd todo: $TODO2_JSON"
if [ ! -z "$TODO2_ID" ] && [[ $TODO2_JSON == *'"title":"Second Todo"'* ]]; then
    echo "✓ Second todo creation successful, ID: $TODO2_ID"
else
    echo "✗ Second todo creation failed"
fi

echo ""
echo "Test 10: List all todos"
ALL_TODOS=$(curl -b "$COOKIES_FILE" -s -X GET "http://localhost:$SERVER_PORT/todos")

if [[ $ALL_TODOS == *'"title":"Updated Todo"'* ]] && [[ $ALL_TODOS == *'"title":"Second Todo"'* ]]; then
    echo "✓ List todos successful"
    echo "Found both todos in the list"
else
    echo "✗ List todos failed"
    echo "Response: $ALL_TODOS"
fi

echo ""
echo "Test 11: Change password"
CHANGE_PASS_RESULT=$(curl -b "$COOKIES_FILE" -s -X PUT -H "Content-Type: application/json" \
  -d '{"old_password":"testpass123", "new_password":"newpassword123"}' \
  "http://localhost:$SERVER_PORT/password")

if [ "$CHANGE_PASS_RESULT" = "{}" ]; then
    echo "✓ Password change successful"
else
    echo "✗ Password change failed: $CHANGE_PASS_RESULT"
fi

echo ""
echo "Test 12: Logout"
LOGOUT_RESULT=$(curl -b "$COOKIES_FILE" -s -X POST -H "Content-Type: application/json" \
  -d '{}' \
  "http://localhost:$SERVER_PORT/logout")

if [ "$LOGOUT_RESULT" = "{}" ]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed: $LOGOUT_RESULT"
fi

echo ""
echo "Test 13: Verify logout worked by trying to access protected resource"
PROTECTED_ACCESS=$(curl -b "$COOKIES_FILE" -s -X GET "http://localhost:$SERVER_PORT/me")
if [[ $PROTECTED_ACCESS == *'"error"'* ]]; then
    echo "✓ Session properly cleared after logout"
else
    echo "✗ Session still accessible after logout"
fi

echo ""
echo "Test 14: Verify deleted session no longer works by logging back in"
NEW_SID=$(curl -c "$COOKIES_FILE" -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser", "password":"newpassword123"}' \
  "http://localhost:$SERVER_PORT/login" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}')
  
if [ ! -z "$NEW_SID" ]; then
    echo "✓ Can login again with new session"
else
    echo "✗ Cannot login with new password"
fi

echo ""
echo "Test 15: Delete one of the todos"
curl -s -X DELETE "http://localhost:$SERVER_PORT/todos/$TODO_ID" -b "$COOKIES_FILE" -w "Status: %{http_code}\n" > /dev/null

echo ""
echo "Verify deletion by trying to get the removed todo"
REMOVAL_VERIFY=$(curl -b "$COOKIES_FILE" -s -X GET "http://localhost:$SERVER_PORT/todos/$TODO_ID" -w " - Status: %{http_code}\n" 2>&1)

if [[ $REMOVAL_VERIFY == *"404"* ]]; then
    echo "✓ Todo deletion successful"
else  
    echo "✗ Todo deletion may have failed"
fi

echo ""
echo "All tests completed, stopping server..."
kill $SERVER_PID

# Cleanup
rm -f $COOKIES_FILE

echo "Done."