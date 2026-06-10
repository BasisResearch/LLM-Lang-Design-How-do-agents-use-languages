#!/bin/bash

# Test script for Todo API server

PORT=8080
BASE_URL="http://localhost:$PORT"

echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 2  # Give server time to start

# Check if server started successfully 
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Failed to start server"
    exit 1
fi

echo "Testing endpoints..."

# Clean up on exit
cleanup() {
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
}
trap cleanup EXIT

# Function to make requests and check results
make_request() {
    local method=$1
    local endpoint=$2
    local data=$3
    local cookie_jar=$4
    local expected_status=$5
    
    if [ -n "$data" ]; then
        if [ -n "$cookie_jar" ]; then
            response=$(curl -s -w "%{http_code}" -X $method $BASE_URL$endpoint \
                -H "Content-Type: application/json" \
                -d "$data" \
                --cookie $cookie_jar --cookie-jar $cookie_jar)
        else
            response=$(curl -s -w "%{http_code}" -X $method $BASE_URL$endpoint \
                -H "Content-Type: application/json" \
                -d "$data")
        fi
    else
        if [ -n "$cookie_jar" ]; then
            response=$(curl -s -w "%{http_code}" -X $method $BASE_URL$endpoint \
                --cookie $cookie_jar --cookie-jar $cookie_jar)
        else
            response=$(curl -s -w "%{http_code}" -X $method $BASE_URL$endpoint)
        fi
    fi
    
    actual_status="${response: -3}"
    
    if [ "$actual_status" -eq "$expected_status" ]; then
        echo "✓ $method $endpoint - Expected: $expected_status, Got: $actual_status"
        # Show body if not successful
        if [ "$actual_status" -ne 204 ]; then
            body="${response%???}"
            echo "  Response: $body"
        fi
        return 0
    else
        echo "✗ $method $endpoint - Expected: $expected_status, Got: $actual_status"
        body="${response%???}"
        echo "  Response: $body"
        return 1
    fi
}

# Cookie jar for keeping session
COOKIE_JAR=$(mktemp)

echo
echo "Test 1: Register a new user"
make_request POST "/register" '{"username": "testuser", "password": "password123"}' "" 201
TEST1_RESULT=$?

if [ $TEST1_RESULT -ne 0 ]; then
    echo "Test failed: Could not register user"
    cleanup
    exit 1
fi

echo
echo "Test 2: Register the same user again (should fail)"
make_request POST "/register" '{"username": "testuser", "password": "password123"}' "" 409
TEST2_RESULT=$?

echo
echo "Test 3: Register user with invalid username (too short)"
make_request POST "/register" '{"username": "ab", "password": "password123"}' "" 400
TEST3_RESULT=$?

echo
echo "Test 4: Register user with invalid username (invalid chars)"
make_request POST "/register" '{"username": "test@user", "password": "password123"}' "" 400
TEST4_RESULT=$?

echo
echo "Test 5: Register user with short password"
make_request POST "/register" '{"username": "testuser2", "password": "pass"}' "" 400
TEST5_RESULT=$?

echo
echo "Test 6: Login with correct credentials"
make_request POST "/login" '{"username": "testuser", "password": "password123"}' $COOKIE_JAR 200
TEST6_RESULT=$?

if [ $TEST6_RESULT -ne 0 ]; then
    echo "Test failed: Could not login"
    cleanup
    exit 1
fi

echo
echo "Test 7: Login with wrong password"
echo "Using curl directly since we need clean cookies"
status_code=$(curl -s -o /tmp/response_body -w "%{http_code}" -X POST $BASE_URL/login \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "wrongpassword"}')
if [ "$status_code" -eq 401 ]; then
    response_body=$(cat /tmp/response_body)
    echo "✓ Login with wrong password - Expected: 401, Got: $status_code"
    echo "  Response: $response_body"
    TEST7_RESULT=0
