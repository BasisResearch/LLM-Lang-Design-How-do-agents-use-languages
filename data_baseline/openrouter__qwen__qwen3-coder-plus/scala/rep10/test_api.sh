#!/bin/bash

# Configuration
PORT=8080
BASE_URL="http://localhost:$PORT"
SESSION_FILE=$(mktemp)

# Start server in background
echo "Starting server on localhost:${PORT}..."
./run.sh --port ${PORT} &
SERVER_PID=$!
sleep 3  # Allow server to start

# Function to perform cleanup
cleanup() {
    echo
    echo "Shutting down server..."
    kill $SERVER_PID
    rm -f $SESSION_FILE
    wait $SERVER_PID 2>/dev/null
}

# Ensure cleanup on exit
trap cleanup EXIT

# Function to make authenticated request by extracting and sending cookies
cookie_jar=()
make_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}" 
    
    local curl_cmd="curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X $method $BASE_URL$endpoint"
    
    if [[ -n "$data" ]]; then
        curl_cmd="$curl_cmd -d '$data' -H 'Content-Type: application/json'"
    fi
    
    response=$(eval $curl_cmd)
    # Extract body and http code
    body=$(echo "$response" | sed '$d')
    http_code=$(echo "$response" | tail -n1)

    echo "$body"  # Return body
}

# Test registration
echo "Testing registration..."
response=$(curl -sS -w '\n%{http_code}\n' -X POST $BASE_URL/register \
  -d '{"username": "johndoe", "password": "password123"}')
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 201 ]]; then
    echo "✓ Registration successful: $body"
else
    echo "✗ Registration failed with status $http_code: $body"
    exit 1
fi

# Test registration with bad username
response=$(curl -sS -w '\n%{http_code}\n' -X POST $BASE_URL/register \
  -d '{"username": "ab", "password": "password123"}')
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 400 ]]; then
    echo "✓ Bad username validation works: $body"
else
    echo "✗ Bad username validation failed with status $http_code: $body"
    exit 1
fi

# Test login
echo "Testing login..."
response=$(curl -sS -w '\n%{header_json}' -X POST $BASE_URL/login \
  -d '{"username": "johndoe", "password": "password123"}')
headers=$(echo "$response" | sed -n '/^{/,$p')
body=$(echo "$response" | sed '/^{/,$d' | sed '/^$/d; /^{/q' )
echo "$body"

http_code=$(echo "$response" | grep -o '"code":\([0-9]*\)' | cut -d':' -f2)

if [[ $(echo "$headers" | grep -c 'session_id') -gt 0 ]] && [[ $body =~ "johndoe" ]]; then
    echo "✓ Login successful and cookie set"
else
    echo "✗ Login failed: $response"
    exit 1
fi

# Test /me endpoint (authenticated)
echo "Testing /me endpoint..."
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X GET $BASE_URL/me)
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 200 ]] && [[ $body =~ "johndoe" ]]; then
    echo "✓ /me endpoint works: $body"
else
    echo "✗ /me endpoint failed with status $http_code: $body"
    exit 1
fi

# Test unauthorized access to protected endpoint
echo "Testing unauthorized access..."
rm -f $SESSION_FILE  # Clear session
response=$(curl -sS -w '\n%{http_code}\n' -X GET $BASE_URL/me)
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 401 ]]; then
    echo "✓ Unauthorized access blocked: $body"
else
    echo "✗ Unauthorized access not blocked: $body"
    exit 1
fi

# Login again to proceed with tests
curl -sS -w '/n' -X POST $BASE_URL/login -d '{"username": "johndoe", "password": "password123"}' -c $SESSION_FILE > /dev/null

# Test create todo
echo "Testing create todo..."
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X POST $BASE_URL/todos \
  -d '{"title": "Buy groceries", "description": "Milk and bread"}')
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 201 ]] && [[ $body =~ "Buy groceries" ]]; then
    todo_id=$(echo $body | jq -r '.id')
    echo "✓ Todo created successfully with ID: $todo_id"
