#!/bin/bash

# Test script for Todo API

# Start server in background
PORT=3005
echo "Starting server on port $PORT..."
node server.js --port $PORT &
SERVER_PID=$!
sleep 2  # Give server time to start

# Base URL
BASE_URL="http://localhost:$PORT"

# Helper curl function
curl_req() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    local cookie_jar="$4"
    
    if [ -n "$cookie_jar" ]; then
        curl_cmd="curl -s -c $cookie_jar -b $cookie_jar -X $method -H 'Content-Type: application/json'"
    else
        curl_cmd="curl -s -X $method -H 'Content-Type: application/json'"
    fi
    
    if [ -n "$data" ]; then
        curl_cmd="$curl_cmd -d '$data'"
    fi
    
    curl_cmd="$curl_cmd $BASE_URL$endpoint"
    
    eval $curl_cmd
}

echo "Running tests..."

# Test register new user
echo "Testing POST /register"
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    $BASE_URL/register)
if echo "$response" | grep -q '"id"[[:space:]*:[[:space:]*[0-9]*'; then
    echo "✓ Register success"
else
    echo "✗ Register failed: $response"
fi

# Test register with existing username
echo "Testing duplicate username"
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    $BASE_URL/register)
if echo "$response" | grep -q "already exists"; then
    echo "✓ Duplicate username handled correctly"
else
    echo "✗ Duplicate username not handled: $response"
fi

# Test malformed username (too short)
echo "Testing malformed username (too short)"
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"ab","password":"password123"}' \
    $BASE_URL/register)
if echo "$response" | grep -q "Invalid username"; then
    echo "✓ Short username rejected correctly"
else
    echo "✗ Short username not rejected: $response"
fi

# Test invalid characters in username
echo "Testing invalid characters in username"
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"test-name","password":"password123"}' \
    $BASE_URL/register)
if echo "$response" | grep -q "Invalid username"; then
    echo "✓ Invalid character username rejected correctly"
else
    echo "✗ Invalid character username not rejected: $response"
fi

# Test short password
echo "Testing short password"
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"newuser","password":"pass"}' \
    $BASE_URL/register)
if echo "$response" | grep -q "Password too short"; then
    echo "✓ Short password rejected correctly"
else
    echo "✗ Short password not rejected: $response"
fi

# Now register a different user
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"newuser","password":"password123"}' \
    $BASE_URL/register)

# Cookie jar for maintaining session
COOKIE_JAR=$(mktemp)

# Test login
echo "Testing POST /login"
response=$(curl -s -c $COOKIE_JAR -X POST -H "Content-Type: application/json" \
    -d '{"username":"newuser","password":"password123"}' \
    $BASE_URL/login)
if echo "$response" | grep -q '"id"' && echo "$response" | grep -q '"username"'; then
    echo "✓ Login success"
else
    echo "✗ Login failed: $response"
fi

# Test /me endpoint
echo "Testing GET /me"
response=$(curl -s -b $COOKIE_JAR -X GET $BASE_URL/me)
if echo "$response" | grep -q '"id"' && echo "$response" | grep -q '"username"'; then
    echo "✓ Me endpoint success"
else
    echo "✗ Me endpoint failed: $response"
fi

# Test unauthorized access to protected endpoint
echo "Testing unauthorized access to protected endpoint"
response=$(curl -s -X GET $BASE_URL/me)
if echo "$response" | grep -q "Authentication required"; then
    echo "✓ Unauthenticated access properly blocked"
else
    echo "✗ Unauthenticated access not blocked: $response"
fi

# Test creating todos
echo "Testing POST /todos"
response=$(curl -s -b $COOKIE_JAR -X POST -H "Content-Type: application/json" \
    -d '{"title":"Test Todo","description":"This is a test"}' \
    $BASE_URL/todos)
if echo "$response" | grep -q '"id"' && echo "$response" | grep -q '"title"'; then
    echo "✓ Create todo success"
    TODO_ID=$(echo $response | sed -n 's/.*"id":[[:space:]]*\([0-9]*\).*/\1/p')
    echo "Created todo with ID: $TODO_ID"
else
    echo "✗ Create todo failed: $response"
fi

# Test creating todo without title
echo "Testing create todo without title"
response=$(curl -s -b $COOKIE_JAR -X POST -H "Content-Type: application/json" \
    -d '{"description":"This is a test without title"}' \
    $BASE_URL/todos)
