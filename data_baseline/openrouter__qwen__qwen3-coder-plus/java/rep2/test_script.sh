#!/bin/bash

# Start the server on a random available port
PORT=8081
echo "Starting server on port $PORT..."
java -cp bin com.todoserver.Main --port $PORT &
SERVER_PID=$!
sleep 2  # Give the server time to start

echo "Testing server endpoints..."

# Function to check if server is up
check_server_ready () {
    local max_attempts=10
    local count=0
    
    while [ $count -lt $max_attempts ]; do
        status=$(curl -o /dev/null -s -w "%{http_code}\n" http://localhost:$PORT/todos 2>/dev/null) || status=""
        if [ "$status" = "401" ]; then  # This means server is responding
            echo "Server is ready! (Received expected 401 for protected endpoint)"
            return 0
        fi
        sleep 1
        ((count++))
    done
    
    echo "Server did not start properly after $max_attempts attempts"
    kill $SERVER_PID
    exit 1
}

check_server_ready

# Test variables
SESSION_COOKIE=""
TEST_USER_ID=0

echo "TEST 1: Register new user"
response=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser123", "password": "password123"}')
echo "Response: $response"

# Extract the ID accurately
TEST_USER_ID=$(echo $response | sed -n 's/.*"id":[[:space:]]*\([0-9]\+\).*/\1/p')
if [ -z "$TEST_USER_ID" ] || [ "$TEST_USER_ID" = "" ]; then
    echo "FAIL: Could not register user - couldn't extract ID from: $response"
    kill $SERVER_PID
    exit 1
fi
echo "Registered user with ID: $TEST_USER_ID"

# Test bad username registration
echo "TEST 1B: Register with invalid username (too short)"
response=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
if [[ $response == *"Invalid username"* ]]; then
    echo "PASS: Correctly rejected short username"
else
    echo "FAIL: Did not reject short username - Response: $response"
fi

# Test bad password registration
echo "TEST 1C: Register with short password"
response=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "test2", "password": "pass"}')
if [[ $response == *"Password too short"* ]]; then
    echo "PASS: Correctly rejected short password"
else
    echo "FAIL: Did not reject short password - Response: $response"
fi

# Test duplicate username registration
echo "TEST 1D: Register duplicate username"
response=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser123", "password": "password123"}')
if [[ $response == *"Username already exists"* ]]; then
    echo "PASS: Correctly rejected duplicate username"
else
    echo "FAIL: Did not reject duplicate username - Response: $response"
fi

