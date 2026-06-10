#!/bin/bash

# Comprehensive test script for the Todo API server

set -e

# Configuration
PORT="${TEST_PORT:-8080}"
BASE_URL="http://localhost:$PORT"
SERVER_LOG="server_test.log"

# Start server in background
echo "Compiling and starting server on port $PORT..."

# Build and run server in background
nohup ./run.sh --port $PORT > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Give the server some time to start
sleep 2

# Test variables
TEST_USER="testuser123"
TEST_PASSWORD="password1234"
NEW_PASSWORD="newpassword5678"
TODO_TITLE="Test Todo Item"
TODO_DESC="Description of test todo item"
SESSION_COOKIE=""

echo "Server started with PID $SERVER_PID"

# Utility function to send requests
send_request() {
    local method=$1
    local endpoint=$2
    local data=$3
    local headers=("${@:4}")
    
    curl -s -w "\n%{http_code}\n" \
         -X "$method" \
         "${headers[@]}" \
         -H "Content-Type: application/json" \
         --data "$data" \
         "$BASE_URL$endpoint"
}

# Utility to extract cookie from response
extract_set_cookie() {
    local response=$(echo "$1" | head -n $(($(echo "$1" | wc -l) - 1)) )
    echo "$response" | grep -i "Set-Cookie:" | sed 's/Set-Cookie: session_id=\([^;]*\).*/\1/'
}

# Function to handle JSON response and status code
parse_response() {
    local full_response="$1"
    local response_body=$(echo "$full_response" | sed -n '1p')
    local status_code=$(echo "$full_response" | tail -n 1)
    
    echo "$response_body"
    return $status_code
}

# Test 1: Register new user
echo "Test 1: Registering new user..."
register_response=$(send_request "POST" "/register" "{\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASSWORD\"}")
register_status=$(echo "$register_response" | tail -n1)
if [ "$register_status" -eq 201 ]; then
    echo "✓ Registered user successfully"
else
    echo "✗ Failed to register user: $register_response"
    kill $SERVER_PID
    exit 1
fi

# Test 2: Try registering duplicate username
echo "Test 2: Trying to register duplicate user..."
dup_response=$(send_request "POST" "/register" "{\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASSWORD\"}")
dup_status=$(echo "$dup_response" | tail -n1)
if [ "$dup_status" -eq 409 ]; then
    echo "✓ Correctly rejected duplicate username"
else
    echo "✗ Failed to reject duplicate: $dup_response"
fi

# Test 3: Login with created user
echo "Test 3: Logging in..."
login_response=$(send_request "POST" "/login" "{\"username\":\"$TEST_USER\",\"password\":\"$TEST_PASSWORD\"}")
login_status=$(echo "$login_response" | tail -n1)
if [ "$login_status" -eq 200 ]; then
    echo "✓ Login successful"
    # Extract cookie from response
    SERVER_RESPONSE_FULL=$(echo "$login_response" | head -n -1)
    SESSION_ID=$(echo "$SERVER_RESPONSE_FULL" | grep -i "Set-Cookie:" | cut -d'=' -f2 | cut -d';' -f1)
    if [ -n "$SESSION_ID" ]; then
        echo "✓ Extracted session ID successfully"
    else
        echo "✗ Failed to extract session ID"
    fi
else
    echo "✗ Login failed: $login_response"
    kill $SERVER_PID
    exit 1
fi

# Function to make authenticated request
authenticated_request() {
    local method=$1
    local endpoint=$2
    local data=$3
    
    if [ -n "$SESSION_ID" ]; then
        curl -s -w "\n%{http_code}\n" \
             -X "$method" \
             -H "Content-Type: application/json" \
             -H "Cookie: session_id=$SESSION_ID" \
             --data "$data" \
             "$BASE_URL$endpoint"
    else
        curl -s -w "\n%{http_code}\n" \
             -X "$method" \
             -H "Content-Type: application/json" \
             --data "$data" \
             "$BASE_URL$endpoint"
    fi
}

# Test 4: Access protected /me endpoint
echo "Test 4: Getting user info (/me)..."
me_response=$(authenticated_request "GET" "/me" "")
me_status=$(echo "$me_response" | tail -n1)
if [ "$me_status" -eq 200 ] && echo "$me_response" | head -n1 | grep -q "\"username\":\"$TEST_USER\""; then
    echo "✓ Successfully accessed /me endpoint"
else
    echo "✗ Failed to access /me: $me_response"
fi

# Test 5: Access protected endpoint without auth
echo "Test 5: Trying to access /me without credentials..."
no_auth_response=$(send_request "GET" "/me" "")
no_auth_status=$(echo "$no_auth_response" | tail -n1)
if [ "$no_auth_status" -eq 401 ]; then
    echo "✓ Correctly rejected unauthorized access"