else
    echo "✗ Todo creation failed with status $http_code: $body"
    echo "Debug: Response was $response"
    exit 1
fi

# Create another todo
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X POST $BASE_URL/todos \
  -d '{"title": "Walk the dog", "description": "Evening walk"}')
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 201 ]]; then
    todo_id2=$(echo $body | jq -r '.id')
    echo "✓ Second todo created with ID: $todo_id2"
else
    echo "✗ Second todo creation failed: $body"
    exit 1
fi

# Test get all todos
echo "Testing get all todos..."
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X GET $BASE_URL/todos)
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 200 ]] && [[ $(echo $body | jq '. | length') -ge 1 ]]; then
    echo "✓ Get all todos works: Found $(echo $body | jq '. | length') todos"
else
    echo "✗ Get all todos failed: $body"
    exit 1
fi

# Test get specific todo
echo "Testing get specific todo..."
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X GET $BASE_URL/todos/$todo_id)
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 200 ]] && [[ $body =~ "Buy groceries" ]]; then
    echo "✓ Get specific todo works: $body"
else
    echo "✗ Get specific todo failed: $body"
    exit 1
fi

# Test update todo
echo "Testing update todo..."
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X PUT $BASE_URL/todos/$todo_id \
  -d '{"completed": true, "description": "Milk, bread, and eggs"}')
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 200 ]] && [[ $body =~ "true" ]]; then
    echo "✓ Todo updated successfully: $body"
else
    echo "✗ Todo update failed: $body"
    exit 1
fi

# Test delete todo
echo "Testing delete todo..."
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X DELETE $BASE_URL/todos/$todo_id)
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 204 ]]; then
    echo "✓ Todo deleted successfully"
else
    echo "✗ Todo deletion failed with status $http_code: $response"
    exit 1
fi

# Verify deleted todo is gone
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X GET $BASE_URL/todos/$todo_id)
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 404 ]]; then
    echo "✓ Deleted todo is properly removed: $body"
else
    echo "✗ Deleted todo still accessible: $body"
    exit 1
fi

# Test change password
echo "Testing change password..."
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X PUT $BASE_URL/password \
  -d '{"old_password": "password123", "new_password": "newpassword456"}')
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 200 ]]; then
    echo "✓ Password changed successfully"
else 
    echo "✗ Password change failed: $body"
    exit 1
fi

# Try to login with old password (should fail)
curl -sS -w '\n%{http_code}\n' -X POST $BASE_URL/login \
  -d '{"username": "johndoe", "password": "password123"}' | grep -q "401"
if [[ $? -eq 0 ]]; then
    echo "✓ Old password is invalid after change"
else
    echo "✗ Old password still works after change"
    exit 1
fi

# Try to login with new password
rm -f $SESSION_FILE  # Clear old session
response=$(curl -sS -w '\n%{http_code}\n' -X POST $BASE_URL/login \
  -d '{"username": "johndoe", "password": "newpassword456"}' -c $SESSION_FILE)
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 200 ]]; then
    echo "✓ New password works for login"
else 
    echo "✗ New password doesn't work after change: $body"
    exit 1
fi

# Test logout
echo "Testing logout..."
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X POST $BASE_URL/logout)
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 200 ]]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed: $body" 
    exit 1
fi

# Verify that after logout, can't access protected endpoints
response=$(curl -sS -w '\n%{http_code}\n' -b $SESSION_FILE -c $SESSION_FILE -X GET $BASE_URL/me)
body=$(echo "$response" | sed '$d')
http_code=$(echo "$response" | tail -n1)

if [[ $http_code -eq 401 ]]; then
    echo "✓ Session properly invalidated after logout"
else
    echo "✗ Access still available after logout: $body"
    exit 1
fi

echo
echo "All tests passed! ✓"
echo "Server working correctly with all endpoints validated."