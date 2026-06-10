#!/bin/bash

# Test script to verify that the API implementation works correctly

# Start server in background
echo "Starting server on port 8080..."
java -cp out com.todoserver.Main --port 8080 &
SERVER_PID=$!
sleep 2

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Failed to start server"
    exit 1
fi

echo "Server is running with PID $SERVER_PID"

# Function to cleanup
cleanup() {
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
}

# Trap to ensure cleanup happens
trap cleanup EXIT

# Test variables
COOKIE_FILE=$(mktemp)

# Test 1: Register a new user
echo "Test 1: Register user"
RESPONSE=$(curl -s -w "%{http_code}" \
    -X POST http://localhost:8080/register \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

echo "Status: $HTTP_CODE, Response: $BODY"

if [ "$HTTP_CODE" -eq 201 ] && [[ "$BODY" == *"testuser"* ]] && [[ "$BODY" == *"id"* ]]; then
    echo "✓ Register test passed"
else
    echo "✗ Register test failed"
    cleanup
    exit 1
fi

# Test 2: Register duplicate username
echo "Test 2: Register duplicate username"
RESPONSE=$(curl -s -w "%{http_code}" \
    -X POST http://localhost:8080/register \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "differentpass123"}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 409 ] && [[ "$BODY" == *"already exists"* ]]; then
    echo "✓ Duplicate registration test passed"
else
    echo "✗ Duplicate registration test failed"
    cleanup
    exit 1
fi

# Test 3: Login with registered user
echo "Test 3: Login with registered user"
RESPONSE=$(curl -s -c $COOKIE_FILE -w "%{http_code}" \
    -X POST http://localhost:8080/login \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 200 ] && [[ "$BODY" == *"testuser"* ]]; then
    echo "✓ Login test passed"
else
    echo "✗ Login test failed"
    cleanup
    exit 1
fi

# Test 4: Access protected resource (/me)
echo "Test 4: Access /me endpoint"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    http://localhost:8080/me)

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 200 ] && [[ "$BODY" == *"testuser"* ]]; then
    echo "✓ /me endpoint test passed"
else
    echo "✗ /me endpoint test failed"
    cleanup
    exit 1
fi

# Test 5: Create a todo
echo "Test 5: Create a todo"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    -X POST http://localhost:8080/todos \
    -H "Content-Type: application/json" \
    -d '{"title": "My first todo", "description": "This is a test todo"}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 201 ] && [[ "$BODY" == *"My first todo"* ]]; then
    TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "✓ Create todo test passed (ID: $TODO_ID)"
else
    echo "✗ Create todo test failed"
    cleanup
    exit 1
fi

# Test 6: Get all todos
echo "Test 6: Get all todos"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    http://localhost:8080/todos)

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 200 ] && [[ "$BODY" == *"$TODO_ID"* ]]; then
    echo "✓ Get all todos test passed"
else
    echo "✗ Get all todos test failed"
    cleanup
    exit 1
fi

# Test 7: Get specific todo
echo "Test 7: Get specific todo"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    http://localhost:8080/todos/$TODO_ID)

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 200 ] && [[ "$BODY" == *"My first todo"* ]]; then
    echo "✓ Get specific todo test passed"
else
    echo "✗ Get specific todo test failed"
    cleanup
    exit 1
fi

# Test 8: Update specific todo
echo "Test 8: Update specific todo"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    -X PUT http://localhost:8080/todos/$TODO_ID \
    -H "Content-Type: application/json" \
    -d '{"title": "Updated todo", "completed": true}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 200 ] && [[ "$BODY" == *"Updated todo"* ]] && [[ "$BODY" == *"true"* ]]; then
    echo "✓ Update specific todo test passed"
else
    echo "✗ Update specific todo test failed"
    cleanup
    exit 1
fi

# Test 9: Delete specific todo
echo "Test 9: Delete specific todo"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    -X DELETE http://localhost:8080/todos/$TODO_ID)

HTTP_CODE="${RESPONSE: -3}"

if [ "$HTTP_CODE" -eq 204 ]; then
    echo "✓ Delete specific todo test passed"
else
    echo "✗ Delete specific todo test failed"
    cleanup
    exit 1
fi

# Test 10: Try to access non-existent todo after deletion
echo "Test 10: Access deleted todo (should fail)"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    http://localhost:8080/todos/$TODO_ID)

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 404 ] && [[ "$BODY" == *"not found"* ]]; then
    echo "✓ Access deleted todo test passed"
else
    echo "✗ Access deleted todo test failed"
    cleanup
    exit 1
fi

# Test 11: Change password
echo "Test 11: Update password"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    -X PUT http://localhost:8080/password \
    -H "Content-Type: application/json" \
    -d '{"old_password": "password123", "new_password": "newpassword123"}')

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 200 ]; then
    echo "✓ Update password test passed"
else
    echo "✗ Update password test failed"
    cleanup
    exit 1
fi

# Test 12: Logout
echo "Test 12: Logout"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    -X POST http://localhost:8080/logout)

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 200 ]; then
    echo "✓ Logout test passed"
else
    echo "✗ Logout test failed"
    cleanup
    exit 1
fi

# Test 13: Try to access protected resource after logout (should fail)
echo "Test 13: Access /me after logout (should fail)"
RESPONSE=$(curl -s -b $COOKIE_FILE -w "%{http_code}" \
    http://localhost:8080/me)

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [ "$HTTP_CODE" -eq 401 ]; then
    echo "✓ Access after logout test passed"
else
    echo "✗ Access after logout test failed"
    cleanup
    exit 1
fi

# Clean up
rm $COOKIE_FILE
echo "All tests passed!"
cleanup
exit 0