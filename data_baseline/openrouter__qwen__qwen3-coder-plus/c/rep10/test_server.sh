#!/bin/bash

# Start test server on port 8080 in background
./run.sh --port 8080 &
SERVER_PID=$!

echo "Started server with PID: $SERVER_PID"

# Wait for server to start
sleep 2

# Initialize cookies file
COOKIE_JAR="test_cookies.txt"
touch $COOKIE_JAR

# Test successful registration
echo "Test 1: Register user johndoe..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "johndoe", "password": "securepassword"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 201 ] && [[ "$body" == *"johndoe"* ]]; then
    echo "PASS: User registered successfully"
else
    echo "FAIL: Registration failed"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test successful second registration (different user)
echo "Test 2: Register user janedoe..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "janedoe", "password": "anotherpassword"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 201 ] && [[ "$body" == *"janedoe"* ]]; then
    echo "PASS: Second user registered successfully"
else
    echo "FAIL: Second registration failed"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test username validation - too short
echo "Test 3: Register with invalid username (too short)..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "jo", "password": "password"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 400 ] && [[ "$body" == *"Invalid username"* ]]; then
    echo "PASS: Short username rejected properly"
else
    echo "FAIL: Short username not rejected"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test username validation - contains invalid chars
echo "Test 4: Register with invalid username (contains invalid characters)..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "john@doe", "password": "password"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 400 ] && [[ "$body" == *"Invalid username"* ]]; then
    echo "PASS: Invalid character username rejected properly"
else
    echo "FAIL: Invalid character username not rejected"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test username validation - too long
echo "Test 5: Register with invalid username (too long)..."
long_username=$(printf 'a%.0s' {1..60})  # 60 chars
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d "{\"username\": \"$long_username\", \"password\": \"password\"}")
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 400 ] && [[ "$body" == *"Invalid username"* ]]; then
    echo "PASS: Long username rejected properly"
else
    echo "FAIL: Long username not rejected"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test weak password
echo "Test 6: Register with weak password (too short)..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "gooduser", "password": "badpass"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 400 ] && [[ "$body" == *"Password too short"* ]]; then
    echo "PASS: Weak password rejected properly"
else
    echo "FAIL: Weak password not rejected"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test duplicate username
echo "Test 7: Register duplicate username..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "johndoe", "password": "otherpassword"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 409 ] && [[ "$body" == *"Username already exists"* ]]; then
    echo "PASS: Duplicate username rejected properly"
else
    echo "FAIL: Duplicate username not rejected"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test successful login
echo "Test 8: Login user johndoe..."
response=$(curl -s -c $COOKIE_JAR -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "johndoe", "password": "securepassword"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 200 ] && [[ "$body" == *"johndoe"* ]]; then
    echo "PASS: Login successful"
else
    echo "FAIL: Login failed"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test wrong password
echo "Test 9: Login with wrong password..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "johndoe", "password": "wrongpassword"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 401 ] && [[ "$body" == *"Invalid credentials"* ]]; then
    echo "PASS: Wrong password rejected"
else
    echo "FAIL: Wrong password not rejected"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test invalid username login
echo "Test 10: Login with non-existent username..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "nonexistent", "password": "any"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 401 ] && [[ "$body" == *"Invalid credentials"* ]]; then
    echo "PASS: Non-existent user rejected"
else
    echo "FAIL: Non-existent user allowed"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test get user's info (requires authentication)
echo "Test 11: Get user info with authentication..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X GET http://localhost:8080/me)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 200 ] && [[ "$body" == *"johndoe"* ]]; then
    echo "PASS: Get user info successful"
else
    echo "FAIL: Get user info failed - expected authentication to work"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test get user's info without auth