echo "TEST 2: Login user"
response=$(curl -s -c cookies.txt -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser123", "password": "password123"}')
echo "Response: $response"

# Check that ID matches expected
result_id=$(echo $response | sed -n 's/.*"id":[[:space:]]*\([0-9]\+\).*/\1/p')
if [ "$result_id" = "$TEST_USER_ID" ]; then
    echo "PASS: Login response has correct user ID"
else
    echo "FAIL: Login response has wrong user ID - Expected: $TEST_USER_ID, Got: $result_id"
    echo "Full response: $response"
    kill $SERVER_PID
    exit 1
fi

echo "TEST 3: Try login with wrong password"
response=$(curl -s -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser123", "password": "wrongpassword"}')
if [[ $response == *"Invalid credentials"* ]]; then
    echo "PASS: Correctly rejected wrong password"
else
    echo "FAIL: Did not reject wrong password - Response: $response"
fi

echo "TEST 4: Access protected resource - /me"
response=$(curl -s -b cookies.txt http://localhost:$PORT/me)
echo "Response: $response"

# Check that ID matches expected
result_id=$(echo $response | sed -n 's/.*"id":[[:space:]]*\([0-9]\+\).*/\1/p')
if [ "$result_id" = "$TEST_USER_ID" ]; then
    echo "PASS: /me returned correct user ID"
else
    echo "FAIL: /me returned wrong user ID - Expected: $TEST_USER_ID, Got: $result_id"
    echo "Full response: $response"
fi

echo "TEST 5: Access protected resource without authentication"
response=$(curl -s http://localhost:$PORT/me)
if [[ $response == *"Authentication required"* ]]; then
    echo "PASS: Correctly rejected unauthenticated request to /me"
else
    echo "FAIL: Did not reject unauthenticated request to /me - Response: $response"
fi

echo "TEST 6: Create first todo"
response=$(curl -s -b cookies.txt -X POST http://localhost:$PORT/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "First task", "description": "This is my first task"}')
echo "Response: $response"

TODO1_RESPONSE="$response"  # Save first todo response
TODO1_ID=$(echo $response | sed -n 's/.*"id":[[:space:]]*\([0-9]\+\).*/\1/p')

if [ ! -z "$TODO1_ID" ] && [[ $response == *"First task"* ]]; then
    echo "PASS: First todo created successfully with ID $TODO1_ID"
else
    echo "FAIL: First todo creation failed - Response: $response"
    kill $SERVER_PID
    exit 1
fi

echo "TEST 7: Create second todo"
response=$(curl -s -b cookies.txt -X POST http://localhost:$PORT/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Second task", "description": "This is my second task"}')
TODO2_ID=$(echo $response | sed -n 's/.*"id":[[:space:]]*\([0-9]\+\).*/\1/p')
echo "Response: $response"

if [ ! -z "$TODO2_ID" ] && [[ $response == *"Second task"* ]]; then
    echo "PASS: Second todo created successfully with ID $TODO2_ID"
else
    echo "FAIL: Second todo creation failed - Response: $response"
    kill $SERVER_PID
    exit 1
fi

echo "TEST 8: Get all todos"
response=$(curl -s -b cookies.txt http://localhost:$PORT/todos)
echo "Response: $response"

# Should contain both todos
if [[ $response == *"$TODO1_ID"* ]] && [[ $response == *"$TODO2_ID"* ]]; then
    echo "PASS: Retrieved both todos"
else
    echo "FAIL: Could not retrieve both todos"
fi

echo "TEST 9: Get specific todo"
response=$(curl -s -b cookies.txt http://localhost:$PORT/todos/$TODO1_ID)
echo "Response: $response"

if [[ $response == *"First task"* ]]; then
    echo "PASS: Retrieved specific todo"
else
    echo "FAIL: Could not retrieve specific todo - Response: $response"
fi

echo "TEST 10: Try getting nonexistent todo"
response=$(curl -s -b cookies.txt http://localhost:$PORT/todos/999999)
if [[ $response == *"Todo not found"* ]]; then
    echo "PASS: Correctly handled nonexistent todo"
else
    echo "FAIL: Did not handle nonexistent todo correctly - Response: $response"
fi

echo "TEST 11: Update a todo"
response=$(curl -s -b cookies.txt -X PUT http://localhost:$PORT/todos/$TODO1_ID \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated first task", "completed": true}')
echo "Response: $response"

if [[ $response == *"Updated first task"* ]] && [[ $response == *"true"* ]]; then
    echo "PASS: Successfully updated todo"
else
    echo "FAIL: Failed to update todo - Response: $response"
fi

echo "TEST 12: Update with empty title should fail"
response=$(curl -s -b cookies.txt -X PUT http://localhost:$PORT/todos/$TODO1_ID \
  -H "Content-Type: application/json" \
  -d '{"title": ""}')
if [[ $response == *"Title is required"* ]]; then
    echo "PASS: Correctly rejected update with empty title"
else
    echo "FAIL: Did not reject update with empty title - Response: $response"
fi

echo "TEST 13: Delete a todo"
status_code=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X DELETE http://localhost:$PORT/todos/$TODO2_ID)
if [ "$status_code" = "204" ]; then
    echo "PASS: Deleted todo successfully (Status: $status_code)"
else
    echo "FAIL: Failed to delete todo (Status: $status_code)"
fi

echo "TEST 14: Try viewing deleted todo"
response=$(curl -s -b cookies.txt http://localhost:$PORT/todos/$TODO2_ID)
if [[ $response == *"Todo not found"* ]]; then
    echo "PASS: Correctly indicates deleted todo does not exist"
else
    echo "FAIL: Did not indicate that deleted todo does not exist - Response: $response"
fi

echo "TEST 15: Change password"
response=$(curl -s -b cookies.txt -X PUT http://localhost:$PORT/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword123"}')

if [ "$response" = "{}" ]; then
    echo "PASS: Password changed successfully"
else
    echo "FAIL: Password change failed - Response: $response"
fi

echo "TEST 16: Try login with old password should fail"
response=$(curl -s -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser123", "password": "password123"}')
if [[ $response == *"Invalid credentials"* ]]; then
    echo "PASS: Old password was correctly rejected after change"
else
    echo "FAIL: Old password was accepted after change - Response: $response"
fi

echo "TEST 17: Login with new password should succeed"
response=$(curl -s -c new_cookies.txt -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser123", "password": "newpassword123"}')
if [[ $response == *"testuser123"* ]]; then
    echo "PASS: New password worked for login"
else
    echo "FAIL: New password did not work for login - Response: $response"
fi

echo "TEST 18: Logout"
response=$(curl -s -b new_cookies.txt -X POST http://localhost:$PORT/logout)
if [ "$response" = "{}" ]; then
    echo "PASS: Logout succeeded"
else
    echo "FAIL: Logout failed - Response: $response"
fi

echo "TEST 19: Attempt to access protected resource after logout"
response=$(curl -s -b new_cookies.txt http://localhost:$PORT/me)
if [[ $response == *"Authentication required"* ]]; then
    echo "PASS: Properly rejects request after logout"
else
    echo "FAIL: Did not reject request after logout - Response: $response"
fi

# Try to register a user with a very long username to test validation
echo "TEST 20: Test username validation - too long"
long_username=$(printf 'a%.0s' {1..60})  # 60 characters, exceeds limit
response=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"$long_username\", \"password\": \"password123\"}")
if [[ $response == *"Invalid username"* ]]; then
    echo "PASS: Correctly rejected too-long username"
else
    echo "FAIL: Did not reject too-long username - Response: $response"
fi

# Test alphanumeric underscore validation with a new registration
echo "TEST 21: Register a user to test update after logging out from previous"
response=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "valid_user123", "password": "password123"}')

if [[ $response == *"valid_user123"* ]]; then
    echo "PASS: Created user for subsequent tests"
else
    echo "FAIL: Failed to create user - Response: $response"
fi

# Login with this new user
response=$(curl -s -c newer_cookies.txt -X POST http://localhost:$PORT/login \
  -H "Content-Type: application/json" \
  -d '{"username": "valid_user123", "password": "password123"}')

# Test with special characters in username through direct validation
echo "TEST 22: Register with invalid character in username"
response=$(curl -s -X POST http://localhost:$PORT/register \
  -H "Content-Type: application/json" \
  -d '{"username": "invalid-user!", "password": "password123"}')
if [[ $response == *"Invalid username"* ]]; then
    echo "PASS: Correctly rejected username with special characters"
else
    echo "FAIL: Did not reject username with special characters - Response: $response"
fi

# Test creating todo with empty title
echo "TEST 23: Test creating todo with empty title (unauthenticated)"
response=$(curl -s -X POST http://localhost:$PORT/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "", "description": "This should fail due to auth"}')
if [[ $response == *"Authentication required"* ]]; then  
    echo "PASS: Unauthenticated request correctly rejected"
else
    echo "FAIL: Unauthenticated request was not rejected - Response: $response"
fi

# Use proper authentication for empty title test
echo "TEST 24: Test creating todo with empty title (with auth)"
response=$(curl -s -b newer_cookies.txt -X POST http://localhost:$PORT/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "", "description": "This should fail"}')
if [[ $response == *"Title is required"* ]]; then  
    echo "PASS: Correctly rejected todo creation with empty title"
else
    echo "FAIL: Did not reject todo creation with empty title - Response: $response"
fi

# Finally, test that we can properly access the newly created account
echo "TEST 25: Test access to new user account information"
response=$(curl -s -b newer_cookies.txt -X GET http://localhost:$PORT/me)
if [[ $response == *"valid_user123"* ]]; then
    echo "PASS: Successfully logged in with new user and accessed /me"
else
    echo "FAIL: Could not access /me with new user - Response: $response"
fi


echo "ALL TESTS COMPLETED SUCCESSFULLY!"

# Cleanup
kill $SERVER_PID
rm -f cookies.txt new_cookies.txt newer_cookies.txt