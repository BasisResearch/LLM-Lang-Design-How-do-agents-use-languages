#!/bin/bash

# Test script for Todo API server

# Configuration
PORT=8080
SERVER_URL="http://localhost:$PORT"
SESSION_COOKIE_FILE="/tmp/todo_session_test_$$.txt"
LOG_FILE="/tmp/todo_log_$$.log"

# Cleanup functions
cleanup() {
    if [ ! -z "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null
    fi
    rm -f $SESSION_COOKIE_FILE
    rm -f $LOG_FILE
}
trap cleanup EXIT

echo "Starting server on port $PORT..."
node server.ts --port $PORT > $LOG_FILE 2>&1 &
SERVER_PID=$!
sleep 2

# Function to make requests and extract cookie
make_request() {
    local method=$1
    local endpoint=$2
    local data=$3
    local expected_status=$4
    shift 4
    
    local curl_args=("-s" "-w" "\n%{http_code}")
    if [ -n "$data" ]; then
        curl_args+=("-d" "$data")
    fi
    if [ -f "$SESSION_COOKIE_FILE" ] && [ -s "$SESSION_COOKIE_FILE" ]; then
        curl_args+=("-b" "$SESSION_COOKIE_FILE")
    fi
    if [ "$method" != "GET" ]; then
        curl_args+=("-X" "$method")
        if [ "$method" == "POST" ] || [ "$method" == "PUT" ]; then
            curl_args+=("-H" "Content-Type: application/json")
        fi
    fi
    
    local response
    response=$(curl "${curl_args[@]}" "$SERVER_URL$endpoint" | sed '$ d' | tr -d '\r\n')
    local status_code=$(curl "${curl_args[@]}" "$SERVER_URL$endpoint" | tail -1)
    
    # Extract and save session cookie if present
    if [ -n "$(curl -s -D - "${curl_args[@]}" "$SERVER_URL$endpoint" | grep -i 'set-cookie')" ]; then
        curl -s -c "$SESSION_COOKIE_FILE" -o /dev/null \
             $(if [ -n "$data" ]; then echo "-d $data"; fi) \
             $(if [ -n "$*" ]; then echo "$*"; fi) \
             $(if [ "$method" != "GET" ]; then echo "-X $method"; fi) \
             "$SERVER_URL$endpoint" \
             -H 'Content-Type: application/json'
    fi
    
    echo "$response|$status_code"
}

# Function to validate JSON response
validate_json_response() {
    local response_data=$1
    local expected_status=$2
    local expected_keys=$3
    
    IFS='|' read -r json_resp response_status <<< "$response_data"
    
    if [ "$response_status" -ne "$expected_status" ]; then
        echo "FAILED: Expected status $expected_status, got $response_status"
        echo "Response: $json_resp"
        return 1
    fi
    
    # Additional validation for JSON keys if specified
    if [ -n "$expected_keys" ]; then
        for key in $expected_keys; do
            if ! echo "$json_resp" | jq -e ".\"$key\"" >/dev/null 2>&1; then
                echo "FAILED: Expected key '$key' not found in response: $json_resp"
                return 1
            fi
        done
    fi
    
    echo "$json_resp"
    return 0
}

echo "Testing API endpoints..."

# Test 1: Register a new user
echo "Test 1: Register user with valid credentials"
response=$(make_request "POST" "/register" '{"username": "testuser", "password": "password123"}' "201")
json_response=$(validate_json_response "$response" "201" "id username")
if [ $? -ne 0 ]; then
    echo "Registration test failed"
    exit 1
else
    TEST_USER_ID=$(echo "$json_response" | jq -r '.id')
    echo "User registered successfully with ID: $TEST_USER_ID"
fi

# Test 2: Register with invalid username
echo "Test 2: Register with invalid username"
response=$(make_request "POST" "/register" '{"username": "inv", "password": "password123"}' "400")
validate_json_response "$response" "400" "error" || { echo "Invalid username test failed"; exit 1; }
echo "Invalid username properly rejected"

# Test 3: Register user with existing username
echo "Test 3: Register duplicate username"
response=$(make_request "POST" "/register" '{"username": "testuser", "password": "password123"}' "409")
validate_json_response "$response" "409" "error" || { echo "Duplicate username test failed"; exit 1; }
echo "Duplicate username properly rejected"

# Test 4: Login with correct credentials
echo "Test 4: Login with valid credentials"
response=$(make_request "POST" "/login" '{"username": "testuser", "password": "password123"}' "200")
json_response=$(validate_json_response "$response" "200" "id username")
if [ $? -ne 0 ]; then
    echo "Login test failed"
    exit 1
else
    echo "Login successful"
fi

# Test 5: Access protected endpoint (/me) after login
echo "Test 5: Access user profile after login"
response=$(make_request "GET" "/me" "" "200")
json_response=$(validate_json_response "$response" "200" "id username")
if [ $? -ne 0 ]; then
    echo "Profile access test failed"
    exit 1
else
    USER_ID=$(echo "$json_response" | jq -r '.id')
    echo "User profile accessed: $USER_ID"
fi

# Test 6: Try accessing protected endpoint without login
rm -f $SESSION_COOKIE_FILE
echo "Test 6: Access protected endpoint without login"
response=$(make_request "GET" "/me" "" "401")
validate_json_response "$response" "401" "error" || { echo "Unauthenticated access test failed"; exit 1; }
echo "Unauthenticated access properly rejected"

# Test 7: Login again to continue testing
response=$(make_request "POST" "/login" '{"username": "testuser", "password": "password123"}' "200")
validate_json_response "$response" "200" "id username" || { echo "Re-login test failed"; exit 1; }
echo "Re-login successful"

# Test 8: Create a new todo
echo "Test 8: Create a new todo"
response=$(make_request "POST" "/todos" '{"title": "First Task", "description": "My first todo item"}' "201")
json_response=$(validate_json_response "$response" "201" "id title description completed created_at updated_at")
if [ $? -ne 0 ]; then
    echo "Create todo test failed"
    exit 1
else
    TODO_ID=$(echo "$json_response" | jq -r '.id')
    echo "Todo created successfully with ID: $TODO_ID"
fi

# Test 9: Create a todo with missing title
echo "Test 9: Create todo with missing title"
response=$(make_request "POST" "/todos" '{"description": "Should have title"}' "400")
validate_json_response "$response" "400" "error" || { echo "Missing title test failed"; exit 1; }
echo "Create todo with missing title properly rejected"

# Test 10: Get all todos
echo "Test 10: Get all todos"
response=$(make_request "GET" "/todos" "" "200")
json_response=$(validate_json_response "$response" "200" "")
if [ $? -ne 0 ]; then
    echo "Get all todos test failed"
    exit 1
else
    TODO_COUNT=$(echo "$json_response" | jq 'length')
    echo "Retrieved $TODO_COUNT todos"
fi

# Test 11: Get a specific todo by ID
echo "Test 11: Get specific todo by ID $TODO_ID"
response=$(make_request "GET" "/todos/$TODO_ID" "" "200")
json_response=$(validate_json_response "$response" "200" "id title description completed created_at updated_at")
if [ $? -ne 0 ]; then
    echo "Get specific todo test failed"
    exit 1
else
    TODO_TITLE=$(echo "$json_response" | jq -r '.title')
    echo "Retrieved todo \"$TODO_TITLE\""
fi

# Test 12: Try to get a non-existent todo
echo "Test 12: Try to get non-existent todo"
NON_EXISTENT_ID=$((TODO_ID + 100))
response=$(make_request "GET" "/todos/$NON_EXISTENT_ID" "" "404")
validate_json_response "$response" "404" "error" || { echo "Non-existent todo test failed"; exit 1; }
echo "Non-existent todo properly responded with 404"

# Test 13: Update a todo
echo "Test 13: Update a specific todo by ID $TODO_ID"
UPDATE_PAYLOAD='{"title": "Updated Task Title", "completed": true}'
response=$(make_request "PUT" "/todos/$TODO_ID" "$UPDATE_PAYLOAD" "200")
json_response=$(validate_json_response "$response" "200" "id title description completed created_at updated_at")
if [ $? -ne 0 ]; then
    echo "Update todo test failed"
    exit 1
else
    UPDATED_TITLE=$(echo "$json_response" | jq -r '.title')
    UPDATED_COMPLETED=$(echo "$json_response" | jq -r '.completed')
    echo "Todo updated, new title: $UPDATED_TITLE, completed: $UPDATED_COMPLETED"
fi

# Test 14: Try to update with invalid data
echo "Test 14: Try to update with empty title"
UPDATE_PAYLOAD='{"title": "", "completed": false}'
response=$(make_request "PUT" "/todos/$TODO_ID" "$UPDATE_PAYLOAD" "400")
validate_json_response "$response" "400" "error" || { echo "Empty title update test failed"; exit 1; }
echo "Updating with empty title properly rejected"

# Test 15: Delete the todo
echo "Test 15: Delete specific todo by ID $TODO_ID"
response=$(make_request "DELETE" "/todos/$TODO_ID" "" "204")
if [ $? -ne 0 ]; then
    echo "Delete todo test failed"
    exit 1
else
    echo "Todo deleted successfully"
fi

# Test 16: Try to get the deleted todo
echo "Test 16: Try to get deleted todo"
response=$(make_request "GET" "/todos/$TODO_ID" "" "404")
validate_json_response "$response" "404" "error" || { echo "Accessed deleted todo test failed"; exit 1; }
echo "Deleted todo properly returns 404"

# Test 17: Change password with wrong old password
echo "Test 17: Try to change password with wrong old password"
PASSWORD_UPDATE_PAYLOAD='{"old_password": "wrong_password", "new_password": "newpassword123"}'
response=$(make_request "PUT" "/password" "$PASSWORD_UPDATE_PAYLOAD" "401")
validate_json_response "$response" "401" "error" || { echo "Wrong password change test failed"; exit 1; }
echo "Password update with wrong old password properly rejected"

# Test 18: Change password with valid old password
echo "Test 18: Change password with valid old password"
PASSWORD_UPDATE_PAYLOAD='{"old_password": "password123", "new_password": "newpassword123"}'
response=$(make_request "PUT" "/password" "$PASSWORD_UPDATE_PAYLOAD" "200")
validate_json_response "$response" "200" "" || { echo "Valid password change test failed"; exit 1; }
echo "Password updated successfully"

# Test 19: Logout
echo "Test 19: Logout user"
response=$(make_request "POST" "/logout" "" "200")
validate_json_response "$response" "200" "" || { echo "Logout test failed"; exit 1; }
echo "Logged out successfully"

# Test 20: Try to access profile after logout
echo "Test 20: Try to access profile after logout"
response=$(make_request "GET" "/me" "" "401")
validate_json_response "$response" "401" "error" || { echo "Post-logout access test failed"; exit 1; }
echo "Properly prevented access after logout (401)"

echo ""
echo "All tests passed! 🎉"
kill $SERVER_PID 2>/dev/null