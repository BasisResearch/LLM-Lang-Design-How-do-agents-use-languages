#!/bin/bash

echo "Starting comprehensive test of Todo App API..."

# Start server in the background
PORT=8080
./run.sh --port $PORT &
SERVER_PID=$!
echo "Server started with PID: $SERVER_PID"

# Give server time to start
sleep 3

# Test that server is responsive
if curl -s http://localhost:$PORT/register >/dev/null 2>&1; then
    echo "✓ Server is running and accepting connections"
else
    echo "✗ Server is not responding"
    kill $SERVER_PID 2>/dev/null
    exit 1
fi

# Initialize a file to track cookies
COOKIE_JAR="cookies.txt"
touch $COOKIE_JAR

# Test 1: Register new user
echo ""
echo "Test 1: Registering new user..."
RESPONSE=$(curl -s -c $COOKIE_JAR -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  "http://localhost:$PORT/register")

if echo "$RESPONSE" | grep -q '"id":1' && echo "$RESPONSE" | grep -q '"username":"testuser"'; then
    echo "✓ Registration successful"
else
    echo "✗ Registration failed: $RESPONSE"
fi

# Test 2: Attempt to register duplicate user
echo ""
echo "Test 2: Attempting to register duplicate user..."
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  "http://localhost:$PORT/register")

if echo "$RESPONSE" | grep -q '"error":"Username already exists"'; then
    echo "✓ Duplicate username rejection works"
else
    echo "✗ Duplicate username not rejected: $RESPONSE"
fi

# Test 3: Login with valid credentials
echo ""
echo "Test 3: Logging in with valid credentials..."
RESPONSE=$(curl -s -c $COOKIE_JAR -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  "http://localhost:$PORT/login")

if echo "$RESPONSE" | grep -q '"id":1' && echo "$RESPONSE" | grep -q '"username":"testuser"'; then
    echo "✓ Login successful"
else
    echo "✗ Login failed: $RESPONSE"
fi

# Test 4: Access to protected resource after login
echo ""
echo "Test 4: Accessing /me endpoint after login..."
RESPONSE=$(curl -s -b $COOKIE_JAR -X GET "http://localhost:$PORT/me")

if echo "$RESPONSE" | grep -q '"id":1' && echo "$RESPONSE" | grep -q '"username":"testuser"'; then
    echo "✓ /me endpoint accessible after login"
else
    echo "✗ /me endpoint failed: $RESPONSE"
fi

# Test 5: Access to protected resource without auth
echo ""
echo "Test 5: Accessing /me without authentication..."
RESPONSE=$(curl -s -X GET "http://localhost:$PORT/me")

if echo "$RESPONSE" | grep -q '"error":"Authentication required"'; then
    echo "✓ Unauthenticated access correctly rejected"
else
    echo "✗ Unauthenticated access should be rejected: $RESPONSE"
fi

# Test 6: Create a todo item
echo ""
echo "Test 6: Creating a todo item..."
RESPONSE=$(curl -s -b $COOKIE_JAR -X POST \
  -H "Content-Type: application/json" \
  -d '{"title":"Buy groceries","description":"Milk, bread, eggs"}' \
  "http://localhost:$PORT/todos")

