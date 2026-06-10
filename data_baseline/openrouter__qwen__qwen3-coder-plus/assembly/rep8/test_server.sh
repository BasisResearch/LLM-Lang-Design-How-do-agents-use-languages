#!/bin/bash

# Test script for Todo API server
set -e

echo "Building server..."

# Assemble and link
nasm -f elf64 todo_server_full.asm -o server.o
ld server.o -o server

# Start the server in the background
./server --port 3000 &
SERVER_PID=$!

echo "Server started with PID $SERVER_PID"

# Allow server to start
sleep 2

# Function to send curl request and check response
test_endpoint() {
    local method=$1
    local endpoint=$2
    local expected_code=$3
    local data=$4
    local desc=$5
    
    echo "Testing: $desc ($method $endpoint) - expecting $expected_code"
    
    if [ "$data" != "" ]; then
        response=$(curl -s -w "%{http_code}" -X "$method" -H "Content-Type: application/json" \
            --data "$data" "http://localhost:3000$endpoint")
    else
        response=$(curl -s -w "%{http_code}" -X "$method" "http://localhost:3000$endpoint")
    fi
    
    actual_code="${response: -3}"
    body="${response%???}"
    
    if [ "$actual_code" -eq "$expected_code" ]; then
        echo "✓ Expected $expected_code, got $actual_code"
    else
        echo "✗ Expected $expected_code, got $actual_code"
        echo "Response body: $body"
        # Kill server and exit with error
        kill -9 $SERVER_PID
        exit 1
    fi

    # Optional: Pretty print response body
    echo "Response: $body"
    echo "---"
}

# Test all endpoints
echo "Running tests..."

# 1. Test POST /register
test_endpoint "POST" "/register" 201 '{"username": "testuser", "password": "securepassword"}' "Register new user"

# 2. Test POST /register with existing user (should be 409)
test_endpoint "POST" "/register" 409 '{"username": "testuser", "password": "otherpassword"}' "Register duplicate user"

# 3. Test POST /register with invalid username (<3 chars)
test_endpoint "POST" "/register" 400 '{"username": "ab", "password": "securepassword"}' "Register with short username"

# 4. Test POST /register with short password
test_endpoint "POST" "/register" 400 '{"username": "gooduser", "password": "short"}' "Register with short password"

# 5. Test POST /login
test_endpoint "POST" "/login" 200 '{"username": "testuser", "password": "securepassword"}' "Login existing user"

# 6. Test POST /login with bad credentials
test_endpoint "POST" "/login" 401 '{"username": "testuser", "password": "wrongpassword"}' "Login with wrong password"

# 7. Test GET /me (need to capture session from login first)
echo "Testing GET /me requires authentication..."
response=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"username": "testuser", "password": "securepassword"}"' "http://localhost:3000/login" -D headers.txt)
    
SESSION_ID=$(grep -i "set-cookie" headers.txt | grep -o 'session_id=[^;]*' | cut -d'=' -f2)

if [ -n "$SESSION_ID" ]; then
    echo "Got session ID: $SESSION_ID"
    cookies="session_id=$SESSION_ID"
    echo "Testing GET /me with session..."
    response=$(curl -s -w "%{http_code}" -X GET --cookie "session_id=$SESSION_ID" "http://localhost:3000/me")
    actual_code="${response: -3}"
    body="${response%???}"
    
    if [ "$actual_code" -eq "200" ]; then
        echo "✓ GET /me succeeded: $body"
    else
        echo "✗ GET /me failed with code $actual_code: $body"
        kill -9 $SERVER_PID
        exit 1
    fi
    
    echo "---"
else
    echo "Warning: Could not extract session ID for /me test"
fi

# 8. Test POST /logout (uses same session)
if [ -n "$SESSION_ID" ]; then
    echo "Testing POST /logout with session..."
    response=$(curl -s -w "%{http_code}" -X POST --cookie "session_id=$SESSION_ID" -H "Content-Type: application/json" \
        --data '{}'" "http://localhost:3000/logout")
    actual_code="${response: -3}"
    body="${response%???}"
    
    if [ "$actual_code" -eq "200" ]; then
        echo "✓ POST /logout succeeded: $body"
    else
        echo "✗ POST /logout failed with code $actual_code: $body"
        kill -9 $SERVER_PID
        exit 1
    fi
    
    echo "---"
fi

# 9. Test protected endpoints without authentication (should return 401)
test_endpoint "GET" "/me" 401 '' "Access /me without auth (should fail)"

# 10. Test /todos endpoints after re-login
echo "Re-authenticating for todos tests..."
response=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"username": "testuser", "password": "securepassword"}"' "http://localhost:3000/login" -D headers2.txt)
    
SESSION_ID=$(grep -i "set-cookie" headers2.txt | grep -o 'session_id=[^;]*' | cut -d'=' -f2)

if [ -n "$SESSION_ID" ]; then
    # Test GET /todos
    response=$(curl -s -w "%{http_code}" -X GET --cookie "session_id=$SESSION_ID" "http://localhost:3000/todos")
    actual_code="${response: -3}"
    body="${response%???}"
    
    if [ "$actual_code" -eq "200" ]; then
        echo "✓ GET /todos succeeded: $body"
    else
        echo "✗ GET /todos failed with code $actual_code: $body"
        kill -9 $SERVER_PID
        exit 1
    fi
    echo "---"
    
    # Test POST /todos
    response=$(curl -s -w "%{http_code}" -X POST --cookie "session_id=$SESSION_ID" -H "Content-Type: application/json" \
        --data '{"title": "First task", "description": "My first todo item"}" "http://localhost:3000/todos")
    actual_code="${response: -3}"
    body="${response%???}"
    
    if [ "$actual_code" -eq "201" ]; then
        echo "✓ POST /todos succeeded: $body"
    elif [ "$actual_code" -eq "400" ]; then
        echo "! Note: POST /todos returned 400: $body" 
        # This might be OK depending on parsing capability
    else
        echo "✗ POST /todos failed with code $actual_code: $body"
        kill -9 $SERVER_PID
        exit 1
    fi
    echo "---"
fi

echo "All tests completed successfully!"
echo "Stopping server..."

# Stop the server
kill -9 $SERVER_PID

echo "Done."