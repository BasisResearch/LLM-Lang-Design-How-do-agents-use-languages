#!/bin/bash

PORT=4567
SERVER_URL="http://localhost:$PORT"

echo "Starting server on port $PORT..."
node server.js --port $PORT &
SERVER_PID=$!
sleep 2  # Give server time to start

echo "Testing API..."

# Test 1: Register user
echo "1. Registering user..."
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  $SERVER_URL/register)

if [ $? -eq 0 ] && echo "$RESPONSE" | grep -q '"id"'; then
    echo "✓ Registration successful"
else
    echo "✗ Registration failed: $RESPONSE"
fi

# Test 2: Register another user 
echo "2. Registering second user..."
RESPONSE=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser2","password":"password456"}' \
  $SERVER_URL/register)

if [ $? -eq 0 ] && echo "$RESPONSE" | grep -q '"id"'; then
    echo "✓ Second registration successful"
else  
    echo "✗ Second registration failed: $RESPONSE"
fi

# Test 3: Login and capture cookie
echo "3. Logging in..."
RESPONSE=$(curl -s -c cookies.txt -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  $SERVER_URL/login)

if [ $? -eq 0 ] && grep -q "session_id" cookies.txt; then
    echo "✓ Login successful, cookie captured"
else
    echo "✗ Login failed: $RESPONSE"
fi

# Test 4: Get user profile with cookie
echo "4. Getting user profile..."
RESPONSE=$(curl -s -b cookies.txt $SERVER_URL/me)

if [ $? -eq 0 ] && echo "$RESPONSE" | grep -q '"id"'; then
    echo "✓ Profile retrieved"
else
    echo "✗ Profile request failed: $RESPONSE"
fi

# Test 5: Create a todo
echo "5. Creating todo..."
RESPONSE=$(curl -s -X POST -b cookies.txt -H "Content-Type: application/json" \
  -d '{"title":"Test todo","description":"A test task"}' \
  $SERVER_URL/todos)

if [ $? -eq 0 ] && echo "$RESPONSE" | grep -q '"id"'; then
    TODO_ID=$(echo "$RESPONSE" | sed -n 's/.*"id":[[:space:]]*\([0-9]*\).*/\1/p')
    echo "✓ Todo created with ID $TODO_ID"
else
    echo "✗ Todo creation failed: $RESPONSE"
fi

# Test 6: Get todos
echo "6. Retrieving todos..."
RESPONSE=$(curl -s -b cookies.txt $SERVER_URL/todos)

if [ $? -eq 0 ] && echo "$RESPONSE" | grep -E -o '"id":[[:space:]]*[0-9]+' | grep -q "$TODO_ID"; then
    echo "✓ Todo retrieval successful"
else
    echo "✗ Todo retrieval failed: $RESPONSE"
fi

# Test 7: Get todo by ID
echo "7. Getting specific todo..."
RESPONSE=$(curl -s -b cookies.txt $SERVER_URL/todos/$TODO_ID)

if [ $? -eq 0 ] && echo "$RESPONSE" | grep -q "\"id\":$TODO_ID"; then
    echo "✓ Retrieved specific todo"
else
    echo "✗ Specific todo retrieval failed: $RESPONSE"
fi

# Test 8: Update todo
echo "8. Updating todo..."
RESPONSE=$(curl -s -X PUT -b cookies.txt -H "Content-Type: application/json" \
  -d '{"title":"Updated title","completed":true}' \
  $SERVER_URL/todos/$TODO_ID)

if [ $? -eq 0 ] && echo "$RESPONSE" | grep -q "Updated title"; then
    echo "✓ Todo update successful"
else
    echo "✗ Todo update failed: $RESPONSE"
fi

# Test 9: Delete todo
echo "9. Deleting todo..."
http_status=$(curl -s -o /tmp/output -w "%{http_code}" -X DELETE -b cookies.txt \
  $SERVER_URL/todos/$TODO_ID)

if [ $http_status -eq 204 ]; then
    echo "✓ Todo deletion successful (status: $http_status)"
else
    RESPONSE=$(cat /tmp/output)
    echo "✗ Todo deletion failed: status $http_status, response: $RESPONSE"
fi

# Cleanup
rm -f cookies.txt
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

echo "Test complete!"