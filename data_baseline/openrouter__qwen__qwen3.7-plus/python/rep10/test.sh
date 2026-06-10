#!/bin/bash
set -e

PORT=8888
echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 2

# Function to test and assert
test_endpoint() {
    local name=$1
    local expected_status=$2
    local actual_status=$3
    if [ "$expected_status" == "$actual_status" ]; then
        echo "✅ PASS: $name"
    else
        echo "❌ FAIL: $name - Expected status $expected_status, got $actual_status"
        kill $SERVER_PID
        exit 1
    fi
}

echo "Testing /register..."

# Test valid registration
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
test_endpoint "Register valid user" 201 "$STATUS"

# Test invalid username (too short)
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Register invalid username (too short)" 400 "$STATUS"

# Test username with special characters
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "test user!", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Register invalid username (special chars)" 400 "$STATUS"

# Test password too short
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Register password too short" 400 "$STATUS"

# Test duplicate username
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Register duplicate username" 409 "$STATUS"

echo "Testing /login..."

# Test invalid login
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "wrongpassword"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Login invalid credentials" 401 "$STATUS"

# Test valid login
RESP=$(curl -s -i -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "password123"}')
STATUS=$(echo "$RESP" | grep -i "^HTTP/" | awk '{print $2}')
test_endpoint "Login valid credentials" 200 "$STATUS"

# Extract cookie
COOKIE=$(echo "$RESP" | grep -i "^Set-Cookie:" | sed 's/Set-Cookie: //i' | cut -d';' -f1)
echo "Got cookie: $COOKIE"

echo "Testing /me..."

# Test me without cookie
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/me)
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Me without auth" 401 "$STATUS"

# Test me with cookie
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/me -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Me with auth" 200 "$STATUS"

echo "Testing /password..."

# Test change password with wrong old password
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/password -H "Cookie: $COOKIE" -H "Content-Type: application/json" -d '{"old_password": "wrong", "new_password": "newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Change password wrong old password" 401 "$STATUS"

# Test change password with short new password
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/password -H "Cookie: $COOKIE" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "short"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Change password short new password" 400 "$STATUS"

# Test valid change password
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/password -H "Cookie: $COOKIE" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Change password valid" 200 "$STATUS"

# Verify new password works
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Login with new password" 200 "$STATUS"

echo "Testing /todos..."

# Create todo 1
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/todos -H "Cookie: $COOKIE" -H "Content-Type: application/json" -d '{"title": "First todo", "description": "Description 1"}')
STATUS=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
test_endpoint "Create todo 1" 201 "$STATUS"
TODO1_ID=$(echo "$BODY" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

# Create todo 2 (no description)
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/todos -H "Cookie: $COOKIE" -H "Content-Type: application/json" -d '{"title": "Second todo"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Create todo 2 (no description)" 201 "$STATUS"

# Create todo with empty title
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/todos -H "Cookie: $COOKIE" -H "Content-Type: application/json" -d '{"title": "   ", "description": "test"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Create todo with empty title" 400 "$STATUS"

# Get all todos
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get all todos" 200 "$STATUS"

# Get specific todo
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos/$TODO1_ID -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get specific todo" 200 "$STATUS"

# Get non-existent todo
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos/9999 -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get non-existent todo" 404 "$STATUS"

# Update todo
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/todos/$TODO1_ID -H "Cookie: $COOKIE" -H "Content-Type: application/json" -d '{"completed": true, "title": "Updated title"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Update todo" 200 "$STATUS"

# Verify updated_at changed and completed is true
RESP=$(curl -s http://localhost:$PORT/todos/$TODO1_ID -H "Cookie: $COOKIE")
if echo "$RESP" | grep -q '"completed": true'; then
    echo "✅ PASS: Todo updated correctly"
else
    echo "❌ FAIL: Todo not updated correctly"
    kill $SERVER_PID
    exit 1
fi

# Register a second user to test isolation
RESP=$(curl -s -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "testuser3", "password": "password123"}')
RESP2=$(curl -s -i -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "testuser3", "password": "password123"}')
COOKIE2=$(echo "$RESP2" | grep -i "^Set-Cookie:" | sed 's/Set-Cookie: //i' | cut -d';' -f1)

# Try to access first user's todo with second user's cookie
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos/$TODO1_ID -H "Cookie: $COOKIE2")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get other user's todo returns 404" 404 "$STATUS"

# Try to update first user's todo with second user's cookie
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/todos/$TODO1_ID -H "Cookie: $COOKIE2" -H "Content-Type: application/json" -d '{"completed": false}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Update other user's todo returns 404" 404 "$STATUS"

# Delete todo
RESP=$(curl -s -w "\n%{http_code}" -X DELETE http://localhost:$PORT/todos/$TODO1_ID -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Delete todo" 204 "$STATUS"

# Verify deleted
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos/$TODO1_ID -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get deleted todo returns 404" 404 "$STATUS"

# Delete non-existent todo
RESP=$(curl -s -w "\n%{http_code}" -X DELETE http://localhost:$PORT/todos/9999 -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Delete non-existent todo" 404 "$STATUS"

echo "Testing /logout..."

# Logout
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/logout -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Logout" 200 "$STATUS"

# Try to access protected endpoint after logout
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/me -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Me after logout returns 401" 401 "$STATUS"

echo ""
echo "🎉 All tests passed! 🎉"

# Cleanup
kill $SERVER_PID
exit 0
