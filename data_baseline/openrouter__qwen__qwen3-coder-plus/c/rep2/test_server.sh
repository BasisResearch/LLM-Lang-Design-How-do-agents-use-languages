#!/bin/bash

# Test script for Todo App Server
SERVER_URL="http://localhost:8080"
CREDENTIAL_FILE="/tmp/todo_test_cookies.txt"
LOG_FILE="/tmp/todo_test.log"

echo "Starting Todo API tests..."

# Clean log file
> $LOG_FILE

# Start the server in background
./server --port 8080 &
SERVER_PID=$!
sleep 2

# Check if server started successfully
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "ERROR: Failed to start server"
    exit 1
fi

echo "Server is running with PID $SERVER_PID"

# Function to make requests using curl
make_request() {
    local method=$1
    local endpoint=$2
    local data=$3
    local expected_status=${4:-200}
    
    if [ -z "$data" ]; then
        response=$(curl -s -w "%{http_code}" -X "$method" \
            -H "Content-Type: application/json" \
            --cookie $CREDENTIAL_FILE --cookie-jar $CREDENTIAL_FILE \
            "$SERVER_URL$endpoint")
    else
        response=$(curl -s -w "%{http_code}" -X "$method" \
            -H "Content-Type: application/json" \
            -d "$data" \
            --cookie $CREDENTIAL_FILE --cookie-jar $CREDENTIAL_FILE \
            "$SERVER_URL$endpoint")
    fi
    
    http_code="${response: -3}"
    body="${response%???}"
    
    if [ "$http_code" != "$expected_status" ]; then
        echo "ERROR: $method $endpoint failed - Expected: $expected_status, Got: $http_code"
        echo "Response: $body"
        return 1
    fi
    
    echo "$body"
    return 0
}

# Clean cookies file
> $CREDENTIAL_FILE

echo "Running test 1: Register new user..."
result=$(make_request "POST" "/register" '{"username": "testuser", "password": "password123"}' 201)
status=$?
if [ $status -ne 0 ]; then
    echo "Register test failed"
    kill $SERVER_PID
    exit 1
else
    echo "Register successful: $result"
fi

echo "Running test 2: Verify user registration values..."
if [[ $result != *"username"* ]] || [[ $result != *"id"* ]]; then
    echo "Registration response doesn't contain expected fields"
    kill $SERVER_PID
    exit 1
fi

echo "Running test 3: Register with invalid username (< 3 chars)..."
result2=$(make_request "POST" "/register" '{"username": "ab", "password": "password123"}' 400)
status2=$?
if [ $status2 -eq 0 ]; then
    echo "Expected validation failure didn't happen"
    kill $SERVER_PID
    exit 1
else
    echo "Proper validation occurred for short username"
fi

echo "Running test 4: Register with invalid username (> 50 chars)..."
long_username=$(printf 'A%.0s' {1..51})
result3=$(make_request "POST" "/register" "{\"username\": \"$long_username\", \"password\": \"password123\"}" 400)
status3=$?
if [ $status3 -eq 0 ]; then
    echo "Expected validation failure didn't happen"
    kill $SERVER_PID
    exit 1
else
    echo "Proper validation occurred for long username"
fi

echo "Running test 5: Register with invalid characters in username..."
result4=$(make_request "POST" "/register" '{"username": "user@name", "password": "password123"}' 400)
status4=$?
if [ $status4 -eq 0 ]; then
    echo "Expected validation failure didn't happen"
    kill $SERVER_PID
    exit 1
else
    echo "Proper validation occurred for invalid characters"
fi

echo "Running test 6: Register user with same username should fail..."
result5=$(make_request "POST" "/register" '{"username": "testuser", "password": "password123"}' 409)
status5=$?
if [ $status5 -eq 0 ]; then
    echo "Expected duplicate username detection failed"
    kill $SERVER_PID
    exit 1
else
    echo "Properly detected duplicate username"
fi

echo "Running test 7: Login with registered user..."
login_result=$(make_request "POST" "/login" '{"username": "testuser", "password": "password123"}' 200)
status7=$?
if [ $status7 -ne 0 ]; then
    echo "Login failed"
    kill $SERVER_PID
    exit 1
else
    echo "Login successful: $login_result"
fi

echo "Running test 8: Access protected endpoint /me after login..."
me_result=$(make_request "GET" "/me")
status8=$?
if [ $status8 -ne 0 ]; then
    echo "/me endpoint failed"
    kill $SERVER_PID
    exit 1
else
    echo "/me endpoint success: $me_result"
fi

if [[ $me_result != *"testuser"* ]]; then
    echo "User data not returned correctly from /me"
    kill $SERVER_PID
    exit 1
fi

echo "Running test 9: Try accessing protected endpoint without cookie (should fail)..."
temp_cookie="/tmp/temp_cookies.txt"
> $temp_cookie
unauth_result=$(curl -s -w "%{http_code}" -X GET \
    -H "Content-Type: application/json" \
    --cookie $temp_cookie --cookie-jar $temp_cookie \
    "$SERVER_URL/me")
