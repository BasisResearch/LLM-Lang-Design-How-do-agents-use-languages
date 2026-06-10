#!/bin/bash

# Test script for the Todo API
set -e  # Exit on any error

echo "Starting test server on port 54321..."
PORT=54321
node server.js --port $PORT &
SERVER_PID=$!
sleep 2

# Function to check if server is up
check_server_ready () {
    for i in {1..10}; do
        if curl -f -s --connect-timeout 2 "http://localhost:$PORT/me" &>/dev/null; then
            return 0
        fi
        sleep 1
    done
    echo "Server not responding!"
    kill $SERVER_PID
    exit 1
}

check_server_ready
echo "Server is ready"

# Clean up function
cleanup_and_exit() {
    echo "Cleaning up server process..."
    kill $SERVER_PID
    exit $1
}

# Trap to ensure cleanup happens
trap cleanup_and_exit EXIT

COOKIE_JAR=$(mktemp)
JQ_AVAILABLE="true"
if ! command -v jq &>/dev/null; then
    JQ_AVAILABLE="false"
    echo "jq not available, falling back to manual parsing"
fi

# Test variables
TEST_USERNAME="test_user_$(date +%s)"
TEST_PASSWORD="password123"

# Utility function to make API requests and extract cookie
make_request_with_cookie() {
    local method=$1
    local endpoint=$2
    local data=$3
    
    if [ -n "$data" ]; then
        curl -X $method \
             -H "Content-Type: application/json" \
             -d "$data" \
             -c $COOKIE_JAR -b $COOKIE_JAR -s \
             "http://localhost:$PORT$endpoint" \
             --connect-timeout 5
    else
        curl -X $method \
             -H "Content-Type: application/json" \
             -c $COOKIE_JAR -b $COOKIE_JAR -s \
             "http://localhost:$PORT$endpoint" \
             --connect-timeout 5
    fi
}

# Alternative without jq if not available
get_json_field() {
    local field=$1
    local json=$2
    if [ "$JQ_AVAILABLE" = "true" ]; then
        echo "$json" | jq -r ".$field" 2>/dev/null || echo ""
    else
        # Simple regex-based extraction
        echo "$json" | sed -n "s/.*\"$field\":\"\([^\",}]*\)\".*/\1/p" | head -1
    fi
}

get_numeric_field() {
    local field=$1
    local json=$2
    if [ "$JQ_AVAILABLE" = "true" ]; then
        echo "$json" | jq -r ".$field" 2>/dev/null || echo ""
    else
        # Simple regex-based extraction for numeric values
        echo "$json" | sed -n "s/.*\"$field\":\([0-9]*\).*/\1/p" | head -1
    fi
}

echo "=== Testing Registration ==="
RESPONSE=$(make_request_with_cookie POST "/register" "{\"username\":\"$TEST_USERNAME\",\"password\":\"$TEST_PASSWORD\"}")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"username\":\"$TEST_USERNAME\",\"password\":\"$TEST_PASSWORD\"}" "http://localhost:$PORT/register")

if [ "$HTTP_CODE" != "201" ]; then
    echo "❌ Registration failed. Expected 201, got $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi

# Extract user id from response
USER_ID=$(get_numeric_field "id" "$RESPONSE")
ACTUAL_USERNAME=$(get_json_field "username" "$RESPONSE")

if [ -z "$USER_ID" ] || [ "$ACTUAL_USERNAME" != "$TEST_USERNAME" ]; then
    echo "❌ Registration returned invalid response"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✅ Registration successful (user_id: $USER_ID)"

# Test registration with existing username
RESPONSE=$(make_request_with_cookie POST "/register" "{\"username\":\"$TEST_USERNAME\",\"password\":\"differentpass\"}")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"username\":\"$TEST_USERNAME\",\"password\":\"differentpass\"}" "http://localhost:$PORT/register")

