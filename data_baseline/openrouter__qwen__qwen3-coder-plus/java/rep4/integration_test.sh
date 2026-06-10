#!/bin/bash

# Start server on a different port to avoid conflicts
PORT=8085

echo "Starting server on port $PORT..."
java -cp bin com.todoserver.Main --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 3

# Check if server started successfully
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "❌ Failed to start server"
    exit 1
else
    echo "✅ Server started successfully with PID $SERVER_PID"
fi

TESTS_PASSED=0
TESTS_TOTAL=0

# Function to run a test
run_test() {
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    local test_name=$1
    local cmd=$2
    local expected_status=$3
    local expected_content=$4
    
    # Execute the test command
    response=$(eval "$cmd")
    status=$(echo "$response" | tail -n 1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status" = "$expected_status" ] && [[ "$body" == *"$expected_content"* ]]; then
        echo "✅ PASS: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "❌ FAIL: $test_name"
        echo "   Expected: $expected_content (status $expected_status)"
        echo "   Got: $body (status $status)"
    fi
}

echo -e "\n--- Running Tests ---"

# Create a temporary file for cookies
COOKIE_JAR=$(mktemp)

# Test 1: POST /register - Valid registration
run_test "POST /register (valid)" \
    'curl -s -c '"$COOKIE_JAR"' -w "\n%{http_code}" -X POST http://localhost:'"$PORT"'/register \
    -H "Content-Type: application/json" \
    -d '{"'"'"'username'"'"'": "'"'"'testuser'"'"'", "'"'"'password'"'"'": "'"'"'password123'"'"'"}' \
    "201" "testuser"

# Test 2: POST /register - Duplicate username
run_test "POST /register (duplicate username)" \
    'curl -s -w "\n%{http_code}" -X POST http://localhost:'"$PORT"'/register \
    -H "Content-Type: application/json" \
    -d '{"'"'"'username'"'"'": "'"'"'testuser'"'"'", "'"'"'password'"'"'": "'"'"'password123'"'"'"}' \
    "409" "Username already exists"

# Test 3: POST /login - Valid login
run_test "POST /login (valid)" \
    'curl -s -c '"$COOKIE_JAR"' -w "\n%{http_code}" -X POST http://localhost:'"$PORT"'/login \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"testuser\", \"password\": \"password123\"}"' \
    "200" "testuser"

# Test 4: GET /me - Authenticated user info
run_test "GET /me (authenticated)" \
    'curl -b '"$COOKIE_JAR"' -s -w "\n%{http_code}" http://localhost:'"$PORT"'/me' \
    "200" "testuser"

# Test 5: POST /todos - Create todo
run_test "POST /todos (create todo)" \
    'curl -b '"$COOKIE_JAR"' -s -w "\n%{http_code}" -X POST http://localhost:'"$PORT"'/todos \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"Test todo\", \"description\": \"A test todo item\"}"' \
    "201" "Test todo"

# Test 6: GET /todos - List todos
run_test "GET /todos (list todos)" \
    'curl -b '"$COOKIE_JAR"' -s -w "\n%{http_code}" http://localhost:'"$PORT"'/todos' \
    "200" "Test todo"

# Test 7: GET /todos/:id - Get specific todo 
ID_RESPONSE=$(curl -b "$COOKIE_JAR" -s http://localhost:$PORT/todos)
TODO_ID=$(echo "$ID_RESPONSE" | grep -o '"id":[0-9]*' | head -n1 | cut -d: -f2)
if [ -n "$TODO_ID" ]; then
    run_test "GET /todos/:id (get specific todo)" \
        'curl -b '"$COOKIE_JAR"' -s -w "\n%{http_code}" http://localhost:'"$PORT"'/todos/'"$TODO_ID" \
        "200" "Test todo"
fi

# Test 8: PUT /todos/:id - Update todo
run_test "PUT /todos/:id (update todo)" \
    'curl -b '"$COOKIE_JAR"' -s -w "\n%{http_code}" -X PUT http://localhost:'"$PORT"'/todos/'"$TODO_ID"' \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"Updated todo\", \"completed\": true}"' \
    "200" "Updated todo"

# Test 9: PUT /password - Change password
run_test "PUT /password (change password)" \
    'curl -b '"$COOKIE_JAR"' -s -w "\n%{http_code}" -X PUT http://localhost:'"$PORT"'/password \
    -H "Content-Type: application/json" \
    -d "{\"old_password\": \"password123\", \"new_password\": \"newpassword456\"}"' \
    "200" "{}"

# Test 10: POST /logout - Logout
run_test "POST /logout (logout)" \
    'curl -b '"$COOKIE_JAR"' -s -w "\n%{http_code}" -X POST http://localhost:'"$PORT"'/logout' \
    "200" "{}"

# Test 11: GET /me (with invalid session) - Should fail
run_test "GET /me (without valid session)" \
    'curl -b '"$COOKIE_JAR"' -s -w "\n%{http_code}" http://localhost:'"$PORT"'/me' \
    "401" "Authentication required"

# Test 12: POST /login - Wrong credentials
run_test "POST /login (wrong credentials)" \
    'curl -s -w "\n%{http_code}" -X POST http://localhost:'"$PORT"'/login \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"testuser\", \"password\": \"wrongpassword\"}"' \
    "401" "Invalid credentials"

# Cleanup
kill $SERVER_PID 2>/dev/null
rm -f $COOKIE_JAR

# Output results
echo -e "\n--- Results ---"
echo "Tests passed: $TESTS_PASSED/$TESTS_TOTAL"
if [ $TESTS_PASSED -eq $TESTS_TOTAL ]; then
    echo "🎉 All tests passed!"
    exit 0
else
    echo "⚠️  Some tests failed"
    exit 1
fi