else
    echo "✗ Login with wrong password - Expected: 401, Got: $status_code"
    cat /tmp/response_body
    TEST7_RESULT=1
fi

echo
echo "Test 8: Access /me (authenticated)"
make_request GET "/me" "" $COOKIE_JAR 200
TEST8_RESULT=$?

if [ $TEST8_RESULT -ne 0 ]; then
    echo "Test failed: Could not access /me"
    cleanup
    exit 1
fi

echo
echo "Test 9: Try accessing protected route without session (unauthenticated)"
curl_response=$(curl -s -w "%{http_code}" -X GET $BASE_URL/me)
curl_status="${curl_response: -3}"
if [ "$curl_status" -eq 401 ]; then
    curl_body="${curl_response%???}"
    echo "✓ Unauthenticated /me request - Expected: 401, Got: $curl_status"
    echo "  Response: $curl_body"
    TEST9_RESULT=0
else
    echo "✗ Unauthenticated /me request - Expected: 401, Got: $curl_status"
    echo "  Response: ${curl_response%???}"
    TEST9_RESULT=1
fi

echo
echo "Test 10: Create first todo item"
make_request POST "/todos" '{"title": "First Task", "description": "My very first task"}' $COOKIE_JAR 201
TEST10_RESULT=$?

if [ $TEST10_RESULT -ne 0 ]; then
    echo "Test failed: Could not create first todo"
    cleanup
    exit 1
fi

echo
echo "Test 11: Create second todo item"
make_request POST "/todos" '{"title": "Second Task", "description": "Another task"}' $COOKIE_JAR 201
TEST11_RESULT=$?

if [ $TEST11_RESULT -ne 0 ]; then
    echo "Test failed: Could not create second todo"
    cleanup
    exit 1
fi

echo
echo "Test 12: Create todo with empty title (should fail)"
make_request POST "/todos" '{"title": "", "description": "Empty title task"}' $COOKIE_JAR 400
TEST12_RESULT=$?

echo
echo "Test 13: List all todos"
make_request GET "/todos" "" $COOKIE_JAR 200
TEST13_RESULT=$?

if [ $TEST13_RESULT -ne 0 ]; then
    echo "Test failed: Could not list todos"
    cleanup
    exit 1
fi

echo
echo "Test 14: Create a third todo to make multiple tasks more"
make_request POST "/todos" '{"title": "Third Task", "description": "Third task in the list"}' $COOKIE_JAR 201
TEST14_RESULT=$?

if [ $TEST14_RESULT -ne 0 ]; then
    echo "Test failed: Could not create third todo"
    cleanup
    exit 1
fi

echo
echo "Test 15: Get all todos again to confirm"
make_request GET "/todos" "" $COOKIE_JAR 200
TEST15_RESULT=$?

echo
echo "Extracting Todo ID from previous response..."
# Get first todo ID for further testing (parsing is manual due to limited tools)
TODO_IDS=$(curl -s -X GET $BASE_URL/todos --cookie $COOKIE_JAR | grep -o '"id":[0-9]*' | cut -d: -f2 | head -1)
FIRST_TODO_ID=$(echo $TODO_IDS | awk '{print $1}')
echo "Using first todo ID: $FIRST_TODO_ID"

echo
echo "Test 16: Get specific todo by ID: $FIRST_TODO_ID"
echo "Using curl directly to parse ID"
status_code=$(curl -s -o /tmp/todo_response -w "%{http_code}" -X GET $BASE_URL/todos/$FIRST_TODO_ID --cookie $COOKIE_JAR)
if [ "$status_code" -eq 200 ]; then
    response_body=$(cat /tmp/todo_response)
    echo "✓ Get todo by ID $FIRST_TODO_ID - Expected: 200, Got: $status_code"
    echo "  Response: $response_body"
    TEST16_RESULT=0