if [ "$HTTP_CODE" != "409" ] || ! echo "$RESPONSE" | grep -q "Username already exists"; then
    echo "❌ Duplicate registration test failed"
    echo "Expected 409, got $HTTP_CODE, response: $RESPONSE"
    exit 1
fi

echo "✅ Duplicate username rejection works"

# Test login
echo "=== Testing Login ==="
RESPONSE=$(make_request_with_cookie POST "/login" "{\"username\":\"$TEST_USERNAME\",\"password\":\"$TEST_PASSWORD\"}")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"username\":\"$TEST_USERNAME\",\"password\":\"$TEST_PASSWORD\"}" -c temp_cookie "http://localhost:$PORT/login")

if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ Login failed. Expected 200, got $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi

LOGIN_USER_ID=$(get_numeric_field "id" "$RESPONSE")
LOGIN_USERNAME=$(get_json_field "username" "$RESPONSE")

if [ "$LOGIN_USER_ID" != "$USER_ID" ] || [ "$LOGIN_USERNAME" != "$TEST_USERNAME" ]; then
    echo "❌ Login returned wrong user info"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✅ Login successful"

# Test invalid login
RESPONSE=$(make_request_with_cookie POST "/login" "{\"username\":\"$TEST_USERNAME\",\"password\":\"wrongpass\"}")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"username\":\"$TEST_USERNAME\",\"password\":\"wrongpass\"}" "http://localhost:$PORT/login")

if [ "$HTTP_CODE" != "401" ] || ! echo "$RESPONSE" | grep -q "Invalid credentials"; then
    echo "❌ Invalid login test failed"
    echo "Expected 401, got $HTTP_CODE, response: $RESPONSE"
    exit 1
fi

echo "✅ Invalid login rejection works"

# Test /me endpoint
echo "=== Testing /me endpoint ==="
RESPONSE=$(make_request_with_cookie GET "/me" "")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -s -b $COOKIE_JAR -b $COOKIE_JAR "http://localhost:$PORT/me")

if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ /me endpoint failed. Expected 200, got $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi

ME_USER_ID=$(get_numeric_field "id" "$RESPONSE")
ME_USERNAME=$(get_json_field "username" "$RESPONSE")

if [ "$ME_USER_ID" != "$USER_ID" ] || [ "$ME_USERNAME" != "$TEST_USERNAME" ]; then
    echo "❌ /me endpoint returned wrong user info"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✅ /me endpoint works"

# Test access without auth
NO_AUTH_RESPONSE=$(curl -s -X GET "http://localhost:$PORT/me")
NO_AUTH_CODE=$(curl -o /dev/null -w "%{http_code}" -s -X GET "http://localhost:$PORT/me")

if [ "$NO_AUTH_CODE" != "401" ] || ! echo "$NO_AUTH_RESPONSE" | grep -q "Authentication required"; then
    echo "❌ Unauthenticated access protection failed"
    echo "Expected 401, got $NO_AUTH_CODE, response: $NO_AUTH_RESPONSE"
    exit 1
fi

echo "✅ Unauthenticated access properly blocked"

# Test password change
echo "=== Testing Password Change ==="
NEW_PASSWORD="newpassword456"

RESPONSE=$(make_request_with_cookie PUT "/password" "{\"old_password\":\"$TEST_PASSWORD\", \"new_password\":\"$NEW_PASSWORD\"}")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/json" -d "{\"old_password\":\"$TEST_PASSWORD\", \"new_password\":\"$NEW_PASSWORD\"}" -b $COOKIE_JAR "http://localhost:$PORT/password")

if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ Password change failed. Expected 200, got $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✅ Password change successful"

# Test wrong old password fails
RESPONSE=$(make_request_with_cookie PUT "/password" "{\"old_password\":\"wrongoldpass\", \"new_password\":\"evennewerpass\"}")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/json" -d "{\"old_password\":\"wrongoldpass\", \"new_password\":\"evennewerpass\"}" -b $COOKIE_JAR "http://localhost:$PORT/password")

