#!/bin/bash

# Start the server in the background
echo "Starting server..."
./run.sh --port 3000 &
SERVER_PID=$!

# Wait for server to start
sleep 2

echo "Running tests..."

# Test variables
TOKEN=""
TODO_ID=""

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
}

# Error handling
trap cleanup EXIT

# Test 1: Register a user
echo "Test 1: Registering user..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:3000/register)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ $STATUS_CODE -eq 201 ]; then
    echo "✓ Register success"
else
    echo "✗ Register failed with status $STATUS_CODE: $BODY"
    exit 1
fi

# Test 2: Try registering with same username (should fail)
echo "Test 2: Registering duplicate user..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:3000/register)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ $STATUS_CODE -eq 409 ]; then
    echo "✓ Duplicate username correctly rejected"
else
    echo "✗ Duplicate username not rejected: status $STATUS_CODE - $BODY"
    exit 1
fi

# Test 3: Login with registered user
echo "Test 3: Logging in..."
RESPONSE=$(curl -c cookies.txt -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"username":"testuser","password":"password123"}' \
    http://localhost:3000/login)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ $STATUS_CODE -eq 200 ]; then
    echo "✓ Login success"
else
    echo "✗ Login failed with status $STATUS_CODE: $BODY"
    exit 1
fi

# Test 4: Access protected resource (/me)
echo "Test 4: Accessing /me with valid session..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" \
    http://localhost:3000/me)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ $STATUS_CODE -eq 200 && "$BODY" == *"testuser"* ]]; then
    echo "✓ Access to /me successful"
else
    echo "✗ Failed to access /me: status $STATUS_CODE - $BODY"
    exit 1
fi

# Test 5: Try to access protected resource without auth
echo "Test 5: Accessing /me without authentication..."
RESPONSE=$(curl -s -w "\n%{http_code}" \
    http://localhost:3000/me)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ $STATUS_CODE -eq 401 && "$BODY" == *"Authentication required"* ]]; then
    echo "✓ Unauthenticated access properly blocked"
else
    echo "✗ Unauthenticated access not blocked: status $STATUS_CODE - $BODY"
    exit 1
fi

# Test 6: Create a todo
echo "Test 6: Creating a todo..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
    -d '{"title":"Test Todo","description":"This is a test"}' \
    http://localhost:3000/todos)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ $STATUS_CODE -eq 201 && "$BODY" == *"Test Todo"* ]]; then
    TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "✓ Todo created with ID: $TODO_ID"
else
    echo "✗ Failed to create todo: status $STATUS_CODE - $BODY"
    exit 1
fi

# Test 7: Get the todo
echo "Test 7: Getting a specific todo..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" \
    http://localhost:3000/todos/$TODO_ID)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
OUTPUT=$(echo "$RESPONSE" | head -n-1)

if [[ $STATUS_CODE -eq 200 && "$OUTPUT" == *"Test Todo"* ]]; then
    echo "✓ Todo retrieved successfully"
else
    echo "✗ Failed to retrieve todo: status $STATUS_CODE - $OUTPUT"
    cat cookies.txt
    curl -b cookies.txt -s http://localhost:3000/todos  # for debugging
    exit 1
fi

# Test 8: Update the todo
echo "Test 8: Updating the todo..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" \
    -d '{"title":"Updated Todo","completed":true}' \
    http://localhost:3000/todos/$TODO_ID)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ $STATUS_CODE -eq 200 && "$BODY" == *"Updated Todo"* && "$BODY" == *"true"* ]]; then
    echo "✓ Todo updated successfully"
else
    echo "✗ Failed to update todo: status $STATUS_CODE - $BODY"
    exit 1
fi

# Test 9: Get all todos
echo "Test 9: Getting all todos..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" \
    http://localhost:3000/todos)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ $STATUS_CODE -eq 200 && "$BODY" == *"$TODO_ID"* ]]; then
    echo "✓ Retrieved all todos successfully"
else
    echo "✗ Failed to retrieve todos: status $STATUS_CODE - $BODY"
    exit 1
fi

# Test 10: Delete the todo
echo "Test 10: Deleting the todo..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" -X DELETE \
    http://localhost:3000/todos/$TODO_ID)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)

if [ $STATUS_CODE -eq 204 ]; then
    echo "✓ Todo deleted successfully"
else
    echo "✗ Failed to delete todo: status $STATUS_CODE"
    exit 1
fi

# Test 11: Try to get deleted todo (should fail)
echo "Test 11: Trying to access deleted todo..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" \
    http://localhost:3000/todos/$TODO_ID)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ $STATUS_CODE -eq 404 && "$BODY" == *"Todo not found"* ]]; then
    echo "✓ Deleted todo correctly returns 404"
else
    echo "✗ Getting deleted todo didn't return 404: status $STATUS_CODE - $BODY"
    exit 1
fi

# Test 12: Change password
echo "Test 12: Changing password..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" \
    -d '{"old_password":"password123","new_password":"newpassword123"}' \
    http://localhost:3000/password)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ $STATUS_CODE -eq 200 ]; then
    echo "✓ Password changed successfully"
else
    echo "✗ Failed to change password: status $STATUS_CODE - $BODY"
    exit 1
fi

# Test 13: Logout
echo "Test 13: Logging out..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" -X POST \
    http://localhost:3000/logout)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [ $STATUS_CODE -eq 200 ]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed: status $STATUS_CODE - $BODY"
    exit 1
fi

# Verify logout worked by trying to access protected resource
echo "Test 14: Verifying logout disabled access..."
RESPONSE=$(curl -b cookies.txt -s -w "\n%{http_code}" \
    http://localhost:3000/me)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

if [[ $STATUS_CODE -eq 401 && "$BODY" == *"Authentication required"* ]]; then
    echo "✓ Logout correctly prevents access"
else
    echo "✗ Logout did not work as expected: status $STATUS_CODE - $BODY"
    exit 1
fi

echo "All tests passed!"

# Cleanup
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null
rm -f cookies.txt