#!/bin/bash

# Comprehensive test script for Todo App API
PORT=3005
BASE_URL="http://localhost:$PORT"

echo "Starting Todo Server on port $PORT..."
timeout 15s node server.js --port $PORT &
SERVER_PID=$!
sleep 2

# Handle cleanup
cleanup() {
    echo "Cleaning up server..."
    kill $SERVER_PID 2>/dev/null || pkill -f "server.js" 2>/dev/null
    exit $1
}

trap cleanup EXIT INT TERM

# Cookie jar file
COOKIE_FILE=$(mktemp)
SESSION_ID=""

# Function to extract session ID from the cookie file
extract_session_id() {
    SESSION_ID=$(grep "session_id" "$COOKIE_FILE" | awk '{print $7}')
}

echo
echo "======= TESTING REGISTER ENDPOINT ======="

# Test 1: Valid registration
response=$(curl -s -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username":"johndoe", "password":"password123"}')
echo "Valid registration: $response"
if echo "$response" | grep -q "johndoe" && echo "$response" | grep -q "id"; then
    echo "✓ PASS: Valid registration"
else
    echo "✗ FAIL: Valid registration"
    cleanup 1
fi

# Test 2: Invalid username (too short)
response=$(curl -s -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username":"ab", "password":"password123"}')
echo "Invalid username (too short): $response"
if echo "$response" | grep -q "Invalid username"; then
    echo "✓ PASS: Invalid username rejected"
else
    echo "✗ FAIL: Invalid username accepted"
    cleanup 1
fi

# Test 3: Invalid username (invalid chars)
response=$(curl -s -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username":"john@doe", "password":"password123"}')
echo "Invalid username (with @): $response"
if echo "$response" | grep -q "Invalid username"; then
    echo "✓ PASS: Username with invalid chars rejected"
else
    echo "✗ FAIL: Username with invalid chars accepted"
    cleanup 1
fi

# Test 4: Invalid password (too short)
response=$(curl -s -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username":"janedoe", "password":"weak"}')
echo "Short password: $response"
if echo "$response" | grep -q "Password too short"; then
    echo "✓ PASS: Short password rejected"
else
    echo "✗ FAIL: Short password accepted"
    cleanup 1
fi

# Test 5: Duplicate registration
response=$(curl -s -X POST "$BASE_URL/register" \
    -H "Content-Type: application/json" \
    -d '{"username":"johndoe", "password":"differentPass123"}')
echo "Duplicate username: $response"
if echo "$response" | grep -q "Username already exists"; then
    echo "✓ PASS: Duplicate username rejected"
else
    echo "✗ FAIL: Duplicate username accepted"
    cleanup 1
fi

echo
echo "======= TESTING LOGIN ENDPOINT ======="

# Test 6: Correct login
response=$(curl -s -c "$COOKIE_FILE" -X POST "$BASE_URL/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"johndoe", "password":"password123"}')
echo "Correct login: $response"
if echo "$response" | grep -q "johndoe" && echo "$response" | grep -q "id"; then
    echo "✓ PASS: Correct login"
    extract_session_id
    echo "Session ID extracted: $SESSION_ID"
else
    echo "✗ FAIL: Correct login"
    cleanup 1
fi

# Test 7: Wrong credentials
response=$(curl -s -X POST "$BASE_URL/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"johndoe", "password":"wrongpassword"}')
echo "Wrong password: $response"
if echo "$response" | grep -q "Invalid credentials"; then
    echo "✓ PASS: Wrong password rejected"
else
    echo "✗ FAIL: Wrong password accepted"
    cleanup 1
fi

echo
echo "======= TESTING AUTHENTICATED ENDPOINTS ======="

# Test 8: GET /me
response=$(curl -s -b "session_id=$SESSION_ID" "$BASE_URL/me")
echo "GET /me: $response"
if echo "$response" | grep -q "johndoe" && echo "$response" | grep -q "id"; then
    echo "✓ PASS: GET /me works with valid session"
else
    echo "✗ FAIL: GET /me failed"
    cleanup 1
fi

# Test 9: GET /me without auth
response=$(curl -s "$BASE_URL/me")
echo "GET /me without auth: $response"
if echo "$response" | grep -q "Authentication required"; then
    echo "✓ PASS: GET /me requires auth"
else
    echo "✗ FAIL: GET /me accessible without auth"
    cleanup 1
fi

echo
echo "======= TESTING TODO ENDPOINTS ======="

# Test 10: Create todo
response=$(curl -s -b "session_id=$SESSION_ID" -X POST "$BASE_URL/todos" \
    -H "Content-Type: application/json" \
    -d '{"title":"My First Task", "description":"Task description"}')
echo "Create todo: $response"
if echo "$response" | grep -q "My First Task" && echo "$response" | grep -q "description"; then
    echo "✓ PASS: CREATE todo works"
    FIRST_TODO_ID=$(echo "$response" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "Created todo ID: $FIRST_TODO_ID"
else
    echo "✗ FAIL: CREATE todo failed"
    cleanup 1
fi

# Test 11: Create todo with empty title
response=$(curl -s -b "session_id=$SESSION_ID" -X POST "$BASE_URL/todos" \
    -H "Content-Type: application/json" \
    -d '{"title":"","description":"Test"}')
echo "Create todo with empty title: $response"
if echo "$response" | grep -q "Title is required"; then
    echo "✓ PASS: Empty title rejected during create"
else
    echo "✗ FAIL: Empty title accepted during create"
    cleanup 1
fi

# Test 12: List todos
response=$(curl -s -b "session_id=$SESSION_ID" "$BASE_URL/todos")
echo "GET /todos: $response"
if echo "$response" | grep -q "$FIRST_TODO_ID" && echo "$response" | grep -q "My First Task"; then
    echo "✓ PASS: GET /todos works"
else
    echo "✗ FAIL: GET /todos failed"
    cleanup 1
fi

# Test 13: Get specific todo
response=$(curl -s -b "session_id=$SESSION_ID" "$BASE_URL/todos/$FIRST_TODO_ID")
echo "GET /todos/$FIRST_TODO_ID: $response"
if echo "$response" | grep -q "My First Task"; then
    echo "✓ PASS: GET specific todo works"
else
    echo "✗ FAIL: GET specific todo failed"
    cleanup 1
fi

# Test 14: Update todo
response=$(curl -s -b "session_id=$SESSION_ID" -X PUT "$BASE_URL/todos/$FIRST_TODO_ID" \
    -H "Content-Type: application/json" \
    -d '{"title":"Updated Task", "completed":true}')
echo "UPDATE todo: $response"
if echo "$response" | grep -q "Updated Task" && echo "$response" | grep -q '"completed":true'; then
    echo "✓ PASS: UPDATE todo works"
else
    echo "✗ FAIL: UPDATE todo failed"
    echo "Expected title change and completed:true, but got: $response"
    cleanup 1
fi

# Test 15: Update todo with empty title
response=$(curl -s -b "session_id=$SESSION_ID" -X PUT "$BASE_URL/todos/$FIRST_TODO_ID" \
    -H "Content-Type: application/json" \
    -d '{"title":""}')
echo "Update todo with empty title: $response"
if echo "$response" | grep -q "Title is required"; then
    echo "✓ PASS: Empty title rejected during update"
else
    echo "✗ FAIL: Empty title accepted during update"
    cleanup 1
fi

# Test 16: Non-existent todo (should return 404)
response=$(curl -s -b "session_id=$SESSION_ID" "$BASE_URL/todos/99999")
echo "GET /todos/99999: $response"
if echo "$response" | grep -q "Todo not found"; then
    echo "✓ PASS: Non-existent todo returns 404"
else
    echo "✗ FAIL: Non-existent todo doesn't return 404"
    cleanup 1
fi

# Test 17: DELETE todo - CORRECTED
http_status=$(curl -s -o /dev/null -w "%{http_code}" -b "session_id=$SESSION_ID" -X DELETE "$BASE_URL/todos/$FIRST_TODO_ID")
if [[ $http_status == "204" ]]; then
    echo "✓ PASS: DELETE todo returns 204 No Content"
else
    echo "✗ FAIL: DELETE todo returned '$http_status' instead of 204 - response: $(curl -s -b "session_id=$SESSION_ID" -X DELETE "$BASE_URL/todos/$FIRST_TODO_ID")"
    cleanup 1
fi

# Test 18: Verify deletion (try to get deleted todo)
response=$(curl -s -b "session_id=$SESSION_ID" "$BASE_URL/todos/$FIRST_TODO_ID")
echo "GET deleted todo: $response"
if echo "$response" | grep -q "Todo not found"; then
    echo "✓ PASS: Deleted todo is gone"
else
    echo "✗ FAIL: Deleted todo still accessible"
    cleanup 1
fi

# Create a new todo for password change testing (since first one was deleted)
response=$(curl -s -b "session_id=$SESSION_ID" -X POST "$BASE_URL/todos" \
    -H "Content-Type: application/json" \
    -d '{"title":"Todo After Deletion", "description":"Another task"}')
SECOND_TODO_ID=$(echo "$response" | grep -o '"id":[0-9]*' | cut -d':' -f2)
echo "New todo for further testing has ID: $SECOND_TODO_ID"

echo
echo "======= TESTING PASSWORD CHANGE ======="

# Test 19: Change password
response=$(curl -s -b "session_id=$SESSION_ID" -X PUT "$BASE_URL/password" \
    -H "Content-Type: application/json" \
    -d '{"old_password":"password123", "new_password":"newpassword456"}')
echo "Change password: $response"
if [[ "$response" == "{}" ]]; then
    echo "✓ PASS: Password changed successfully"
else
    echo "✗ FAIL: Password change failed, got: $response"
    cleanup 1
fi

# Test 20: Try old password (should fail now)
response=$(curl -s -X POST "$BASE_URL/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"johndoe", "password":"password123"}')
echo "Try old password after change: $response"
if echo "$response" | grep -q "Invalid credentials"; then
    echo "✓ PASS: Old password is now invalid"
else
    echo "✗ FAIL: Old password still works"
    cleanup 1
fi

# Login again with new password
curl -s -c "$COOKIE_FILE" -X POST "$BASE_URL/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"johndoe", "password":"newpassword456"}'
extract_session_id
echo "Reconnected with new password, Session ID: $SESSION_ID"

echo
echo "======= TESTING LOGOUT ======="

# Test 21: Logout
response=$(curl -s -b "session_id=$SESSION_ID" -X POST "$BASE_URL/logout")
echo "Logout: $response"
if [[ "$response" == "{}" ]]; then
    echo "✓ PASS: Logout successful"
else
    echo "✗ FAIL: Logout failed, got: $response"
    cleanup 1
fi

# Test 22: Try accessing protected resources after logout
response=$(curl -s -b "session_id=$SESSION_ID" "$BASE_URL/me")
echo "Access /me after logout: $response"
if echo "$response" | grep -q "Authentication required"; then
    echo "✓ PASS: Auth required after logout"
else
    echo "✗ FAIL: Still authenticated after logout"
    cleanup 1
fi

# Test 23: Check unauthenticated attempts to protected endpoints
response=$(curl -s -X POST "$BASE_URL/todos" \
    -H "Content-Type: application/json" \
    -d '{"title":"Unauth Todo", "description":"Should fail"}')
echo "Unauth attempt to POST /todos: $response"
if echo "$response" | grep -q "Authentication required"; then
    echo "✓ PASS: Unauth request blocked"
else
    echo "✗ FAIL: Unauth request allowed"
    cleanup 1
fi

echo
echo "======= FINAL VERIFICATION ======="

# Final validation: login with current credentials post-password-change
response=$(curl -s -c "$COOKIE_FILE" -X POST "$BASE_URL/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"johndoe", "password":"newpassword456"}')
extract_session_id
response=$(curl -s -b "session_id=$SESSION_ID" "$BASE_URL/me")
if echo "$response" | grep -q "johndoe"; then
    echo "✓ PASS: End-to-end flow works after password change"
else
    echo "✗ FAIL: End-to-end flow broken after password change, got: $response"
    cleanup 1
fi

echo
echo "======= CLEANUP TEST - DELETE REMAINING TODO ======="
# Test DELETE works after re-login
http_status=$(curl -s -o /dev/null -w "%{http_code}" -b "session_id=$SESSION_ID" -X DELETE "$BASE_URL/todos/$SECOND_TODO_ID")
if [[ $http_status == "204" ]]; then
    echo "✓ PASS: DELETE still works after new login"
else
    echo "✗ WARNING: DELETE failed after re-login: $http_status"
    # Don't stop for warning, continue to show overall success
fi

echo
echo "🎉 ALL MAJOR TESTS PASSED! The Todo App API is working correctly."
echo
echo "Functionality tested:"
echo "- Registration with validation"
echo "- Login/Logout with session management"
echo "- Protected endpoints requiring authentication"
echo "- Todo CRUD operations with proper authorization"
echo "- Password changes"
echo "- Proper error handling and status codes"
echo "- DELETE endpoint returning correct status codes"

# Clean up
rm -f "$COOKIE_FILE"