if [ "$HTTP_CODE" != "401" ] || ! echo "$RESPONSE" | grep -q "Invalid credentials"; then
    echo "❌ Wrong password check failed"
    echo "Expected 401, got $HTTP_CODE, response: $RESPONSE"
    exit 1
fi

echo "✅ Wrong password properly rejected"

# Test todo operations
echo "=== Testing Todo Operations ==="

# Initially should be empty
RESPONSE=$(make_request_with_cookie GET "/todos" "")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -s -b $COOKIE_JAR "http://localhost:$PORT/todos")

if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ GET /todos failed. Expected 200, got $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi

TODO_COUNT=$(echo "$RESPONSE" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "${RESPONSE//[^\\[]/}" | wc -c)
if [ "$JQ_AVAILABLE" = "true" ]; then
    TODO_COUNT=$(echo "$RESPONSE" | jq 'length')
else
    # Count using basic parsing
    TODO_COUNT=$(echo "$RESPONSE" | tr ',' '\n' | wc -l)
    if [ "$RESPONSE" = "[]" ]; then
        TODO_COUNT=0
    fi
fi

if [ "$TODO_COUNT" -ne 0 ]; then
    echo "❌ Initial todo list not empty"
    exit 1
fi

echo "✅ Initially empty todo list"

# Create a todo
TODO_TITLE="Test Todo $(date +%s)"
TODO_DESC="This is a test description"
RESPONSE=$(make_request_with_cookie POST "/todos" "{\"title\":\"$TODO_TITLE\", \"description\":\"$TODO_DESC\"}")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "{\"title\":\"$TODO_TITLE\", \"description\":\"$TODO_DESC\"}" -b $COOKIE_JAR "http://localhost:$PORT/todos")

if [ "$HTTP_CODE" != "201" ]; then
    echo "❌ Create todo failed. Expected 201, got $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi

NEW_TODO_ID=$(get_numeric_field "id" "$RESPONSE")
NEW_TODO_TITLE=$(get_json_field "title" "$RESPONSE")
NEW_TODO_DESC=$(get_json_field "description" "$RESPONSE")
NEW_TODO_COMPLETED=$(get_json_field "completed" "$RESPONSE")
NEW_TODO_CREATED_AT=$(get_json_field "created_at" "$RESPONSE")
NEW_TODO_UPDATED_AT=$(get_json_field "updated_at" "$RESPONSE")

if [ -z "$NEW_TODO_ID" ] || [ "$NEW_TODO_TITLE" != "$TODO_TITLE" ] || [ "$NEW_TODO_DESC" != "$TODO_DESC" ] || [ "$NEW_TODO_COMPLETED" != "false" ]; then
    echo "❌ Created todo has wrong data"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✅ Todo creation successful (id: $NEW_TODO_ID)"

# Get the newly created todo
RESPONSE=$(make_request_with_cookie GET "/todos/$NEW_TODO_ID" "")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -s -b $COOKIE_JAR "http://localhost:$PORT/todos/$NEW_TODO_ID")

if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ Get single todo failed. Expected 200, got $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi

FETCHED_TODO_TITLE=$(get_json_field "title" "$RESPONSE")
if [ "$FETCHED_TODO_TITLE" != "$TODO_TITLE" ]; then
    echo "❌ Fetched todo has wrong data"
    echo "Expected: $TODO_TITLE, Got: $FETCHED_TODO_TITLE"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✅ Single todo retrieval successful"

# Try to get a non-existent todo
NON_EXISTENT_ID=$((NEW_TODO_ID + 100))
RESPONSE=$(make_request_with_cookie GET "/todos/$NON_EXISTENT_ID" "")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -s -b $COOKIE_JAR "http://localhost:$PORT/todos/$NON_EXISTENT_ID")