if echo "$RESPONSE" | grep -q '"title":"Buy groceries"' && echo "$RESPONSE" | grep -q '"completed":false'; then
    TODO_ID=$(echo "$RESPONSE" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
    echo "✓ Todo created with ID: $TODO_ID"
else
    echo "✗ Todo creation failed: $RESPONSE"
fi

# Test 7: Get todo list
echo ""
echo "Test 7: Retrieving todo list..."
RESPONSE=$(curl -s -b $COOKIE_JAR -X GET "http://localhost:$PORT/todos")

if echo "$RESPONSE" | grep -q '"title":"Buy groceries"'; then
    echo "✓ Todo list retrieval successful"
else
    echo "✗ Todo list retrieval failed: $RESPONSE"
fi

# Test 8: Get specific todo
echo ""
echo "Test 8: Retrieving specific todo..."
RESPONSE=$(curl -s -b $COOKIE_JAR -X GET "http://localhost:$PORT/todos/$TODO_ID")

if echo "$RESPONSE" | grep -q "\"id\":$TODO_ID" && echo "$RESPONSE" | grep -q '"title":"Buy groceries"'; then
    echo "✓ Specific todo retrieval successful"
else
    echo "✗ Specific todo retrieval failed: $RESPONSE"
fi

# Test 9: Update a todo item (partial update)
echo ""
echo "Test 9: Updating todo (partial update)..."
RESPONSE=$(curl -s -b $COOKIE_JAR -X PUT \
  -H "Content-Type: application/json" \
  -d '{"completed":true,"description":"Updated description"}' \
  "http://localhost:$PORT/todos/$TODO_ID")

if echo "$RESPONSE" | grep -q '"completed":true' && echo "$RESPONSE" | grep -q '"description":"Updated description"'; then
    echo "✓ Partial update successful"
else
    echo "✗ Partial update failed: $RESPONSE"
fi

# Test 10: Delete a todo
echo ""
echo "Test 10: Deleting a todo..."
STATUS=$(curl -s -b $COOKIE_JAR -o /dev/null -w "%{http_code}" -X DELETE "http://localhost:$PORT/todos/$TODO_ID")

if [ "$STATUS" -eq 204 ]; then
    echo "✓ Todo deletion successful"
else
    echo "✗ Todo deletion failed with status: $STATUS"
fi

# Test 11: Try to access deleted todo
echo ""
echo "Test 11: Trying to access deleted todo..."
RESPONSE=$(curl -s -b $COOKIE_JAR -X GET "http://localhost:$PORT/todos/$TODO_ID")
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X GET "http://localhost:$PORT/todos/$TODO_ID")

if echo "$RESPONSE" | grep -q '"error":"Todo not found"' && [ "$STATUS" -eq 404 ]; then
    echo "✓ Access to deleted todo correctly fails"
else
    echo "✗ Deleted todo should not be accessible: $RESPONSE"
fi

# Test 12: Change password
echo ""
echo "Test 12: Changing user password..."
RESPONSE=$(curl -s -b $COOKIE_JAR -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword456"}' \
  "http://localhost:$PORT/password")

STATUS=$(curl -s -b $COOKIE_JAR -o /dev/null -w "%{http_code}" \
  -X PUT -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword456"}' \
  "http://localhost:$PORT/password")

if [ "$STATUS" -eq 200 ]; then
    echo "✓ Password change successful"
else
    echo "✗ Password change failed with status: $STATUS - $RESPONSE"
fi

# Verify new password works for login after logout
# First logout
echo ""
echo "Test 13: Logging out..."
RESPONSE=$(curl -s -b $COOKIE_JAR -X POST "http://localhost:$PORT/logout")

if echo "$RESPONSE" | grep -q '{}'; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed: $RESPONSE"
fi

# Then login with new password 
echo ""
echo "Test 14: Logging in with new password..."
RESPONSE=$(curl -s -c $COOKIE_JAR -X POST \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpassword456"}' \
  "http://localhost:$PORT/login")

if echo "$RESPONSE" | grep -q '"id":1'; then
    echo "✓ Login with new password successful"
else
    echo "✗ Login with new password failed: $RESPONSE"
fi

# Test 15: Unauthenticated attempt after logout (verifying session invalidation)
echo ""
echo "Test 15: Verifying session invalidation after logout..."
# Clear cookies to simulate fresh session without auth
rm -f $COOKIE_JAR
touch $COOKIE_JAR
RESPONSE=$(curl -s -X GET "http://localhost:$PORT/me")

if echo "$RESPONSE" | grep -q '"error":"Authentication required"'; then
    echo "✓ Session invalidated correctly after logout"
else
    echo "✗ Session should be invalidated: $RESPONSE"
fi

# Cleanup
rm -f $COOKIE_JAR
kill $SERVER_PID 2>/dev/null

echo ""
echo "Comprehensive testing completed!"