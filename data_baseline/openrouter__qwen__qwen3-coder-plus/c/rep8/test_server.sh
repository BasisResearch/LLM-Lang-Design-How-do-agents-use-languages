#!/bin/bash

# Test script for the todo server
SERVER_URL="http://localhost:8080"
SESSION_FILE=$(mktemp)

echo "Testing Todo App API..."

# Start the server in the background
./server --port 8080 &
SERVER_PID=$!
sleep 2  # Give server time to start

# Test registration endpoint
echo "Testing POST /register..."
RESPONSE=$(curl -s -w "%{http_code}" -X POST $SERVER_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ $HTTP_CODE -eq 201 ] && [[ $BODY == *"testuser"* ]]; then
    echo "✓ Registration successful"
else
    echo "✗ Registration failed: $BODY (Code: $HTTP_CODE)"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test registration with invalid username
echo "Testing invalid registration..."
RESPONSE=$(curl -s -w "%{http_code}" -X POST $SERVER_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username":"ab","password":"password123"}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ $HTTP_CODE -eq 400 ]; then
    echo "✓ Registration validation works"
else
    echo "✗ Registration validation failed: $BODY (Code: $HTTP_CODE)"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test login endpoint
echo "Testing POST /login..."
RESPONSE=$(curl -s -c $SESSION_FILE -w "%{http_code}" -X POST $SERVER_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ $HTTP_CODE -eq 200 ] && [[ $BODY == *"testuser"* ]]; then
    echo "✓ Login successful"
else
    echo "✗ Login failed: $BODY (Code: $HTTP_CODE)"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test /me endpoint (should work with valid session)
echo "Testing GET /me..."
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" $SERVER_URL/me)

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ $HTTP_CODE -eq 200 ] && [[ $BODY == *"testuser"* ]]; then
    echo "✓ GET /me successful"
else
    echo "✗ GET /me failed: $BODY (Code: $HTTP_CODE)"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test /me without session (should fail)
echo "Testing GET /me without session..."
RESPONSE=$(curl -s -w "%{http_code}" $SERVER_URL/me)
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 401 ]; then
    echo "✓ Authentication protecting /me endpoint works"
else
    echo "✗ Authentication on /me failed: Code $HTTP_CODE"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test creating todos
echo "Testing POST /todos..."
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" -X POST $SERVER_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"First Todo","description":"My first task"}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ $HTTP_CODE -eq 201 ] && [[ $BODY == *"First Todo"* ]]; then
    TODO_ID=$(echo $BODY | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "✓ Created todo with ID: $TODO_ID"
else
    echo "✗ Failed to create todo: $BODY (Code: $HTTP_CODE)"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Create another todo
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" -X POST $SERVER_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"Second Todo","description":"Another task"}')
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 201 ]; then
    TODO_ID2=$(echo $(curl -s -b $SESSION_FILE -X POST $SERVER_URL/todos \
      -H "Content-Type: application/json" \
      -d '{"title":"Second Todo","description":"Another task"}') | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "✓ Created second todo with ID: $TODO_ID2"
else
    echo "✗ Failed to create second todo (Code: $HTTP_CODE)"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test retrieving all todos
echo "Testing GET /todos..."
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" $SERVER_URL/todos)

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ $HTTP_CODE -eq 200 ] && [[ $BODY == *"$TODO_ID"* ]] && [[ $BODY == *"$TODO_ID2"* ]]; then
    echo "✓ Retrieved all todos successfully"
else
    echo "✗ Failed to retrieve todos: $BODY (Code: $HTTP_CODE)"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test getting specific todo
echo "Testing GET /todos/{id}..."
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" $SERVER_URL/todos/$TODO_ID)

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ $HTTP_CODE -eq 200 ] && [[ $BODY == *"First Todo"* ]]; then
    echo "✓ Retrieved specific todo successfully"
else
    echo "✗ Failed to retrieve specific todo: $BODY (Code: $HTTP_CODE)"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test updating a todo
echo "Testing PUT /todos/{id}..."
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" -X PUT $SERVER_URL/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated First Todo","completed":true}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ $HTTP_CODE -eq 200 ] && [[ $BODY == *"Updated First Todo"* ]] && [[ $BODY == *"true"* ]]; then
    echo "✓ Updated todo successfully"
else
    echo "✗ Failed to update todo: $BODY (Code: $HTTP_CODE)"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test changing password
echo "Testing PUT /password..."
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" -X PUT $SERVER_URL/password \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword456"}')

HTTP_CODE="${RESPONSE: -3}"
if [ $HTTP_CODE -eq 200 ]; then
    echo "✓ Password change successful"
else
    echo "✗ Password change failed: Code $HTTP_CODE"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Try re-authenticating with new password
echo "Testing re-login with new password..."
RESPONSE=$(curl -s -c $SESSION_FILE.new -w "%{http_code}" -X POST $SERVER_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpassword456"}')

HTTP_CODE="${RESPONSE: -3}"
if [ $HTTP_CODE -eq 200 ]; then
    echo "✓ Re-Login with new password successful"
    mv $SESSION_FILE.new $SESSION_FILE
else
    echo "✗ Re-Login with new password failed: Code $HTTP_CODE"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test deleting a todo
echo "Testing DELETE /todos/{id}..."
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" -X DELETE $SERVER_URL/todos/$TODO_ID)

HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 204 ]; then
    echo "✓ Deleted todo successfully"
else
    echo "✗ Failed to delete todo: Code $HTTP_CODE"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Verify deletion - requesting the deleted todo should give 404
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" $SERVER_URL/todos/$TODO_ID)
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 404 ]; then
    echo "✓ Todo properly removed (returns 404)"
else
    echo "✗ Todo not properly removed: Code $HTTP_CODE"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Test logout
echo "Testing POST /logout..."
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" -X POST $SERVER_URL/logout)
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 200 ]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed: Code $HTTP_CODE"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

# Try accessing protected resource after logout (should fail)
RESPONSE=$(curl -s -b $SESSION_FILE -w "%{http_code}" $SERVER_URL/me)
HTTP_CODE="${RESPONSE: -3}"

if [ $HTTP_CODE -eq 401 ]; then
    echo "✓ Logout properly invalidated session"
else
    echo "✗ Session still valid after logout: Code $HTTP_CODE"
    kill $SERVER_PID
    rm -f $SESSION_FILE
    exit 1
fi

kill $SERVER_PID
rm -f $SESSION_FILE

echo
echo "✓ All tests passed!"