#!/bin/bash
set -e

PORT=9998
echo "Starting server on port $PORT..."
python3 server.py --port $PORT &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

trap "kill $SERVER_PID 2>/dev/null || true" EXIT
trap "kill $SERVER_PID 2>/dev/null || true; exit 1" INT TERM

sleep 2

test_endpoint() {
    local name=$1
    local expected_status=$2
    local actual_status=$3
    if [ "$expected_status" == "$actual_status" ]; then
        echo "✅ PASS: $name"
    else
        echo "❌ FAIL: $name - Expected status $expected_status, got $actual_status"
        exit 1
    fi
}

echo "=== Testing /register ==="

# Valid registration
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "user1", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Register valid" 201 "$STATUS"

# Invalid username (too short)
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Register invalid username (short)" 400 "$STATUS"

# Invalid username (special chars)
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "user 1!", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Register invalid username (special chars)" 400 "$STATUS"

# Password too short
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "user2", "password": "short"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Register password too short" 400 "$STATUS"

# Duplicate username
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "user1", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Register duplicate username" 409 "$STATUS"

echo "=== Testing /login ==="

# Invalid login
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "user1", "password": "wrongpass"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Login invalid credentials" 401 "$STATUS"

# Valid login
RESP=$(curl -s -i -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "user1", "password": "password123"}')
STATUS=$(echo "$RESP" | grep -i "^HTTP/" | awk '{print $2}')
COOKIE1=$(echo "$RESP" | grep -i "^Set-Cookie:" | tr -d '\r' | sed 's/Set-Cookie: //i' | cut -d';' -f1)
test_endpoint "Login valid" 200 "$STATUS"

echo "=== Testing /me ==="

# Me without auth
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/me)
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Me without auth" 401 "$STATUS"

# Me with auth
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/me -H "Cookie: $COOKIE1")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Me with auth" 200 "$STATUS"

echo "=== Testing /password ==="

# Change password wrong old password
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/password -H "Cookie: $COOKIE1" -H "Content-Type: application/json" -d '{"old_password": "wrong", "new_password": "newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Password wrong old password" 401 "$STATUS"

# Change password short new password
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/password -H "Cookie: $COOKIE1" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "short"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Password short new password" 400 "$STATUS"

# Valid change password
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/password -H "Cookie: $COOKIE1" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Password change valid" 200 "$STATUS"

# Verify new password works
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "user1", "password": "newpassword123"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Login with new password" 200 "$STATUS"

echo "=== Testing /todos ==="

# Get new cookie
RESP=$(curl -s -i -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "user1", "password": "newpassword123"}')
COOKIE2=$(echo "$RESP" | grep -i "^Set-Cookie:" | tr -d '\r' | sed 's/Set-Cookie: //i' | cut -d';' -f1)

# Create todo 1
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/todos -H "Cookie: $COOKIE2" -H "Content-Type: application/json" -d '{"title": "First todo", "description": "Description 1"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Create todo 1" 201 "$STATUS"
TODO1=$(echo "$RESP" | sed '$d' | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

# Create todo 2 (no description)
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/todos -H "Cookie: $COOKIE2" -H "Content-Type: application/json" -d '{"title": "Second todo"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Create todo 2 (no description)" 201 "$STATUS"

# Create todo with empty title
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/todos -H "Cookie: $COOKIE2" -H "Content-Type: application/json" -d '{"title": "   ", "description": "test"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Create todo with empty title" 400 "$STATUS"

# Get all todos
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos -H "Cookie: $COOKIE2")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get all todos" 200 "$STATUS"

# Get specific todo
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos/$TODO1 -H "Cookie: $COOKIE2")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get specific todo" 200 "$STATUS"

# Get non-existent todo
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos/9999 -H "Cookie: $COOKIE2")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get non-existent todo" 404 "$STATUS"

# Update todo
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/todos/$TODO1 -H "Cookie: $COOKIE2" -H "Content-Type: application/json" -d '{"completed": true, "title": "Updated title"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Update todo" 200 "$STATUS"

# Verify updated_at changed and completed is true
RESP=$(curl -s http://localhost:$PORT/todos/$TODO1 -H "Cookie: $COOKIE2")
if echo "$RESP" | grep -q '"completed": true'; then
    echo "✅ PASS: Todo updated correctly"
else
    echo "❌ FAIL: Todo not updated correctly"
    exit 1
fi

# Test partial update (only update description)
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/todos/$TODO1 -H "Cookie: $COOKIE2" -H "Content-Type: application/json" -d '{"description": "Only description changed"}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Partial update todo" 200 "$STATUS"

# Verify partial update preserved other fields
RESP=$(curl -s http://localhost:$PORT/todos/$TODO1 -H "Cookie: $COOKIE2")
if echo "$RESP" | grep -q '"completed": true' && echo "$RESP" | grep -q '"title": "Updated title"'; then
    echo "✅ PASS: Partial update preserved other fields"
else
    echo "❌ FAIL: Partial update did not preserve other fields"
    exit 1
fi

# Register a second user to test isolation
curl -s -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "user3", "password": "password123"}' > /dev/null
RESP2=$(curl -s -i -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "user3", "password": "password123"}')
COOKIE3=$(echo "$RESP2" | grep -i "^Set-Cookie:" | tr -d '\r' | sed 's/Set-Cookie: //i' | cut -d';' -f1)

# Try to access first user's todo with second user's cookie
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos/$TODO1 -H "Cookie: $COOKIE3")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get other user's todo returns 404" 404 "$STATUS"

# Try to update first user's todo with second user's cookie
RESP=$(curl -s -w "\n%{http_code}" -X PUT http://localhost:$PORT/todos/$TODO1 -H "Cookie: $COOKIE3" -H "Content-Type: application/json" -d '{"completed": false}')
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Update other user's todo returns 404" 404 "$STATUS"

# Delete todo
RESP=$(curl -s -w "\n%{http_code}" -X DELETE http://localhost:$PORT/todos/$TODO1 -H "Cookie: $COOKIE2")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Delete todo" 204 "$STATUS"

# Verify deleted
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos/$TODO1 -H "Cookie: $COOKIE2")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Get deleted todo returns 404" 404 "$STATUS"

# Delete non-existent todo
RESP=$(curl -s -w "\n%{http_code}" -X DELETE http://localhost:$PORT/todos/9999 -H "Cookie: $COOKIE2")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Delete non-existent todo" 404 "$STATUS"

echo "=== Testing /logout ==="

# Logout
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/logout -H "Cookie: $COOKIE2")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Logout" 200 "$STATUS"

# Try to access protected endpoint after logout
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/me -H "Cookie: $COOKIE2")
STATUS=$(echo "$RESP" | tail -n1)
test_endpoint "Me after logout returns 401" 401 "$STATUS"

echo ""
echo "🎉 All comprehensive tests passed! 🎉"
