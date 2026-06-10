#!/bin/bash

PORT=8998
BASE_URL="http://localhost:$PORT"

# Start server in background
./server --port $PORT &
SERVER_PID=$!
sleep 1

# Helper function to check response
check_response() {
    local expected_status=$1
    local actual_status=$2
    local expected_body=$3
    local actual_body=$4
    local test_name=$5

    if [ "$expected_status" -eq "$actual_status" ]; then
        if [ -n "$expected_body" ]; then
            if echo "$actual_body" | grep -q "$expected_body"; then
                echo "PASS: $test_name"
            else
                echo "FAIL: $test_name - Body mismatch. Expected to contain: $expected_body, Got: $actual_body"
            fi
        else
            echo "PASS: $test_name"
        fi
    else
        echo "FAIL: $test_name - Status code mismatch. Expected: $expected_status, Got: $actual_status"
    fi
}

echo "Starting tests on port $PORT..."

# Test 1: Register a new user
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' "$BASE_URL/register")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 201 "$STATUS" "testuser" "$BODY" "Register new user"

# Test 2: Register with invalid username (too short)
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username": "tu", "password": "password123"}' "$BASE_URL/register")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 "$STATUS" "Invalid username" "$BODY" "Register with invalid username (too short)"

# Test 3: Register with invalid password (too short)
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}' "$BASE_URL/register")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 "$STATUS" "Password too short" "$BODY" "Register with invalid password (too short)"

# Test 4: Register with existing username
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' "$BASE_URL/register")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 409 "$STATUS" "Username already exists" "$BODY" "Register with existing username"

# Test 5: Login
RESP=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' "$BASE_URL/login")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 "$STATUS" "testuser" "$BODY" "Login"

# Test 6: Login with invalid credentials
RESP=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}' "$BASE_URL/login")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 "$STATUS" "Invalid credentials" "$BODY" "Login with invalid credentials"

# Test 7: Get /me
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 "$STATUS" "testuser" "$BODY" "Get /me"

# Test 8: Get /me without auth
RESP=$(curl -s -w "\n%{http_code}" "$BASE_URL/me")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 "$STATUS" "Authentication required" "$BODY" "Get /me without auth"

# Test 9: Create a todo
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Some description"}' "$BASE_URL/todos")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 201 "$STATUS" "My Todo" "$BODY" "Create a todo"
TODO_ID=$(echo "$BODY" | jq -r '.id')

# Test 10: Create a todo without title
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST -H "Content-Type: application/json" -d '{"description": "Some description"}' "$BASE_URL/todos")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 "$STATUS" "Title is required" "$BODY" "Create a todo without title"

# Test 11: Get all todos
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 "$STATUS" "My Todo" "$BODY" "Get all todos"

# Test 12: Get specific todo
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO_ID")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 "$STATUS" "My Todo" "$BODY" "Get specific todo"

# Test 13: Get specific todo that doesn't exist
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/9999")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 404 "$STATUS" "Todo not found" "$BODY" "Get specific todo that doesn't exist"

# Test 14: Update specific todo
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -H "Content-Type: application/json" -d '{"title": "Updated Todo", "completed": true}' "$BASE_URL/todos/$TODO_ID")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 "$STATUS" "Updated Todo" "$BODY" "Update specific todo"

# Test 15: Update specific todo with empty title
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -H "Content-Type: application/json" -d '{"title": ""}' "$BASE_URL/todos/$TODO_ID")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 "$STATUS" "Title is required" "$BODY" "Update specific todo with empty title"

# Test 16: Delete specific todo
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/$TODO_ID")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 204 "$STATUS" "" "$BODY" "Delete specific todo"

# Test 17: Get deleted todo
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO_ID")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 404 "$STATUS" "Todo not found" "$BODY" "Get deleted todo"

# Test 18: Change password
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}' "$BASE_URL/password")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 "$STATUS" "{}" "$BODY" "Change password"

# Test 19: Change password with wrong old password
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -H "Content-Type: application/json" -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}' "$BASE_URL/password")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 "$STATUS" "Invalid credentials" "$BODY" "Change password with wrong old password"

# Test 20: Change password with short new password
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}' "$BASE_URL/password")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 "$STATUS" "Password too short" "$BODY" "Change password with short new password"

# Test 21: Login with new password
RESP=$(curl -s -w "\n%{http_code}" -c new_cookies.txt -X POST -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' "$BASE_URL/login")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 "$STATUS" "testuser" "$BODY" "Login with new password"

# Test 22: Logout
RESP=$(curl -s -w "\n%{http_code}" -b new_cookies.txt -X POST "$BASE_URL/logout")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 "$STATUS" "{}" "$BODY" "Logout"

# Test 23: Get /me after logout
RESP=$(curl -s -w "\n%{http_code}" -b new_cookies.txt "$BASE_URL/me")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 "$STATUS" "Authentication required" "$BODY" "Get /me after logout"

# Register a second user to test todo isolation
curl -s -X POST -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' "$BASE_URL/register" > /dev/null
curl -s -c user2_cookies.txt -X POST -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' "$BASE_URL/login" > /dev/null
curl -s -b user2_cookies.txt -X POST -H "Content-Type: application/json" -d '{"title": "User2 Todo"}' "$BASE_URL/todos" > /dev/null
USER2_TODO_JSON=$(curl -s -b user2_cookies.txt "$BASE_URL/todos")
USER2_TODO_ID=$(echo "$USER2_TODO_JSON" | jq -r '.[0].id')

# Testuser needs to log back in to test isolation
curl -s -c testuser_cookies.txt -X POST -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' "$BASE_URL/login" > /dev/null

# Test 24: Get other user's todo (should be 404)
RESP=$(curl -s -w "\n%{http_code}" -b testuser_cookies.txt "$BASE_URL/todos/$USER2_TODO_ID")
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 404 "$STATUS" "Todo not found" "$BODY" "Get other user's todo (should be 404)"

# Cleanup
rm -f cookies.txt new_cookies.txt user2_cookies.txt testuser_cookies.txt
kill $SERVER_PID

echo "Tests completed."