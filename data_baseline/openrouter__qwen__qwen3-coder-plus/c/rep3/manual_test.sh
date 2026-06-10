#!/bin/bash
echo 'Testing simple server functionality...'

# Clean up if running
killall -q server 2>/dev/null || true
sleep 1

# Start server in the background with timeout
( timeout 25s ./server -p 8080 2>/dev/null ) &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Give server time to initialize
sleep 3

# Verify server is running 
if ! ps -p $SERVER_PID >/dev/null; then
    echo 'FAIL: Server did not start properly'
    exit 1
fi

echo 'Server started. Running tests...'

# Test registration
echo '1. Testing register endpoint...'
RES=$(curl -s http://localhost:8080/register -X POST -H "Content-Type: application/json" -d '{"username":"testing","password":"password123"}')
echo "REGISTER response: "
echo "$RES"
if [[ "$RES" == *'"id":'* && "$RES" == *'"username":"testing"'* ]]; then
    echo '✓ Registration working'
else
    echo '✗ Registration failed'
    exit 1
fi

echo ''
# Test login and get session
echo '2. Testing login and session...'
echo '(Capturing cookies to temp file)'
curl -s -c /tmp/session_cookie.txt -X POST \
    -H "Content-Type: application/json" \
    -d '{"username":"testing","password":"password123"}' \
    http://localhost:8080/login

SESSIONID=$(awk '/session_id/ {print $7}' /tmp/session_cookie.txt | head -n 1)
echo "Extracted session ID: $SESSIONID"

if [ -n "$SESSIONID" ]; then
    echo '✓ Login successful, session cookie captured'
else
    echo '✗ Login failed or session cookie not set'
    exit 1 
fi

echo ''
# Test /me with session
echo '3. Testing /me endpoint with session cookie...'
ME_RES=$(curl -s -b session_id='$SESSIONID' http://localhost:8080/me)
echo "ME response: $ME_RES"
if [[ "$ME_RES" == *'"username":"testing"'* && "$ME_RES" != *'Authentication required'* ]]; then
    echo '✓ /me endpoint working with valid session'
else
    echo '✗ /me endpoint failed with valid session'
    exit 1
fi

echo ''
# Test creating a todo
echo '4. Testing todo creation...'
TODO_RES=$(curl -s -b session_id='$SESSIONID' -X POST \
    -H "Content-Type: application/json" \
    -d '{"title":"Test Todo","description":"A test to-do item"}' \
    http://localhost:8080/todos)
echo "CREATE TODO response: $TODO_RES"
TODO_ID=$(echo "$TODO_RES" | grep -o '"id":[0-9]*' | cut -d':' -f2)
echo "Created todo with ID: $TODO_ID"

if [[ -n "$TODO_ID" && "$TODO_RES" == *'"title":"Test Todo"'* ]]; then
    echo '✓ Todo creation working'
else
    echo '✗ Todo creation failed'
    exit 1
fi

echo ''
# Test getting the todo
echo '5. Testing getting a specific todo...'
GET_TODO_RES=$(curl -s -b session_id='$SESSIONID' http://localhost:8080/todos/$TODO_ID)
echo "GET TODO response: $GET_TODO_RES"

if [[ "$GET_TODO_RES" == *'"title":"Test Todo"'* ]]; then
    echo '✓ Getting specific todo working'
else
    echo '✗ Getting specific todo failed'
    exit 1
fi

echo ''
# Test updating the todo
echo '6. Testing todo update...'
UPDATE_RES=$(curl -s -b session_id='$SESSIONID' -X PUT \
    -H "Content-Type: application/json" \
    -d '{"title":"Updated Test Todo", "completed":true}' \
    http://localhost:8080/todos/$TODO_ID)
echo "UPDATE TODO response: $UPDATE_RES"

if [[ "$UPDATE_RES" == *'"title":"Updated Test Todo"'* && "$UPDATE_RES" == *'"completed":true'* ]]; then
    echo '✓ Todo update working'
else
    echo '✗ Todo update failed'
    exit 1
fi

echo ''
# Test listing todos  
echo '7. Testing list all todos...'
LIST_RES=$(curl -s -b session_id='$SESSIONID' http://localhost:8080/todos)
echo "LIST TODOS response: $LIST_RES"

if [[ "$LIST_RES" == *'[{'*"Updated Test Todo"*'}]' && "$LIST_RES" == *'"completed":true'* ]]; then
    echo '✓ Todo list working'
else
    echo '✗ Todo list failed'
    exit 1
fi

echo ''
# Test deleting the todo
echo '8. Testing todo deletion...'
DEL_RES_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b session_id='$SESSIONID' -X DELETE http://localhost:8080/todos/$TODO_ID)
echo "DELETE response code: $DEL_RES_CODE"

if [[ "$DEL_RES_CODE" == "204" ]]; then
    echo '✓ Todo deletion working'
else
    echo '✗ Todo deletion failed'
    exit 1
fi

echo ''
# Test logout
echo '9. Testing logout...'
LOGOUT_RES=$(curl -s -b session_id='$SESSIONID' -X POST http://localhost:8080/logout)
echo "LOGOUT response: $LOGOUT_RES"

if [[ "$LOGOUT_RES" == '{}' ]]; then
    echo '✓ Logout endpoint working'
    
    # Confirm user is signed out by trying /me
    ME_AFT_LOGOUT=$(curl -s -b session_id='$SESSIONID' -w "\n%{http_code}" http://localhost:8080/me)
    HTTP_CODE="${ME_AFT_LOGOUT: -3}"
    
    if [[ "$HTTP_CODE" == "401" ]]; then
        echo '✓ Session properly invalidated'
    else
        echo '✗ Session not properly invalidated after logout'
    fi
else
    echo '✗ Logout failed'
    exit 1
fi

echo ''
echo '🎉 All basic functionality tests passed!'
echo 'Shutting down server...'

# Kill server process
kill $SERVER_PID 2>/dev/null || true
sleep 1

if ps -p $SERVER_PID 2>/dev/null; then
    kill -KILL $SERVER_PID 2>/dev/null
    sleep 1
fi

echo 'Cleanup complete.'