unauth_code="${unauth_result: -3}"

if [ "$unauth_code" != "401" ]; then
    echo "Expected authentication failure didn't occur"
    kill $SERVER_PID
    exit 1
else
    echo "Authentication protection working: got 401 as expected"
fi

echo "Running test 10: Add a todo item..."
todo1_result=$(make_request "POST" "/todos" '{"title": "First Todo", "description": "My first important task"}' 201)
status10=$?
if [ $status10 -ne 0 ]; then
    echo "Failed to add first todo"
    kill $SERVER_PID
    exit 1
else
    echo "Added first todo: $todo1_result"
fi

if [[ $todo1_result != *"First Todo"* ]]; then
    echo "Todo title not returned correctly"
    kill $SERVER_PID
    exit 1
fi

echo "Running test 11: Add another todo without description..."
todo2_result=$(make_request "POST" "/todos" '{"title": "Second Todo"}' 201)
status11=$?
if [ $status11 -ne 0 ]; then
    echo "Failed to add second todo"
    kill $SERVER_PID
    exit 1
else
    echo "Added second todo: $todo2_result"
fi

echo "Running test 12: Get all todos..."
todos_list=$(make_request "GET" "/todos")
status12=$?
if [ $status12 -ne 0 ]; then
    echo "Failed to get todos"
    kill $SERVER_PID
    exit 1
else
    echo "Got todos list: $todos_list"
fi

if [[ $todos_list != *"[{"* ]] || [[ $todos_list != *"}]"* ]]; then
    echo "Todos list not formatted correctly as JSON array"
    kill $SERVER_PID
    exit 1
fi

# Extract first todo ID
first_todo_id=$(echo $todo1_result | grep -o '"id":[0-9]*' | cut -d':' -f2)

echo "Running test 13: Get a specific todo by ID ($first_todo_id)..."
specific_todo=$(make_request "GET" "/todos/$first_todo_id")
status13=$?
if [ $status13 -ne 0 ]; then
    echo "Failed to get specific todo"
    kill $SERVER_PID
    exit 1
else
    echo "Got specific todo: $specific_todo"
fi

echo "Running test 14: Update a todo partially..."
update_result=$(make_request "PUT" "/todos/$first_todo_id" '{"title": "Updated First Todo", "completed": true}')
status14=$?
if [ $status14 -ne 0 ]; then
    echo "Failed to update todo"
    kill $SERVER_PID
    exit 1
else
    echo "Updated todo: $update_result"
fi

if [[ $update_result != *"Updated First Todo"* ]] || [[ $update_result != *"true"* ]]; then
    echo "Todo didn't update correctly"
    kill $SERVER_PID
    exit 1
fi

echo "Running test 15: Test todo title validation on update (empty title)..."
bad_update=$(make_request "PUT" "/todos/$first_todo_id" '{"title": ""}' 400)
status15=$?
if [ $status15 -eq 0 ]; then
    echo "Update with empty title should have failed"
    kill $SERVER_PID
    exit 1
else
    echo "Successfully caught invalid title during update"
fi

echo "Running test 16: Delete a todo..."
delete_result=$(make_request "DELETE" "/todos/$first_todo_id" '' 204)
status16=$?
if [ $status16 -ne 0 ]; then
    echo "Failed to delete todo"
    kill $SERVER_PID
    exit 1
else
    echo "Deleted todo with 204 response (as expected)"
fi

echo "Running test 17: Try to get deleted todo (should fail)..."
deleted_todo_result=$(make_request "GET" "/todos/$first_todo_id" '' 404)
status17=$?
if [ $status17 -eq 0 ]; then
    echo "Access to deleted todo worked, shouldn't happen"
    kill $SERVER_PID
    exit 1
else
    echo "Got 404 for deleted todo, which is correct"
fi

echo "Running test 18: Change password..."
change_pw_result=$(make_request "PUT" "/password" '{"old_password": "password123", "new_password": "newpassword456"}')
status18=$?
if [ $status18 -ne 0 ]; then
    echo "Failed to change password"
    kill $SERVER_PID
    exit 1
else
    echo "Password changed successfully"
fi

echo "Running test 19: Logout..."
logout_result=$(make_request "POST" "/logout")
status19=$?
if [ $status19 -ne 0 ]; then
    echo "Logout failed"
    kill $SERVER_PID
    exit 1
else
    echo "Logged out successfully"
fi

echo "Running test 20: Try access /me after logout (should fail)..."
after_logout=$(make_request "GET" "/me" '' 401)
status20=$?
if [ $status20 -eq 0 ]; then
    echo "Should be logged out now but still working"
    kill $SERVER_PID
    exit 1
else
    echo "Successfully logged out (got 401 as expected)"
fi

echo ""
echo "All tests passed! Server is working correctly."
echo ""

kill $SERVER_PID

# Clean up cookie file
rm -f $CREDENTIAL_FILE $temp_cookie

exit 0