echo "Test 12: Get user info without authentication..."
response=$(curl -s -w "\n%{http_code}" -X GET http://localhost:8080/me)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 401 ] && [[ "$body" == *"Authentication required"* ]]; then
    echo "PASS: Access without auth denied"
else
    echo "FAIL: Access without auth not denied"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test changing password
echo "Test 13: Change password..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "securepassword", "new_password": "newsecurepassword"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 200 ] && [[ "$body" == "{}" ]]; then
    echo "PASS: Password change successful"
else
    echo "FAIL: Password change failed"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test password change with wrong old password
echo "Test 14: Change password with wrong old password..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "wrongpassword", "new_password": "anothernewpass"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 401 ] && [[ "$body" == *"Invalid credentials"* ]]; then
    echo "PASS: Changing password with wrong old password failed correctly"
else
    echo "FAIL: Changed password with wrong old password"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test new password works (try logging in again to verify password was changed)
echo "Test 15: Login with new password after change..."
response=$(curl -s -c $COOKIE_JAR -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "johndoe", "password": "newsecurepassword"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 200 ] && [[ "$body" == *"johndoe"* ]]; then
    echo "PASS: New password works"
else
    echo "FAIL: New password doesn't work"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test creating a todo
echo "Test 16: Create a new todo item..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Buy groceries", "description": "Milk, eggs, bread"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 201 ] && [[ "$body" == *"Buy groceries"* ]]; then
    echo "PASS: Created todo successfully"
else
    echo "FAIL: Failed to create todo"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test creating a todo without authentication
echo "Test 17: Create todo without authentication (should fail)..."
response=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Another task", "description": "With no auth"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 401 ] && [[ "$body" == *"Authentication required"* ]]; then
    echo "PASS: Create todo without auth denied"
else
    echo "FAIL: Create todo without auth not denied"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test creating a todo with empty title
echo "Test 18: Create todo with empty title..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "", "description": "This should fail"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 400 ] && [[ "$body" == *"Title is required"* ]]; then
    echo "PASS: Creating todo with empty title properly denied"
else
    echo "FAIL: Creating todo with empty title not denied"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test getting todos (should be 1 todo so far)
