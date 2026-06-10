#!/bin/bash
set -e

# Start server in background
echo "Starting server on port 5000..."
./run.sh --port 5000 &
SERVER_PID=$!
sleep 3  # Wait for server to start

# Clean exit function
cleanup() {
    echo "Stopping server..."
    kill $SERVER_PID
    wait $SERVER_PID
}
trap cleanup EXIT

BASE_URL="http://localhost:5000"
COOKIE_FILE=$(mktemp)
SESSION_COOKIE_HEADER=""

echo "Testing API endpoints..."

# Test 1: POST /register
echo "1. Testing /register"
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    "$BASE_URL/register")
echo "Registration response: $response"
expected='{"id":1,"username":"testuser"}'
if [[ $response != *"testuser"* ]]; then
    echo "FAIL: Registration failed"
    exit 1
else
    echo "OK: Registration successful"
fi

# Save cookies for later use
curl -c "$COOKIE_FILE" -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    "$BASE_URL/login" > /dev/null

SESSION_COOKIE=$(grep session_id "$COOKIE_FILE" | awk '{print $7}')
if [[ -z "$SESSION_COOKIE" ]]; then
    # In case cURL doesn't store to file properly, extract from header
    SESSION_COOKIE_HEADER=$(curl -s -D - -X POST -H "Content-Type: application/json" \
        -d '{"username":"testuser","password":"password123"}' \
        "$BASE_URL/login" | grep -i "Set-Cookie" | cut -d' ' -f2 | cut -d';' -f1 | cut -d'=' -f2)
    if [[ -n "$SESSION_COOKIE_HEADER" ]]; then 
        SESSION_COOKIE="$SESSION_COOKIE_HEADER"
    fi
fi

echo "Session ID: $SESSION_COOKIE"

# Test 2: POST /login
echo "2. Testing /login"
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -b "session_id=$SESSION_COOKIE" \
    -d '{"username":"testuser","password":"password123"}' \
    "$BASE_URL/login")
echo "Login response: $response"
if [[ $response == *"error"* ]]; then
    echo "FAIL: Login failed - $response"
    exit 1
else
    echo "OK: Login successful"
fi

# Test 3: GET /me (with session cookie)
echo "3. Testing /me"
response=$(curl -s -H "Cookie: session_id=$SESSION_COOKIE" "$BASE_URL/me")
echo "Me response: $response" 
if [[ $response == *"testuser"* ]]; then 
    echo "OK: Get me successful"
else
    echo "FAIL: Get me failed - $response"
    exit 1
fi

# Test 4: PUT /password (change password)
echo "4. Testing /password"
response=$(curl -s -X PUT -H "Content-Type: application/json" \
    -H "Cookie: session_id=$SESSION_COOKIE" \
    -d '{"old_password":"password123","new_password":"newpassword456"}' \
    "$BASE_URL/password")
echo "Change password response: $response"
if [[ $response != *"{}}"* ]]; then
    echo "FAIL: Password change failed - $response"
    exit 1
else
    echo "OK: Password change successful"
fi

# Test 5: Verify new password works in login
echo "5. Testing login with new password"
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"newpassword456"}' \
    "$BASE_URL/login")
echo "New password login: $response"
if [[ $response == *"error"* ]]; then
    echo "FAIL: New password doesn't work - $response"
    exit 1
else
    echo "OK: New password login successful"
fi

# Log back in with new password to get new session
NEW_SESSION_COOKIE=$(curl -s -D - -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"newpassword456"}' \
    "$BASE_URL/login" | grep -i "Set-Cookie" | cut -d' ' -f2 | cut -d';' -f1 | cut -d'=' -f2)

echo "New Session ID: $NEW_SESSION_COOKIE"

# Test 6: GET /todos (should be empty initially) 
echo "6. Testing /todos GET"
response=$(curl -s -H "Cookie: session_id=$NEW_SESSION_COOKIE" "$BASE_URL/todos")
echo "Todos response: $response"
if [[ "$response" == "[]" ]]; then
    echo "OK: Get todos returned empty array"