if echo "$response" | grep -q "Title is required"; then
    echo "✓ Missing title properly handled"
else
    echo "✗ Missing title not handled: $response"
fi

# Test retrieving todos
echo "Testing GET /todos"
response=$(curl -s -b $COOKIE_JAR -X GET $BASE_URL/todos)
if echo "$response" | grep -q '"id"'; then
    echo "✓ Get todos success"
else
    echo "✗ Get todos failed: $response"
fi

# Test updating todo
echo "Testing PUT /todos/$TODO_ID"
response=$(curl -s -b $COOKIE_JAR -X PUT -H "Content-Type: application/json" \
    -d '{"title":"Updated Todo","completed":true}' \
    $BASE_URL/todos/$TODO_ID)
if echo "$response" | grep -q '"id"' && echo "$response" | grep -q "Updated Todo" && echo "$response" | grep -q "true"; then
    echo "✓ Update todo success"
else
    echo "✗ Update todo failed: $response"
fi

# Test getting single todo
echo "Testing GET /todos/$TODO_ID"
response=$(curl -s -b $COOKIE_JAR -X GET $BASE_URL/todos/$TODO_ID)
if echo "$response" | grep -q "Updated Todo"; then
    echo "✓ Get single todo success"
else
    echo "✗ Get single todo failed: $response"
fi

# Test updating with empty title
echo "Testing update with empty title"
response=$(curl -s -b $COOKIE_JAR -X PUT -H "Content-Type: application/json" \
    -d '{"title":""}' \
    $BASE_URL/todos/$TODO_ID)
if echo "$response" | grep -q "Title is required"; then
    echo "✓ Empty title after update properly rejected"
else
    echo "✗ Empty title after update not handled: $response"
fi

# Create a second user to test isolation
response=$(curl -s -X POST -H "Content-Type: application/json" \
    -d '{"username":"otheruser","password":"password123"}' \
    $BASE_URL/register)

# Login as second user
COOKIE_JAR2=$(mktemp)
response=$(curl -s -c $COOKIE_JAR2 -X POST -H "Content-Type: application/json" \
    -d '{"username":"otheruser","password":"password123"}' \
    $BASE_URL/login)

# Second user creates a todo
response2=$(curl -s -b $COOKIE_JAR2 -X POST -H "Content-Type: application/json" \
    -d '{"title":"Other User Todo","description":"Created by other user"}' \
    $BASE_URL/todos)
TODO_ID_OTHER=$(echo $response2 | sed -n 's/.*"id":[[:space:]]*\([0-9]*\).*/\1/p')

if [ -n "$TODO_ID_OTHER" ]; then
    echo "Second user created todo with ID: $TODO_ID_OTHER"
    
    # Try to access other user's todo (should fail)
    echo "Testing cross-user data access"
    response=$(curl -s -b $COOKIE_JAR -X GET $BASE_URL/todos/$TODO_ID_OTHER)
    if echo "$response" | grep -q "Todo not found"; then
        echo "✓ Cross-user access properly denied"
    else
        echo "✗ Cross-user access not denied: $response"
    fi
fi

# Test password change
echo "Testing PUT /password"
response=$(curl -s -b $COOKIE_JAR -X PUT -H "Content-Type: application/json" \
    -d '{"old_password":"password123","new_password":"newpassword123"}' \
    $BASE_URL/password)
if echo "$response" | grep -q '^{[[:space:]]*}$'; then
    echo "✓ Password change success"
else
    echo "✗ Password change failed: $response"
fi

# Test invalid old password
echo "Testing invalid old password for change"
response=$(curl -s -b $COOKIE_JAR -X PUT -H "Content-Type: application/json" \
    -d '{"old_password":"wrongpassword","new_password":"newpassword123"}' \
    $BASE_URL/password)
if echo "$response" | grep -q "Invalid credentials"; then
    echo "✓ Invalid old password handled correctly"
else
    echo "✗ Invalid old password not handled: $response"
fi

# Test deleting todo
echo "Testing DELETE /todos/$TODO_ID"
response=$(curl -s -b $COOKIE_JAR -X DELETE $BASE_URL/todos/$TODO_ID)
if [ "$response" = "" ] && [ $? -eq 0 ]; then
    echo "✓ Delete todo success (received 204 as expected)"
else
    echo "✗ Delete todo failed: $response"
fi

# Cleanup
kill $SERVER_PID
rm -f $COOKIE_JAR $COOKIE_JAR2

echo "Tests completed!"