if [ "$HTTP_CODE" != "404" ] || ! echo "$RESPONSE" | grep -q "Todo not found"; then
    echo "❌ Non-existent todo access test failed"
    echo "Expected 404, got $HTTP_CODE, response: $RESPONSE"
    exit 1
fi

echo "✅ Non-existent todo properly returns 404"

# Attempt illegal modifications to existing todo without authentication
# First logout
make_request_with_cookie POST "/logout" ""
echo "✅ Logout successful"

# Then try to access todo
RESPONSE=$(curl -s -X GET "http://localhost:$PORT/todos/$NEW_TODO_ID")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -s -X GET "http://localhost:$PORT/todos/$NEW_TODO_ID")

if [ "$HTTP_CODE" != "401" ] || ! echo "$RESPONSE" | grep -q "Authentication required"; then
    echo "❌ Unauthorized access protection failed"
    echo "Expected 401, got $HTTP_CODE, response: $RESPONSE"
    exit 1
fi

echo "✅ Todo access without auth properly blocked"

# Login again for further testing
curl -s -X POST -H "Content-Type: application/json" -d "{\"username\":\"$TEST_USERNAME\",\"password\":\"$NEW_PASSWORD\"}" -c $COOKIE_JAR "http://localhost:$PORT/login" > /dev/null
echo "✅ Re-login successful after password change"

# Test updating the todo (partial update)
UPDATED_TITLE="Updated Todo Title"
RESPONSE=$(make_request_with_cookie PUT "/todos/$NEW_TODO_ID" "{\"title\":\"$UPDATED_TITLE\"}")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/json" -d "{\"title\":\"$UPDATED_TITLE\"}" -b $COOKIE_JAR "http://localhost:$PORT/todos/$NEW_TODO_ID")

if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ Update todo failed. Expected 200, got $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi

UPDATED_TODO_TITLE=$(get_json_field "title" "$RESPONSE")
UPDATED_TODO_DESC=$(get_json_field "description" "$RESPONSE")

if [ "$UPDATED_TODO_TITLE" != "$UPDATED_TITLE" ] || [ "$UPDATED_TODO_DESC" != "$TODO_DESC" ]; then
    echo "❌ Updated todo has wrong data"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✅ Partial todo update successful"

# Test setting completed flag
RESPONSE=$(make_request_with_cookie PUT "/todos/$NEW_TODO_ID" "{\"completed\":true}")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/json" -d "{\"completed\":true}" -b $COOKIE_JAR "http://localhost:$PORT/todos/$NEW_TODO_ID")

if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ Setting completed flag failed. Expected 200, got $HTTP_CODE"
    echo "Response: $RESPONSE"
    exit 1
fi

UPDATED_TODO_COMPLETED=$(get_json_field "completed" "$RESPONSE")
if [ "$UPDATED_TODO_COMPLETED" != "true" ]; then
    echo "❌ Completed flag was not set"
    echo "Response: $RESPONSE"
    exit 1
fi

echo "✅ Setting completed flag successful"

# Test invalid update (empty title)
try_invalid_update() {
    RESPONSE=$(make_request_with_cookie PUT "/todos/$NEW_TODO_ID" "{\"title\":\"\"}")
    HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X PUT -H "Content-Type: application/json" -d "{\"title\":\"\"}" -b $COOKIE_JAR "http://localhost:$PORT/todos/$NEW_TODO_ID")

    if [ "$HTTP_CODE" != "400" ] || ! echo "$RESPONSE" | grep -q "Title is required"; then
        echo "❌ Empty title validation during update failed"
        echo "Expected 400, got $HTTP_CODE, response: $RESPONSE"
        exit 1
    fi
}

try_invalid_update    
echo "✅ Empty title during update properly rejected"

# Test deletion
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X DELETE -b $COOKIE_JAR "http://localhost:$PORT/todos/$NEW_TODO_ID")

if [ "$HTTP_CODE" != "204" ]; then
    echo "❌ Todo deletion failed. Expected 204, got $HTTP_CODE"
    exit 1