else
    echo "FAIL: Get todos should be empty - $response" 
    exit 1
fi

# Test 7: POST /todos (create todo)
echo "7. Testing /todos POST"
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -H "Cookie: session_id=$NEW_SESSION_COOKIE" \
    -d '{"title":"First Todo","description":"My first todo item"}' \
    "$BASE_URL/todos")
echo "Create todo response: $response"
if [[ $response == *"First Todo"* ]]; then
    echo "OK: Create todo successful"
else
    echo "FAIL: Create todo failed - $response"
    exit 1
fi

TODO_ID=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

# Test 8: GET /todos (should have newly created todo)
echo "8. Testing /todos GET"
response=$(curl -s -H "Cookie: session_id=$NEW_SESSION_COOKIE" "$BASE_URL/todos")
echo "Todos response: $response"
if [[ $response == *"$TODO_ID"* && $response == *"First Todo"* ]]; then
    echo "OK: Get todos includes new todo"
else
    echo "FAIL: Get todos doesn't include new todo - $response"
    exit 1
fi

# Test 9: Get specific todo with GET /todos/:id
echo "9. Testing /todos/$TODO_ID GET"
response=$(curl -s -H "Cookie: session_id=$NEW_SESSION_COOKIE" "$BASE_URL/todos/$TODO_ID")
echo "Specific todo response: $response"
if [[ $response == *"First Todo"* ]]; then
    echo "OK: Get specific todo successful"
else
    echo "FAIL: Get specific todo failed - $response"
    exit 1
fi

# Test 10: PUT /todos/:id (update todo)
echo "10. Testing /todos/$TODO_ID PUT"
response=$(curl -s -X PUT -H "Content-Type: application/json" \
    -H "Cookie: session_id=$NEW_SESSION_COOKIE" \
    -d '{"title":"Updated Todo","completed":true}' \
    "$BASE_URL/todos/$TODO_ID")
echo "Update todo response: $response"
if [[ $response == *"Updated Todo"* && $response == *"true"* ]]; then
    echo "OK: Update todo successful"
else
    echo "FAIL: Update todo failed - $response"
    exit 1
fi

# Test 11: DELETE /todos/:id 
echo "11. Testing /todos/$TODO_ID DELETE"
response=$(curl -si -X DELETE -H "Cookie: session_id=$NEW_SESSION_COOKIE" "$BASE_URL/todos/$TODO_ID")
echo "Delete todo status: $?"
if [[ $response == *"204"* || $(echo "$response" | grep -c "HTTP/1.1 204") -ge 1 ]]; then
    echo "OK: Delete todo successful (status 204)"
else
    echo "FAIL: Delete todo failed"
    exit 1
fi

# Ensure todo was actually deleted
echo "Confirming deletion..."
response=$(curl -s -H "Cookie: session_id=$NEW_SESSION_COOKIE" "$BASE_URL/todos/$TODO_ID")
if [[ $response == *"Todo not found"* ]]; then
    echo "OK: Todo was successfully deleted"
else
    echo "FAIL: Todo still exists after deletion - $response"
    exit 1
fi

# Test 12: POST /logout
echo "12. Testing /logout"
response=$(curl -s -X POST -H "Cookie: session_id=$NEW_SESSION_COOKIE" "$BASE_URL/logout")
echo "Logout response: $response"
if [[ $response == *"{}}"* ]]; then
    echo "OK: Logout successful"
else
    echo "FAIL: Logout failed - $response"
    exit 1
fi

# Test protected endpoint after logout (should fail)
echo "13. Testing protected endpoint after logout"
response=$(curl -s -H "Cookie: session_id=$NEW_SESSION_COOKIE" "$BASE_URL/me")
echo "Me after logout response: $response"
if [[ $response == *"Authentication required"* ]]; then
    echo "OK: Authentication correctly required after logout"
else
    echo "FAIL: Should require authentication after logout - $response"
    exit 1
fi

echo ""
echo "All tests passed successfully!"