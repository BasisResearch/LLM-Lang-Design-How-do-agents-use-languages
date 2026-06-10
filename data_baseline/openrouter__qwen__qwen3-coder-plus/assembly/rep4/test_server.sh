#!/bin/bash

# Test script for Todo API Server
# Verifies all endpoints work correctly

PORT=${PORT:-8080}
BASE_URL="http://localhost:${PORT}"

echo "Testing Todo API Server on ${BASE_URL}..."

# Start server in background
echo "Starting server..."
timeout 30s ./todo_server --port $PORT &
SERVER_PID=$!
sleep 2  # Wait for server to start

# Cleanup function
cleanup() {
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
}

# Trap to cleanup on exit
trap cleanup EXIT

# Test variables
SESSION_COOKIE=""
TEST_USER_ID=""
TEST_TODO_ID=""

# Function to extract session cookie
extract_session() {
    echo "$1" | grep -i "set-cookie:" | sed 's/Set-Cookie: session_id=\([^;]*\);.*/\1/' | head -1
}

echo "Test 1: POST /register - Valid registration"
response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser", "password":"password123"}' \
    "${BASE_URL}/register")
status="${response: -3}"
body="${response%???}"
if [[ $status == "201" && "$body" == *"\"id\""* && "$body" == *"\"username\":\"testuser\""* ]]; then
    TEST_USER_ID=$(echo "$body" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
    echo "✓ Registration successful, user ID: $TEST_USER_ID"
else
    echo "✗ Registration failed. Status: $status, Response: $body"
    exit 1
fi

echo "Test 2: POST /register - Duplicate username"
response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser", "password":"password123"}' \
    "${BASE_URL}/register")
status="${response: -3}"
body="${response%???}"
if [[ $status == "409" && "$body" == *"\"error\":\"Username already exists\""* ]]; then
    echo "✓ Duplicate registration blocked correctly"
else
    echo "✗ Duplicate registration should be blocked. Status: $status, Response: $body"
    exit 1
fi

echo "Test 3: POST /login - Valid credentials"
response=$(curl -s -c cookie.tmp -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser", "password":"password123"}' \
    "${BASE_URL}/login")
status="${response: -3}"
body="${response%???}"
if [[ $status == "200" && "$body" == *"\"id\":\"$TEST_USER_ID\""* && -s cookie.tmp ]]; then
    SESSION_COOKIE=$(grep "session_id" cookie.tmp | awk '{print $7}')
    echo "✓ Login successful, session: ${SESSION_COOKIE:0:10}..."
else
    echo "✗ Login failed. Status: $status, Response: $body, Cookie file empty: $(if [ ! -s cookie.tmp ]; then echo "YES"; else echo "NO"; fi)"
    exit 1
fi

echo "Test 4: GET /me - With valid session"
response=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" \
    "${BASE_URL}/me")
status="${response: -3}"
body="${response%???}"
if [[ $status == "200" && "$body" == *"\"id\":\"$TEST_USER_ID\""* && "$body" == *"\"username\":\"testuser\""* ]]; then
    echo "✓ GET /me successful"
else
    echo "✗ GET /me failed. Status: $status, Response: $body"
    exit 1
fi

echo "Test 5: GET /me - Without session (should fail)"
response=$(curl -s -w "\n%{http_code}" "${BASE_URL}/me")
status="${response: -3}"
body="${response%???}"
if [[ $status == "401" && "$body" == *"\"error\":\"Authentication required\""* ]]; then
    echo "✓ Authentication required for /me - correctly blocked"
else
    echo "✗ Authentication should be required for /me. Status: $status, Response: $body"
    exit 1
fi

echo "Test 6: POST /todos - Create a new todo"
response=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"title":"Test Task", "description":"Test Description"}' \
    "${BASE_URL}/todos")
status="${response: -3}"
body="${response%???}"
if [[ $status == "201" && "$body" == *"\"id\""* && "$body" == *"\"title\":\"Test Task\""* ]]; then
    TEST_TODO_ID=$(echo "$body" | grep -o '"id":[0-9]*' | grep -o '[0-9]*' | head -1)
    echo "✓ Created todo with ID: $TEST_TODO_ID"
else
    echo "✗ Failed to create todo. Status: $status, Response: $body"
    exit 1
fi

echo "Test 7: GET /todos - List user's todos"
response=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" \
    "${BASE_URL}/todos")  
status="${response: -3}"
body="${response%???}"
if [[ $status == "200" && "$body" == "["*"]"* ]]; then
    echo "✓ Retrieved todo list successfully"
else
    echo "✗ Failed to retrieve todo list. Status: $status, Response: $body"
    exit 1
fi

echo "Test 8: GET /todos/:id - Get specific todo"
response=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" \
    "${BASE_URL}/todos/$TEST_TODO_ID")
status="${response: -3}"
body="${response%???}"
if [[ $status == "200" && "$body" == *"\"id\":$TEST_TODO_ID"* ]]; then
    echo "✓ Retrieved specific todo successfully"
else
    echo "✗ Failed to retrieve specific todo. Status: $status, Response: $body"
    exit 1
fi

echo "Test 9: PUT /todos/:id - Update todo"
response=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X PUT \
    -H "Content-Type: application/json" \
    -d '{"title":"Updated Task", "completed":true}' \
    "${BASE_URL}/todos/$TEST_TODO_ID")