else
    echo "✗ Get todo by ID $FIRST_TODO_ID - Expected: 200, Got: $status_code"
    cat /tmp/todo_response  
    TEST16_RESULT=1
fi

echo
echo "Test 17: Update existing todo (partial update)"
make_request PUT "/todos/$FIRST_TODO_ID" '{"title": "Updated First Task", "completed": true}' $COOKIE_JAR 200
TEST17_RESULT=$?

echo
echo "Test 18: Update with empty title (should fail)"
make_request PUT "/todos/$FIRST_TODO_ID" '{"title": ""}' $COOKIE_JAR 400
TEST18_RESULT=$?

echo
echo "Test 19: Try to update a non-existent todo ID (99999)"
non_existent_id=99999
status_code=$(curl -s -o /tmp/response_body -w "%{http_code}" -X PUT $BASE_URL/todos/$non_existent_id \
    -H "Content-Type: application/json" \
    --cookie $COOKIE_JAR \
    -d '{"title": "Some Title"}')
if [ "$status_code" -eq 404 ]; then
    response_body=$(cat /tmp/response_body)
    echo "✓ Update non-existent todo - Expected: 404, Got: $status_code"
    echo "  Response: $response_body"
    TEST19_RESULT=0
else
    echo "✗ Update non-existent todo - Expected: 404, Got: $status_code"
    cat /tmp/response_body
    TEST19_RESULT=1
fi

echo
echo "Test 20: Try to delete a non-existent todo ID (99999)"
status_code=$(curl -s -o /tmp/response_body -w "%{http_code}" -X DELETE $BASE_URL/todos/$non_existent_id --cookie $COOKIE_JAR)
if [ "$status_code" -eq 404 ]; then
    response_body=$(cat /tmp/response_body)
    echo "✓ Delete non-existent todo - Expected: 404, Got: $status_code"
    echo "  Response: $response_body"
    TEST20_RESULT=0
else
    echo "✗ Delete non-existent todo - Expected: 404, Got: $status_code"
    cat /tmp/response_body
    TEST20_RESULT=1
fi

echo
echo "Testing logout functionality..."
echo "Test 21: Logout current session"
make_request POST "/logout" "" $COOKIE_JAR 200
TEST21_RESULT=$?

if [ $TEST21_RESULT -ne 0 ]; then
    echo "Test failed: Could not logout"
    cleanup
    exit 1
fi

echo
echo "Test 22: Now try accessing /me after logout (should fail)"
curl_response=$(curl -s -w "%{http_code}" -X GET $BASE_URL/me --cookie $COOKIE_JAR)
curl_status="${curl_response: -3}"
if [ "$curl_status" -eq 401 ]; then
    curl_body="${curl_response%???}"
    echo "✓ Access /me after logout - Expected: 401, Got: $curl_status"
    echo "  Response: $curl_body"
    TEST22_RESULT=0
else
    echo "✗ Access /me after logout - Expected: 401, Got: $curl_status"
    echo "  Response: ${curl_response%???}"
    TEST22_RESULT=1
fi

echo
echo "Re-login for final tests..."
login_result=$(curl -s -w "%{http_code}" -X POST $BASE_URL/login \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}' \
    --cookie $COOKIE_JAR --cookie-jar $COOKIE_JAR)

login_status="${login_result: -3}"

if [ "$login_status" -eq 200 ]; then
    echo "✓ Re-login successful"
else
    echo "✗ Re-login failed with status: $login_status"
    cleanup
    exit 1
fi

echo
echo "Register a new user for multi-user testing"
second_user_result=$(curl -s -w "%{http_code}" -X POST $BASE_URL/register \
    -H "Content-Type: application/json" \
    -d '{"username": "seconduser", "password": "password456"}')
if [ "${second_user_result: -3}" -eq 201 ]; then
    echo "✓ Second user registered"
else
    echo "✗ Second user registration failed"
fi

