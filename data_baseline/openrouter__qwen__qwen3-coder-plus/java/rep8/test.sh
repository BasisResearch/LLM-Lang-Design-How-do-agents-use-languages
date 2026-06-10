#!/bin/bash

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
}

# Basic HTTP client function
make_request() {
    local method=$1
    local path=$2
    local data=$3
    local cookies=$4
    
    if [ -n "$data" ] && [ -n "$cookies" ]; then
        curl -s -w "\nHTTP_CODE:%{http_code}" -X $method \
            -H "Content-Type: application/json" \
            -b "$cookies" -d "$data" \
            http://localhost:8081$path
    elif [ -n "$data" ]; then
        curl -s -w "\nHTTP_CODE:%{http_code}" -X $method \
            -H "Content-Type: application/json" \
            -d "$data" \
            http://localhost:8081$path
    elif [ -n "$cookies" ]; then
        curl -s -w "\nHTTP_CODE:%{http_code}" -X $method \
            -H "Content-Type: application/json" \
            -b "$cookies" \
            http://localhost:8081$path
    else
        curl -s -w "\nHTTP_CODE:%{http_code}" -X $method \
            -H "Content-Type: application/json" \
            http://localhost:8081$path
    fi
}

# Extract session from response
extract_session() {
    local response="$1"
    echo "$response" | grep -o 'session_id=[^;]*' | cut -d'=' -f2
}

# Test register endpoint
echo "Testing POST /register..."
response=$(make_request POST /register '{"username":"testuser","password":"password123"}')
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 201 ]; then
    echo "✓ Register user successful"
else
    echo "✗ Register user failed: $status - $body"
    TEST_FAILED=1
fi

# Test registration with existing username
echo "Testing duplicate registration..."
response=$(make_request POST /register '{"username":"testuser","password":"password123"}')
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 409 ]; then
    echo "✓ Duplicate registration correctly rejected"
else
    echo "✗ Duplicate registration should fail: $status - $body"
    TEST_FAILED=1
fi

# Test login
echo "Testing POST /login..."
response=$(make_request POST /login '{"username":"testuser","password":"password123"}')
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 200 ]; then
    echo "✓ Login successful"
    SESSION_ID=$(echo "$body" | grep -o '"id":[0-9]*')
    if [ -n "$SESSION_ID" ]; then
        COOKIES="session_id=$(echo "$response" | grep -o 'session_id=[a-z0-9-]*' | cut -d'=' -f2)"
        echo "Got session: $COOKIES"
    else
        echo "✗ Could not extract user info from login response"
        TEST_FAILED=1
    fi
else
    echo "✗ Login failed: $status - $body"
    TEST_FAILED=1
fi

# Test GET /me
echo "Testing GET /me..."
response=$(make_request GET /me "" "$COOKIES")
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 200 ]; then
    echo "✓ Get me successful: $body"
else
    echo "✗ Get me failed: $status - $body"
    TEST_FAILED=1
fi

# Test unauthorized access to protected endpoints
echo "Testing unauthorized access to /me..."
response=$(make_request GET /me "" "")
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 401 ]; then
    echo "✓ Unauthorized access correctly rejected"
else
    echo "✗ Unauthorized access should be rejected: $status - $body"
    TEST_FAILED=1
fi

# Test creating a todo
echo "Testing POST /todos..."
response=$(make_request POST /todos '{"title":"Test Todo","description":"Test Description"}' "$COOKIES")
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 201 ]; then
    echo "✓ Create todo successful"
    TODO_ID=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "Created todo ID: $TODO_ID"
else
    echo "✗ Create todo failed: $status - $body"
    TEST_FAILED=1
fi

# Test getting all todos
echo "Testing GET /todos..."
response=$(make_request GET /todos "" "$COOKIES")
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 200 ] && [[ "$body" =~ \[.*\] ]]; then
    echo "✓ Get todos successful: $body"
else
    echo "✗ Get todos failed: $status - $body"
    TEST_FAILED=1
fi

# Test getting a specific todo
echo "Testing GET /todos/$TODO_ID..."
response=$(make_request GET /todos/$TODO_ID "" "$COOKIES")
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 200 ]; then
    echo "✓ Get specific todo successful: $body"
else
    echo "✗ Get specific todo failed: $status - $body"
    TEST_FAILED=1
fi

# Test updating a todo
echo "Testing PUT /todos/$TODO_ID..."
response=$(make_request PUT /todos/$TODO_ID '{"title":"Updated Title", "completed": true}' "$COOKIES")
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 200 ]; then
    echo "✓ Update todo successful: $body"
else
    echo "✗ Update todo failed: $status - $body"
    TEST_FAILED=1
fi

# Test deleting a todo
echo "Testing DELETE /todos/$TODO_ID..."
response=$(make_request DELETE /todos/$TODO_ID "" "$COOKIES")
status=$(echo "$response" | tail -n1 | cut -d: -f2)

if [ "$status" -eq 204 ]; then
    echo "✓ Delete todo successful"
else
    echo "✗ Delete todo failed: $status"
    TEST_FAILED=1
fi

# Test password change
echo "Testing PUT /password..."
response=$(make_request PUT /password '{"old_password":"password123", "new_password":"newpassword456"}' "$COOKIES")
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 200 ]; then
    echo "✓ Change password successful"
else
    echo "✗ Change password failed: $status - $body"
    TEST_FAILED=1
fi

# Test logout
echo "Testing POST /logout..."
response=$(make_request POST /logout "" "$COOKIES")
status=$(echo "$response" | tail -n1 | cut -d: -f2)
body=$(echo "$response" | sed '$ d')

if [ "$status" -eq 200 ]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed: $status - $body"
    TEST_FAILED=1
fi

# Clean up
cleanup

if [ $TEST_FAILED -eq 0 ]; then
    echo "=================================="
    echo "All tests passed!" 
    echo "=================================="
    exit 0
else
    echo "=================================="
    echo "Some tests failed!"
    echo "=================================="
    exit 1
fi