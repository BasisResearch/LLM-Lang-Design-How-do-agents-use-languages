#!/bin/bash

# Test script for Todo API server

echo "Starting server..."
./run.sh --port 8080 &
SERVER_PID=$!
sleep 3

# Kill server on exit 
trap 'kill $SERVER_PID 2>/dev/null' EXIT

echo "Testing endpoints..."

# Wait a bit for server startup
sleep 2

# Test 1: POST /register
echo -e "\n--- Testing POST /register ---"
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')

status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n1)

if [ "$status_code" -eq 201 ]; then
    echo "✓ Registration successful"
else
    echo "✗ Registration failed - Status: $status_code, Response: $body"
    exit 1
fi

# Extract session cookie from registration response
SESSION_FILE="cookies.txt"
curl -c $SESSION_FILE -s -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"otheruser","password":"password123"}'

# Test 2: Register duplicate username - expect 409
echo -e "\n--- Testing duplicate username ---"
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')

status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 409 ]; then
    echo "✓ Duplicate registration correctly rejected"
else
    echo "✗ Should have rejected duplicate username"
    exit 1
fi

# Test 3: POST /login
echo -e "\n--- Testing POST /login ---"
response=$(curl -s -c cookies.txt -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')

status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n1)

if [ "$status_code" -eq 200 ]; then
    echo "✓ Login successful"
else
    echo "✗ Login failed - Status: $status_code, Response: $body"
    exit 1
fi

# Test 4: GET /me (requires auth)
echo -e "\n--- Testing GET /me ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" http://localhost:8080/me)
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n1)

if [ "$status_code" -eq 200 ]; then
    echo "✓ GET /me successful"
    # Verify it's the right user
    user_id=$(echo $body | grep -o '"id":[0-9]*' | cut -d':' -f2)
    username=$(echo $body | grep -o '"username":"[^"]*"' | cut -d':' -f2 | tr -d '"')
    if [ "$username" = "testuser" ]; then
        echo "✓ Correct user returned"
    else
        echo "✗ Wrong user returned"
        exit 1
    fi
else
    echo "✗ GET /me failed - Status: $status_code, Response: $body"
    exit 1
fi

# Test 5: POST /todos without title - expect 400
echo -e "\n--- Testing POST /todos validation ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"","description":"Test desc"}')

status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 400 ]; then
    echo "✓ Empty title correctly rejected"
else
    echo "✗ Should have rejected empty title, but got: $response ($status_code)"
    exit 1
fi

# Test 6: POST /todos
echo -e "\n--- Testing POST /todos ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"Test Todo","description":"This is a test"}')

status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n1)

if [ "$status_code" -eq 201 ]; then
    echo "✓ Todo creation successful"
    # Extract the created todo ID
    TODO_ID=$(echo $body | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "Created todo ID: $TODO_ID"
else
    echo "✗ Todo creation failed - Status: $status_code, Response: $body"
    exit 1
fi

# Test 7: GET /todos
echo -e "\n--- Testing GET /todos ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" http://localhost:8080/todos)
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n1)

if [ "$status_code" -eq 200 ] && [[ "$body" == *"$TODO_ID"* ]]; then
    echo "✓ GET /todos successful"
else
    echo "✗ GET /todos failed - Status: $status_code, Response: $body"
    exit 1
fi

# Test 8: GET /todos/:id
echo -e "\n--- Testing GET /todos/:id ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" http://localhost:8080/todos/$TODO_ID)
status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n1)

if [ "$status_code" -eq 200 ]; then
    echo "✓ GET /todos/:id successful"
else
    echo "✗ GET /todos/:id failed - Status: $status_code, Response: $body"
    exit 1
fi

# Test 9: PUT /todos/:id
echo -e "\n--- Testing PUT /todos/:id ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" -X PUT http://localhost:8080/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated Title","completed":true}')

status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n1)

if [ "$status_code" -eq 200 ]; then
    echo "✓ PUT /todos/:id successful"
    # Verify the updates were applied
    if [[ "$body" == *"Updated Title"* ]] && [[ "$body" == *"completed"* ]] && [[ "$body" == *"true"* ]]; then
        echo "✓ Updates applied correctly"
    else
        echo "✗ Updates not applied properly: $body"
        exit 1
    fi
else
    echo "✗ PUT /todos/:id failed - Status: $status_code, Response: $body"
    exit 1
fi

# Test 10: Try to update with empty title - should fail
echo -e "\n--- Testing PUT /todos/:id with empty title ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" -X PUT http://localhost:8080/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title":""}')

status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 400 ]; then
    echo "✓ Empty title update correctly rejected"
else
    echo "✗ Should have rejected empty title update, Status: $status_code"
    exit 1
fi

# Test 11: DELETE /todos/:id
echo -e "\n--- Testing DELETE /todos/:id ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" -X DELETE http://localhost:8080/todos/$TODO_ID)
status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 204 ]; then
    echo "✓ DELETE /todos/:id successful"
else
    echo "✗ DELETE /todos/:id failed - Status: $status_code, Response: $body"
    exit 1
fi

# Test 12: GET /todos/:id after deletion - should be 404
echo -e "\n--- Testing GET /todos/:id after deletion ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" http://localhost:8080/todos/$TODO_ID)
status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 404 ]; then
    echo "✓ Deleted todo correctly returns 404"
else
    echo "✗ Deleted todo should return 404, got: $status_code"
    exit 1
fi

# Test 13: PUT /password
echo -e "\n--- Testing PUT /password ---"
response=$(curl -b cookies.txt -s -w "\n%{http_code}" -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword456"}')

status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 200 ]; then
    echo "✓ Password change successful"
else
    echo "✗ Password change failed - Status: $status_code, Response: $body"
    exit 1
fi

# Test 14: Login with old password - should fail
echo -e "\n--- Testing login with old password ---"
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')

status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 401 ]; then
    echo "✓ Old password correctly rejected"
else
    echo "✗ Should have rejected old password"
    exit 1
fi

# Test 15: Login with new password - should succeed
echo -e "\n--- Testing login with new password ---"
response=$(curl -s -c new_cookies.txt -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpassword456"}')

status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 200 ]; then
    echo "✓ New password accepted"
else
    echo "✗ New password rejected - Status: $status_code, Response: $body"
    exit 1
fi

# Test 16: POST /logout
echo -e "\n--- Testing POST /logout ---"
response=$(curl -b new_cookies.txt -s -w "\n%{http_code}" -X POST http://localhost:8080/logout)
status_code=$(echo "$response" | tail -n1)

if [ "$status_code" -eq 200 ]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed - Status: $status_code, Response: $body"
    exit 1
fi

# Clean up cookie files
rm -f cookies.txt new_cookies.txt

echo -e "\n==============================================="
echo "All tests passed! 🎉 Server implementation is correct."
echo "==============================================="

# Kill server process
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null