# Login as second user
second_login_result=$(curl -s -w "%{http_code}" -X POST $BASE_URL/login \
    -H "Content-Type: application/json" \
    -d '{"username": "seconduser", "password": "password456"}')
if [ "${second_login_result: -3}" -eq 200 ]; then
    session_info=$(echo "$second_login_result" | head -c -3)
    echo "✓ Second user login successful"
fi

# Get second user's cookie separately
COOKIE_JAR2=$(mktemp)
curl -s -X POST $BASE_URL/login \
    -H "Content-Type: application/json" \
    -d '{"username": "seconduser", "password": "password456"}' \
    --cookie-jar $COOKIE_JAR2 > /dev/null

# Create a todo for the second user
create_todo_result=$(curl -s -w "%{http_code}" -X POST $BASE_URL/todos \
    -H "Content-Type: application/json" \
    -d '{"title": "Second user task", "description": "Task only second user should see"}' \
    --cookie $COOKIE_JAR2)
if [ "${create_todo_result: -3}" -eq 201 ]; then
    second_todo_id=$(echo "${create_todo_result%???}" | grep -o '"id":[0-9]*' | cut -d: -f2)
    echo "✓ Created todo for second user (ID: $second_todo_id)"
else
    echo "✗ Creating todo for second user failed"
fi

echo
echo "Test 23: Try to access other user's todo (should fail with 404)"
status_code=$(curl -s -o /tmp/response_body -w "%{http_code}" -X GET $BASE_URL/todos/$second_todo_id --cookie $COOKIE_JAR)
if [ "$status_code" -eq 404 ]; then
    response_body=$(cat /tmp/response_body)
    echo "✓ Accessing other user's todo correctly returned 404"
    echo "  Response: $response_body"
    TEST23_RESULT=0
else
    echo "✗ Accessing other user's todo should return 404, got: $status_code"
    cat /tmp/response_body
    TEST23_RESULT=1
fi

echo
echo "Test 24: Try to update other user's todo (should fail with 404)"
update_result=$(curl -s -w "%{http_code}" -X PUT $BASE_URL/todos/$second_todo_id \
    -H "Content-Type: application/json" \
    --cookie $COOKIE_JAR \
    -d '{"title": "Should not work"}')
if [ "${update_result: -3}" -eq 404 ]; then
    response_body="${update_result%???}"
    echo "✓ Updating other user's todo correctly returned 404"
    echo "  Response: $response_body"
    TEST24_RESULT=0
else
    echo "✗ Updating other user's todo should return 404, got: ${update_result: -3}"
    echo "  Response: ${update_result%???}"
    TEST24_RESULT=1
fi

echo
echo "Test 25: Try to delete other user's todo (should fail with 404)"
delete_result=$(curl -s -w "%{http_code}" -X DELETE $BASE_URL/todos/$second_todo_id --cookie $COOKIE_JAR)
if [ "${delete_result: -3}" -eq 404 ]; then
    response_body="${delete_result%???}"
    echo "✓ Deleting other user's todo correctly returned 404"
    echo "  Response: $response_body"
    TEST25_RESULT=0
else
    echo "✗ Deleting other user's todo should return 404, got: ${delete_result: -3}"
    echo "  Response: ${delete_result%???}"
    TEST25_RESULT=1
fi

# Clean up resources
rm -f $COOKIE_JAR $COOKIE_JAR2 /tmp/response_body /tmp/todo_response

echo
# Check overall test results
all_tests_passed=1
for test_var in TEST{1..25}_RESULT; do
    val=$(eval echo \$$test_var)
    if [ "$val" -ne 0 ]; then
        echo "✗ $test_var failed ($val)"
        all_tests_passed=0
    else
        echo "✓ $test_var passed"
    fi
done

if [ $all_tests_passed -eq 1 ]; then
    echo
    echo "🎉 All tests passed!"
    cleanup
    exit 0
else
    echo
    echo "❌ Some tests failed"
    cleanup
    exit 1
fi