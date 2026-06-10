#!/bin/bash
set -e

# Ensure dependencies
apt-get update -qq && apt-get install -y -qq curl > /dev/null 2>&1 || true

PORT=8888
BASE_URL="http://127.0.0.1:$PORT"

# Start server in background
./run.sh --port $PORT > /dev/null 2>&1 &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt
    exit 1
}
trap cleanup EXIT

test_endpoint() {
    local name=$1
    local expected_code=$2
    local response=$3
    
    if [ "$response" -eq "$expected_code" ]; then
        echo "✅ PASS: $name"
    else
        echo "❌ FAIL: $name (Expected $expected_code, got $response)"
        exit 1
    fi
}

echo "Running tests..."

# 1. Register
RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
test_endpoint "Register valid user" 201 "$RESP"

# 2. Register duplicate
RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
test_endpoint "Register duplicate user" 409 "$RESP"

# 3. Register invalid username
RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
test_endpoint "Register short username" 400 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "user-name", "password": "password123"}')
test_endpoint "Register invalid username chars" 400 "$RESP"

# 4. Register short password
RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
test_endpoint "Register short password" 400 "$RESP"

# 5. Login
RESP=$(curl -s -o /dev/null -w "%{http_code}" -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
test_endpoint "Login valid" 200 "$RESP"

# 6. Login invalid
RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
test_endpoint "Login invalid credentials" 401 "$RESP"

# 7. Me
RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "$BASE_URL/me")
test_endpoint "Get me" 200 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/me")
test_endpoint "Get me without auth" 401 "$RESP"

# 8. Change password
RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
test_endpoint "Change password" 200 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
test_endpoint "Change password wrong old" 401 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}')
test_endpoint "Change password short new" 400 "$RESP"

# Re-login with new password
curl -s -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' > /dev/null

# 9. Create todo
RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Do this"}')
test_endpoint "Create todo" 201 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"description": "No title"}')
test_endpoint "Create todo no title" 400 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": ""}')
test_endpoint "Create todo empty title" 400 "$RESP"

# 10. Get todos
RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "$BASE_URL/todos")
test_endpoint "Get todos" 200 "$RESP"

# 11. Get specific todo
TODO_ID=$(curl -s -b cookies.txt "$BASE_URL/todos" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO_ID")
test_endpoint "Get specific todo" 200 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "$BASE_URL/todos/99999")
test_endpoint "Get non-existent todo" 404 "$RESP"

# 12. Update todo
RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"completed": true}')
test_endpoint "Update todo" 200 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"title": ""}')
test_endpoint "Update todo empty title" 400 "$RESP"

# 13. Delete todo
RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/$TODO_ID")
test_endpoint "Delete todo" 204 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO_ID")
test_endpoint "Get deleted todo" 404 "$RESP"

# 14. Logout
RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X POST "$BASE_URL/logout")
test_endpoint "Logout" 200 "$RESP"

RESP=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "$BASE_URL/me")
test_endpoint "Get me after logout" 401 "$RESP"

echo "🎉 All tests passed!"
trap - EXIT
kill $SERVER_PID 2>/dev/null || true
rm -f cookies.txt
exit 0