else
    echo "✗ Did not reject unauthorized access: $no_auth_response"
fi

# Test 6: Create a new todo
echo "Test 6: Creating a new todo..."
todo_response=$(authenticated_request "POST" "/todos" "{\"title\":\"$TODO_TITLE\",\"description\":\"$TODO_DESC\"}")
todo_status=$(echo "$todo_response" | tail -n1)
if [ "$todo_status" -eq 201 ]; then
    TODO_ID=$(echo "$todo_response" | head -n1 | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "✓ Created todo with ID: $TODO_ID"
else
    echo "✗ Failed to create todo: $todo_response"
fi

# Test 7: Get created todo
echo "Test 7: Getting specific todo..."
if [ -n "$TODO_ID" ]; then
    get_todo_response=$(authenticated_request "GET" "/todos/$TODO_ID" "")
    get_todo_status=$(echo "$get_todo_response" | tail -n1)
    if [ "$get_todo_status" -eq 200 ]; then
        echo "✓ Retrieved specific todo"
    else
        echo "✗ Failed to retrieve todo: $get_todo_response"
    fi
else
    echo "! Skipping get todo test (didn't create todo)"
fi

# Test 8: Get all todos
echo "Test 8: Listing all todos..." 
all_todos_response=$(authenticated_request "GET" "/todos" "")
all_todos_status=$(echo "$all_todos_response" | tail -n1)
if [ "$all_todos_status" -eq 200 ]; then
    echo "✓ Listed all todos"
else
    echo "✗ Failed to list todos: $all_todos_response"
fi

# Test 9: Update the todo
echo "Test 9: Updating todo..."
if [ -n "$TODO_ID" ]; then
    update_response=$(authenticated_request "PUT" "/todos/$TODO_ID" "{\"title\":\"Updated Title\",\"completed\":true}")
    update_status=$(echo "$update_response" | tail -n1)
    if [ "$update_status" -eq 200 ]; then
        echo "✓ Updated todo successfully"
    else
        echo "✗ Failed to update todo: $update_response"
    fi
else
    echo "! Skipping update todo test (didn't create todo)"
fi

# Test 10: Change password
echo "Test 10: Changing password..."
change_pass_response=$(authenticated_request "PUT" "/password" "{\"old_password\":\"$TEST_PASSWORD\",\"new_password\":\"$NEW_PASSWORD\"}")
change_pass_status=$(echo "$change_pass_response" | tail -n1)
if [ "$change_pass_status" -eq 200 ]; then
    echo "✓ Changed password successfully"
else
    echo "✗ Failed to change password: $change_pass_response"
fi

# Test 11: Logout
echo "Test 11: Logging out..."
logout_response=$(authenticated_request "POST" "/logout" "")
logout_status=$(echo "$logout_response" | tail -n1)
if [ "$logout_status" -eq 200 ]; then
    echo "✓ Logged out successfully"
else
    echo "✗ Failed to log out: $logout_response"
fi

# Test 12: Try to access protected after logout
echo "Test 12: Testing access after logout..."
after_logout_response=$(authenticated_request "GET" "/me" "")
after_logout_status=$(echo "$after_logout_response" | tail -n1)
if [ "$after_logout_status" -eq 401 ]; then
    echo "✓ Correctly blocked access after logout"
else
    echo "✗ Still allowed access after logout: $after_logout_response"
fi

# Test 13: Login with new password
echo "Test 13: Logging in with new password..."
new_login_response=$(send_request "POST" "/login" "{\"username\":\"$TEST_USER\",\"password\":\"$NEW_PASSWORD\"}")
new_login_status=$(echo "$new_login_response" | tail -n1)
if [ "$new_login_status" -eq 200 ]; then
    echo "✓ Successfully logged in with new password"
else
    echo "✗ Failed to log in with new password: $new_login_response"
fi

# Test 14: Delete the todo
echo "Test 14: Deleting the todo..."
if [ -n "$TODO_ID" ]; then
    delete_response=$(authenticated_request "DELETE" "/todos/$TODO_ID" "")
    delete_status=$(echo "$delete_response" | tail -n1)
    if [ "$delete_status" -eq 204 ]; then
        echo "✓ Deleted todo successfully"
    else
        echo "✗ Failed to delete todo: $delete_response"
    fi
else
    echo "! Skipping delete todo test (didn't create todo)"
fi

# Final report
echo ""
echo "=========================================="
echo "ALL TESTS COMPLETED"
echo "=========================================="

# Stop server
kill $SERVER_PID
wait $SERVER_PID

echo "Server stopped."