fi

echo "✅ Todo deletion successful"

# Verify the todo no longer exists
RESPONSE=$(make_request_with_cookie GET "/todos/$NEW_TODO_ID" "")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -s -b $COOKIE_JAR "http://localhost:$PORT/todos/$NEW_TODO_ID")

if [ "$HTTP_CODE" != "404" ] || ! echo "$RESPONSE" | grep -q "Todo not found"; then
    echo "❌ Deleted todo still accessible"
    echo "Expected 404, got $HTTP_CODE, response: $RESPONSE"
    exit 1
fi

echo "✅ Deleted todo properly inaccessible"

# Final test: create multiple todos and verify list order
CREATE_RESPONSE1=$(make_request_with_cookie POST "/todos" "{\"title\":\"Test Todo A\", \"description\":\"First in sequence\"}")
ID1=$(get_numeric_field "id" "$CREATE_RESPONSE1")

CREATE_RESPONSE2=$(make_request_with_cookie POST "/todos" "{\"title\":\"Test Todo B\", \"description\":\"Second in sequence\"}")
ID2=$(get_numeric_field "id" "$CREATE_RESPONSE2")

GET_TODOS_RESPONSE=$(make_request_with_cookie GET "/todos" "")

# The first item (with smaller ID) goes first
FIRST_ITEM_TITLE=$(echo "$GET_TODOS_RESPONSE" | jq -r '.[0].title' 2>/dev/null) || FIRST_ITEM_TITLE=$(echo "$GET_TODOS_RESPONSE" | sed -n 's/.*"title":"\([^"],*\)".*/\1/p;s/.*"title":"\([^"]*\)"}/\1/p' | head -1)
SECOND_ITEM_TITLE=$(echo "$GET_TODOS_RESPONSE" | jq -r '.[1].title' 2>/dev/null) || SECOND_ITEM_TITLE=$(echo "$GET_TODOS_RESPONSE" | sed -n 's/.*"title":"\([^"],*\)".*/\1/p;s/.*"title":"\([^"]*\)"}.*/\1/p' | tail -n +2 | head -1)

if [ "$FIRST_ITEM_TITLE" != "Test Todo A" ] || [ "$SECOND_ITEM_TITLE" != "Test Todo B" ]; then
    echo "❌ Todos not returned in ascending ID order"
    echo "First item: $FIRST_ITEM_TITLE"
    echo "Second item: $SECOND_ITEM_TITLE"
    echo "Full response: $GET_TODOS_RESPONSE"
    exit 1
fi

echo "✅ Todos returned in correct order (by ID asc)"

# Cleanup created todos
curl -s -X DELETE -b $COOKIE_JAR "http://localhost:$PORT/todos/$ID1" > /dev/null
curl -s -X DELETE -b $COOKIE_JAR "http://localhost:$PORT/todos/$ID2" > /dev/null

# Test logout
RESPONSE=$(make_request_with_cookie POST "/logout" "")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -X POST -b $COOKIE_JAR -s "http://localhost:$PORT/logout")

if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ Logout failed. Expected 200, got $HTTP_CODE"
    exit 1
fi

echo "✅ Logout successful"

# Try to access protected resource after logout
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"title\":\"Post-logout todo\"}" -b $COOKIE_JAR "http://localhost:$PORT/todos")
HTTP_CODE=$(curl -o /dev/null -w "%{http_code}" -s -X POST -H "Content-Type: application/json" -d "{\"title\":\"Post-logout todo\"}" -b $COOKIE_JAR "http://localhost:$PORT/todos")

if [ "$HTTP_CODE" != "401" ]; then
    echo "❌ Session invalidated after logout test failed. Access should be forbidden after logout."
    exit 1
fi

echo "✅ Session properly invalidated after logout"

echo 
echo "🎉 All tests passed! The API implementation appears to be correct."