echo "Test 19: Get all todos for user..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X GET http://localhost:8080/todos)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 200 ] && [[ "$body" == *"[{"* ]] && [[ "$body" == *"Buy groceries"* ]]; then
    echo "PASS: Retrieved todos successfully"
else
    echo "FAIL: Failed to retrieve todos"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test getting a specific todo
echo "Test 20: Get specific todo by ID..."
# First let's find out the ID of the last created todo
todo_id=$(echo "$body" | grep -o '"id":[0-9]*' | sed 's/"id"://' | tail -n1)
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X GET http://localhost:8080/todos/$todo_id)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 200 ] && [[ "$body" == *"Buy groceries"* ]]; then
    echo "PASS: Retrieved specific todo successfully"
else
    echo "FAIL: Failed to retrieve specific todo"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Create another todo before testing cross-user filtering
echo "Switching to Jane's account to test cross-user access restriction..."

# Login as jane
response=$(curl -s -c $COOKIE_JAR -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "janedoe", "password": "anotherpassword"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Jane login response: Status $status, Body $body"

# Create a todo for Jane
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Write report", "description": "Quarterly financial report"}')
status=$(echo "$response" | tail -n 1)
jane_body=$(echo "$response" | head -n -1)
jane_todo_id=$(echo "$jane_body" | grep -o '"id":[0-9]*' | sed 's/"id"://')

echo "Jane created todo with ID: $jane_todo_id"

# Switch back to john's account by logging in again
response=$(curl -s -c $COOKIE_JAR -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "johndoe", "password": "newsecurepassword"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "John re-login: Status $status, Body $body"

echo "Test 21: Try accessing another user's todo (should not be possible)..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X GET http://localhost:8080/todos/$jane_todo_id)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 404 ] && [[ "$body" == *"Todo not found"* ]]; then
    echo "PASS: Cross-user todo access denied (returned 404, not 403)"
else
    echo "FAIL: Cross-user todo access should be denied (expected 404)"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test updating a todo
echo "Test 22: Update an existing todo..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X PUT http://localhost:8080/todos/$todo_id \
  -H "Content-Type: application/json" \
  -d '{"title": "Buy groceries and cook dinner", "completed": true}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 200 ] && [[ "$body" == *"Buy groceries and cook dinner"* ]] && [[ "$body" == *"true"* ]]; then
    echo "PASS: Todo updated successfully"
else
    echo "FAIL: Todo update failed"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test partial update of todo
echo "Test 23: Partial update of a todo (only change description)..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X PUT http://localhost:8080/todos/$todo_id \
  -H "Content-Type: application/json" \
  -d '{"description": "Updated description"}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 200 ] && [[ "$body" == *"Updated description"* ]]; then
    echo "PASS: Todo partially updated successfully"
else
    echo "FAIL: Todo partial update failed"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Check that the updated todo has the correct values
echo "Test 24: Verify the updated todo has correct values..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X GET http://localhost:8080/todos/$todo_id)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status"
if [[ "$body" == *"Buy groceries and cook dinner"* ]] && [[ "$body" == *"Updated description"* ]] && [[ "$body" == *"true"* ]]; then
    echo "PASS: Todo has correct updated values"
else
    echo "FAIL: Todo doesn't have expected updated values"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test trying to update another user's todo (should fail)
echo "Test 25: Try updating another user's todo (should be denied)..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X PUT http://localhost:8080/todos/$jane_todo_id \
  -H "Content-Type: application/json" \
  -d '{"title": "Hacked by john", "completed": true}')
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 404 ] && [[ "$body" == *"Todo not found"* ]]; then
    echo "PASS: Updating another user's todo correctly denied"
else
    echo "FAIL: Updating another user's todo not denied"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi


# Test deleting a todo
echo "Test 26: Delete a todo item..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X DELETE http://localhost:8080/todos/$todo_id)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status"
if [ "$status" -eq 204 ]; then
    echo "PASS: Todo deleted successfully (204 No Content)"
else
    echo "FAIL: Todo deletion failed, expected 204, got $status"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Verify the todo is gone
echo "Test 27: Verify deleted todo is not accessible..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X GET http://localhost:8080/todos/$todo_id)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
if [ "$status" -eq 404 ] && [[ "$body" == *"Todo not found"* ]]; then
    echo "PASS: Deleted todo is inaccessible"
else
    echo "FAIL: Deleted todo is still accessible"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test trying to delete another user's todo (should fail)
echo "Test 28: Try deleting another user's todo (should be denied)..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X DELETE http://localhost:8080/todos/$jane_todo_id)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 404 ] && [[ "$body" == *"Todo not found"* ]]; then
    echo "PASS: Deleting another user's todo correctly denied"
else
    echo "FAIL: Deleting another user's todo not denied"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Test logout
echo "Test 29: Logout user..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X POST http://localhost:8080/logout)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
echo "Status: $status, Response: $body"
if [ "$status" -eq 200 ] && [[ "$body" == "{}" ]]; then
    echo "PASS: Logout successful"
else
    echo "FAIL: Logout failed"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

# Verify logout actually ended the session
echo "Test 30: Try accessing protected resource after logout..."
response=$(curl -s -b $COOKIE_JAR -w "\n%{http_code}" -X GET http://localhost:8080/me)
status=$(echo "$response" | tail -n 1)
body=$(echo "$response" | head -n -1)
if [ "$status" -eq 401 ] && [[ "$body" == *"Authentication required"* ]]; then
    echo "PASS: Authentication required after logout"
else
    echo "FAIL: Still authenticated after logout"
    kill $SERVER_PID
    rm -f server test_cookies.txt
    exit 1
fi

echo ""
echo "All tests passed successfully!"
rm -f test_cookies.txt

# Kill the server process
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null