status="${response: -3}"
body="${response%???}"
if [[ $status == "200" && "$body" == *"\"id\":$TEST_TODO_ID"* && "$body" == *"\"title\":\"Updated Task\""* ]]; then
    echo "✓ Updated todo successfully"
else
    echo "✗ Failed to update todo. Status: $status, Response: $body"
    exit 1
fi

echo "Test 10: PUT /password - Change password"
response=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X PUT \
    -H "Content-Type: application/json" \
    -d '{"old_password":"password123", "new_password":"newpassword456"}' \
    "${BASE_URL}/password")
status="${response: -3}"
body="${response%???}"
if [[ $status == "200" && "$body" == *"{}"* ]]; then
    echo "✓ Password changed successfully"
else
    echo "✗ Failed to change password. Status: $status, Response: $body"
    exit 1
fi

echo "Test 11: POST /logout - Logout user"
response=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" -X POST \
    "${BASE_URL}/logout")
status="${response: -3}"
body="${response%???}"
if [[ $status == "200" ]]; then
    echo "✓ Logout successful"
else
    echo "✗ Failed to logout. Status: $status, Response: $body"
    exit 1
fi

echo "Test 12: GET /me - After logout (should fail)"
response=$(curl -s -b "session_id=$SESSION_COOKIE" -w "\n%{http_code}" \
    "${BASE_URL}/me")
status="${response: -3}"
body="${response%???}"
if [[ $status == "401" && "$body" == *"\"error\":\"Authentication required\""* ]]; then
    echo "✓ Session properly invalidated after logout"
else
    echo "✗ Session should be invalidated after logout. Status: $status, Response: $body"
    exit 1
fi

echo "Test 13: POST /login - With new password"
response=$(curl -s -c cookie2.tmp -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser", "password":"newpassword456"}' \
    "${BASE_URL}/login")
status="${response: -3}"
body="${response%???}"
if [[ $status == "200" && "$body" == *"\"id\":\"$TEST_USER_ID\""* ]]; then
    echo "✓ Login with new password successful"
else
    echo "✗ Failed login with new password. Status: $status, Response: $body"
    exit 1
fi

# Extract new session for final tests
NEW_SESSION=$(grep "session_id" cookie2.tmp | awk '{print $7}')

echo "Test 14: DELETE /todos/:id - Delete todo"
response=$(curl -s -b "session_id=$NEW_SESSION" -w "\n%{http_code}" -X DELETE \
    "${BASE_URL}/todos/$TEST_TODO_ID")
status="${response: -3}"
body="${response%???}"
if [[ $status == "204" ]]; then
    echo "✓ Todo deleted successfully"
else
    echo "✗ Failed to delete todo. Status: $status, Response: $body"
    exit 1
fi

echo "Test 15: GET /todos/:id - Deleted todo (should fail)"
response=$(curl -s -b "session_id=$NEW_SESSION" -w "\n%{http_code}" \
    "${BASE_URL}/todos/$TEST_TODO_ID")
status="${response: -3}"
body="${response%???}"
if [[ $status == "404" && "$body" == *"\"error\":\"Todo not found\""* ]]; then
    echo "✓ Deleted todo correctly not found"
else
    echo "✗ Deleted todo should not be accessible. Status: $status, Response: $body"
    exit 1
fi

echo ""
echo "=================================="
echo "ALL TESTS PASSED! 🎉"
echo "=================================="
echo "API Endpoints tested successfully:"
echo "- POST /register"
echo "- POST /login"  
echo "- GET /me"
echo "- PUT /password"
echo "- GET /todos"
echo "- POST /todos"
echo "- GET /todos/:id"
echo "- PUT /todos/:id"
echo "- DELETE /todos/:id"
echo "- POST /logout"
echo "=================================="

cleanup
rm -f cookie*.tmp