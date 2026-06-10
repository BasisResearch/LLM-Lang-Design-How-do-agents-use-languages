#!/bin/bash

# Start server in background
echo "Starting server on port 8080..."
timeout 60s ./todo_server --port 8080 &
SERVER_PID=$!
sleep 2  # Give server time to start

# Test variables
BASE_URL="http://localhost:8080"
COOKIE_FILE=$(mktemp)

echo "Testing API endpoints..."

# Function to send curl request and print results
test_endpoint() {
    local method=$1
    local endpoint=$2
    local data=$3
    local expected_status=$4
    local description=$5
    
    echo "Testing: $description"
    
    if [ -n "$data" ]; then
        response=$(curl -s -w "\n%{http_code}" -X $method -d "$data" -b $COOKIE_FILE -c $COOKIE_FILE $BASE_URL$endpoint)
    else
        response=$(curl -s -w "\n%{http_code}" -X $method -b $COOKIE_FILE -c $COOKIE_FILE $BASE_URL$endpoint)
    fi
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n-1)
    
    if [ "$http_code" -eq "$expected_status" ]; then
        echo "✅ PASS: Expected $expected_status, got $http_code"
        if [ "$expected_status" -ne 204 ]; then  # Don't print body for 204 (no content)
            echo "Response: $body"
        fi
        echo ""
    else
        echo "❌ FAIL: Expected $expected_status, got $http_code"
        echo "Response: $body"
        echo ""
    fi
}

# Test registration
echo "=== Testing Registration ==="
test_endpoint POST "/register" '{"username": "testuser", "password": "password123"}' 201 "Register new user"

# Test duplicate registration
test_endpoint POST "/register" '{"username": "testuser", "password": "password123"}' 409 "Try to register duplicate username"

# Test registration with invalid username
test_endpoint POST "/register" '{"username": "ab", "password": "password123"}' 400 "Try to register with short username"

# Test registration with invalid password
test_endpoint POST "/register" '{"username": "gooduser", "password": "weak"}' 400 "Try to register with weak password"

# Test login
echo "=== Testing Login ==="
test_endpoint POST "/login" '{"username": "testuser", "password": "password123"}' 200 "Login with valid credentials"

# Test invalid login
test_endpoint POST "/login" '{"username": "testuser", "password": "wrongpassword"}' 401 "Login with wrong password"

# Test authenticated endpoints
echo "=== Testing Authenticated Endpoints ==="
test_endpoint GET "/me" "" 200 "Get user profile after login"

# Test password change
test_endpoint PUT "/password" '{"old_password": "password123", "new_password": "newpassword456"}' 200 "Change password"
test_endpoint PUT "/password" '{"old_password": "wrongpassword", "new_password": "anotherpassword"}' 401 "Change password with wrong old password"

# Test creating todos (login again with new password)
curl -s -w "\n%{http_code}" -X POST -d '{"username": "testuser", "password": "newpassword456"}' -b $COOKIE_FILE -c $COOKIE_FILE $BASE_URL/login -o /dev/null

# Create some todos
test_endpoint POST "/todos" '{"title": "Buy groceries", "description": "Milk, eggs, bread"}' 201 "Create a new todo"
test_endpoint POST "/todos" '{"title": "Walk the dog", "description": "Take him to the park"}' 201 "Create another todo"

# Get all todos
test_endpoint GET "/todos" "" 200 "Get all user's todos"

# Get specific todo
test_endpoint GET "/todos/1" "" 200 "Get specific todo by ID"

# Update todo title
test_endpoint PUT "/todos/1" '{"title": "Buy weekly groceries", "completed": true}' 200 "Update todo partially"

# Test unauthorized access after logout
test_endpoint POST "/logout" "" 200 "Logout user"

# Try accessing protected endpoint after logout
test_endpoint GET "/me" "" 401 "Access me endpoint after logout"

# Log in again to restore session and test remaining features
curl -s -w "\n%{http_code}" -X POST -d '{"username": "testuser", "password": "newpassword456"}' -b $COOKIE_FILE -c $COOKIE_FILE $BASE_URL/login -o /dev/null
sleep 1

# Delete a todo (after re-authenticating)
test_endpoint DELETE "/todos/1" "" 204 "Delete todo"

# Test 404 for non-existent todo
test_endpoint GET "/todos/999" "" 404 "Get non-existent todo"

# Clean up
rm $COOKIE_FILE
kill $SERVER_PID 2>/dev/null

echo "Testing completed!"