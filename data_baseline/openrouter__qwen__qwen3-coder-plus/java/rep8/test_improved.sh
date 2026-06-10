#!/bin/bash

echo "Compiling server..."
mkdir -p classes
javac -d classes src/com/todo/server/TodoServer.java

# Start server in background
echo "Starting server on port 8081..."
java -cp classes com.todo.server.TodoServer --port 8081 &
SERVER_PID=$!
sleep 2

# Test flag
TEST_FAILED=0

# Cleanup function
cleanup() {
    kill $SERVER_PID 2>/dev/null
    # Make sure we wait for it to clean up the port
    sleep 1
}

# Test specific functionality
test_register() {
    echo "Testing POST /register..."
    response=$(curl -s -w "\nSTATUS:%{response_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"username":"testuser","password":"password123"}' \
        http://localhost:8081/register)
    
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
    status=${status#STATUS:}
    body=$(echo "$response" | sed '$ d')
    
    if [ "$status" -eq 201 ]; then
        echo "✓ Register user successful"
        echo "REGISTER_RESPONSE: $body"
        return 0
    else
        echo "✗ Register user failed: $status - $body"
        return 1
    fi
}

# Test login and extract cookie manually
test_login() {
    echo "Testing POST /login..."
    # Save cookies to a file to extract session_id
    cookie_file=$(mktemp)
    response=$(curl -s -w "\nSTATUS:%{response_code}" \
        -c "$cookie_file" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"username":"testuser","password":"password123"}' \
        http://localhost:8081/login)
    
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
    status=${status#STATUS:}
    body=$(echo "$response" | sed '$ d')
    
    # Extract the session ID from the cookie file
    SESSION_ID=$(grep 'session_id' "$cookie_file" | awk '{print $NF}')
    rm "$cookie_file"
    
    if [ "$status" -eq 200 ]; then
        echo "✓ Login successful"
        if [ -n "$SESSION_ID" ]; then
            echo "Retrieved session ID: $SESSION_ID"
            COOKIES="session_id=$SESSION_ID"
            echo "Setting cookies for subsequent requests: $COOKIES"
            return 0
        else
            echo "✗ Could not extract session ID from cookie file"
            return 1
        fi
    else
        echo "✗ Login failed: $status - $body"
        return 1
    fi
}

# Generic http request helper
http_request_with_cookies() {
    local method=$1
    local path=$2
    local data=$3
    local cookies=$4
    local expect_body=${5:-1}
    
    if [ -n "$data" ] && [ -n "$cookies" ]; then
        curl -s -w "\nSTATUS:%{response_code}" \
            -X $method \
            -H "Content-Type: application/json" \
            -b "$cookies" \
            -d "$data" \
            "http://localhost:8081$path"
    elif [ -n "$data" ]; then
        curl -s -w "\nSTATUS:%{response_code}" \
            -X $method \
            -H "Content-Type: application/json" \
            -d "$data" \
            "http://localhost:8081$path"
    elif [ -n "$cookies" ]; then
        curl -s -w "\nSTATUS:%{response_code}" \
            -X $method \
            -H "Content-Type: application/json" \
            -b "$cookies" \
            "http://localhost:8081$path"
    else
        curl -s -w "\nSTATUS:%{response_code}" \
            -X $method \
            -H "Content-Type: application/json" \
            "http://localhost:8081$path"
    fi
}

test_get_me() {
    echo "Testing GET /me..."
    response=$(http_request_with_cookies GET /me "" "$COOKIES")
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')  
    status=${status#STATUS:}
    body=$(echo "$response" | sed '$ d')
    
    if [ "$status" -eq 200 ]; then
        echo "✓ Get me successful: $body"
        return 0
    else
        echo "✗ Get me failed: $status - $body"
        return 1
    fi
}

test_create_todo() {
    echo "Testing POST /todos..."
    response=$(http_request_with_cookies POST /todos '{"title":"Test Todo","description":"Test Description"}' "$COOKIES")
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
    status=${status#STATUS:}  
    body=$(echo "$response" | sed '$ d')
    
    if [ "$status" -eq 201 ]; then
        echo "✓ Create todo successful"
        # Extract ID from response JSON
        GLOBAL_TODO_ID=$(echo "$body" | grep -o '"id":[0-9]*' | head -n1 | cut -d: -f2)
        echo "Created todo with ID: $GLOBAL_TODO_ID"
        return 0
    else
        echo "✗ Create todo failed: $status - $body"
        return 1
    fi
}

test_get_todos() {
    echo "Testing GET /todos..."  
    response=$(http_request_with_cookies GET /todos "" "$COOKIES")
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
    status=${status#STATUS:}
    body=$(echo "$response" | sed '$ d')
    
    if [ "$status" -eq 200 ]; then
        echo "✓ Get todos successful: $body"
        return 0
    else
        echo "✗ Get todos failed: $status - $body"
        return 1
    fi
}

test_get_todo_by_id() {
    if [ -z "$GLOBAL_TODO_ID" ]; then
        echo "* Skipping specific todo fetch (no todo created)"
        return 0
    fi
    
    echo "Testing GET /todos/$GLOBAL_TODO_ID..."
    response=$(http_request_with_cookies GET "/todos/$GLOBAL_TODO_ID" "" "$COOKIES")
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$') 
    status=${status#STATUS:}
    body=$(echo "$response" | sed '$ d')
    
    if [ "$status" -eq 200 ]; then
        echo "✓ Get specific todo successful: $body"
        return 0
    else
        echo "✗ Get specific todo failed: $status - $body"
        return 1
    fi
}

test_update_todo() {
    if [ -z "$GLOBAL_TODO_ID" ]; then
        echo "* Skipping todo update (no todo created)"
        return 0
    fi
    
    echo "Testing PUT /todos/$GLOBAL_TODO_ID..."
    response=$(http_request_with_cookies PUT "/todos/$GLOBAL_TODO_ID" '{"title":"Updated Title", "completed": true}' "$COOKIES")
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
    status=${status#STATUS:}
    body=$(echo "$response" | sed '$ d')
    
    if [ "$status" -eq 200 ]; then
        echo "✓ Update todo successful: $body"
        return 0
    else
        echo "✗ Update todo failed: $status - $body"
        return 1
    fi
}

test_delete_todo() {
    if [ -z "$GLOBAL_TODO_ID" ]; then
        echo "* Skipping todo delete (no todo created)"
        return 0
    fi
    
    echo "Testing DELETE /todos/$GLOBAL_TODO_ID..."
    response=$(http_request_with_cookies DELETE "/todos/$GLOBAL_TODO_ID" "" "$COOKIES")
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
    status=${status#STATUS:}
    
    if [ "$status" -eq 204 ]; then
        echo "✓ Delete todo successful"
        return 0
    else
        echo "✗ Delete todo failed: $status"
        return 1
    fi
}

test_change_password() {
    echo "Testing PUT /password..."
    response=$(http_request_with_cookies PUT /password '{"old_password":"password123", "new_password":"newpassword456"}' "$COOKIES")
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
    status=${status#STATUS:}
    body=$(echo "$response" | sed '$ d')
    
    if [ "$status" -eq 200 ]; then
        echo "✓ Change password successful: $body"
        return 0
    else
        echo "✗ Change password failed: $status - $body"
        return 1
    fi
}

test_logout() {
    echo "Testing POST /logout..."
    response=$(http_request_with_cookies POST /logout "" "$COOKIES")
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
    status=${status#STATUS:}
    body=$(echo "$response" | sed '$ d')
    
    if [ "$status" -eq 200 ]; then
        echo "✓ Logout successful: $body"
        return 0
    else
        echo "✗ Logout failed: $status - $body"
        return 1
    fi
}

# Additional tests for validations
test_invalid_operations() {
    echo "Testing unauthorized access to protected endpoint..."
    response=$(curl -s -w "\nSTATUS:%{response_code}" -X GET http://localhost:8081/me)
    status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
    status=${status#STATUS:}
    body=$(echo "$response" | sed '$ d')
    
    if [ "$status" -eq 401 ]; then
        echo "✓ Unauthorized access correctly rejected: $status - $body"
    else
        echo "✗ Should reject unauthorized access: $status - $body"
        TEST_FAILED=1
    fi
	
	# Test invalid credentials on login
	echo "Testing invalid credentials on login..."
	response=$(curl -s -w "\nSTATUS:%{response_code}" \
		-X POST \
		-H "Content-Type: application/json" \
		-d '{"username":"nonexistent","password":"wrong"}' \
		http://localhost:8081/login)
	status=$(echo "$response" | grep -o 'STATUS:[0-9]*$')
	status=${status#STATUS:} 
	body=$(echo "$response" | sed '$ d')
	
	if [ "$status" -eq 401 ]; then
		echo "✓ Invalid credentials correctly rejected: $status - $body"
	else
		echo "✗ Should reject invalid credentials: $status - $body"
		TEST_FAILED=1
	fi
}

# Variables to store state
GLOBAL_TODO_ID=""
COOKIES=""

# Run the actual tests
echo "=================================="
echo "STARTING COMPREHENSIVE TEST SUITE"
echo "=================================="

{
    # Wait a moment to ensure server is ready
    sleep 1
    
    # Run all tests sequentially, track failures
    if test_register; then
        echo "✓ Registration test passed"
    else
        echo "✗ Registration test failed"
        TEST_FAILED=1
    fi
    
    if test_login; then
        echo "✓ Login test passed"
    else
        echo "✗ Login test failed"
        TEST_FAILED=1
    fi
    
    if test_get_me; then
        echo "✓ Get me test passed"
    else
        echo "✗ Get me test failed"
        TEST_FAILED=1
    fi
    
    if test_create_todo; then
        echo "✓ Create todo test passed"
    else
        echo "✗ Create todo test failed"
        TEST_FAILED=1
    fi
    
    if test_get_todos; then
        echo "✓ Get todos test passed"
    else
        echo "✗ Get todos test failed"
        TEST_FAILED=1
    fi
    
    if test_get_todo_by_id; then
        echo "✓ Get specific todo test passed"
    else
        echo "✗ Get specific todo test failed"
        TEST_FAILED=1
    fi
    
    if test_update_todo; then
        echo "✓ Update todo test passed"
    else
        echo "✗ Update todo test failed"
        TEST_FAILED=1
    fi
    
    if test_delete_todo; then
        echo "✓ Delete todo test passed"
    else
        echo "✗ Delete todo test failed"
        TEST_FAILED=1
    fi
    
    # Register and login again to test password change and logout
    curl -s -X POST -H "Content-Type: application/json" \
        -d '{"username":"anothertest","password":"initialpass123"}' \
        http://localhost:8081/register > /dev/null
    
    # Login with the second user to get new session for testing password change
    temp_cookie_file=$(mktemp)
    curl -s -w "\nSTATUS:%{response_code}" \
        -c "$temp_cookie_file" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"username":"anothertest","password":"initialpass123"}' \
        http://localhost:8081/login > /dev/null
    NEW_SESSION_ID=$(grep 'session_id' "$temp_cookie_file" | awk '{print $NF}')
    rm "$temp_cookie_file"
    NEW_COOKIES="session_id=$NEW_SESSION_ID"
    
    # Change password with second session
    if http_request_with_cookies PUT /password '{"old_password":"initialpass123", "new_password":"newpassword456"}' "$NEW_COOKIES" 2>&1 | grep -q "200"; then
        echo "✓ Change password test passed"
    else
        echo "✗ Change password test failed"
        TEST_FAILED=1
    fi
    
    # Logout with second session
    if http_request_with_cookies POST /logout "" "$NEW_COOKIES" 2>&1 | grep -q "200"; then
        echo "✓ Logout test passed"
    else
        echo "✗ Logout test failed"
        TEST_FAILED=1
    fi
    
    # Now test invalid operations
    test_invalid_operations
} &

# Wait for all tests to complete
wait

# Clean up
cleanup

if [ $TEST_FAILED -eq 0 ]; then
    echo "=================================="
    echo "ALL TESTS PASSED!" 
    echo "=================================="
    exit 0
else
    echo "=================================="
    echo "SOME TESTS FAILED!"
    echo "=================================="
    exit 1
fi