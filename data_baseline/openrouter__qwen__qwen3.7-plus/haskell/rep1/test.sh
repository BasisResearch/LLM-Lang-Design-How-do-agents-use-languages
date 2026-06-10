#!/bin/bash
set -e

PORT=8081
BASE="http://localhost:$PORT"

echo "Starting server in background..."
./run.sh --port "$PORT" &
SERVER_PID=$!

# Ensure server is killed on exit
trap "kill $SERVER_PID 2>/dev/null || true" EXIT

echo "Waiting for server to start..."
sleep 4

# Helper for curl
curl_post() {
    curl -s -i -w "\nHTTP_CODE:%{http_code}" -X POST "$1" -H "Content-Type: application/json" -d "$2" ${3:+-b "$3"}
}

curl_put() {
    curl -s -i -w "\nHTTP_CODE:%{http_code}" -X PUT "$1" -H "Content-Type: application/json" -d "$2" ${3:+-b "$3"}
}

curl_get() {
    curl -s -i -w "\nHTTP_CODE:%{http_code}" -X GET "$1" ${2:+-b "$2"}
}

curl_delete() {
    curl -s -i -w "\nHTTP_CODE:%{http_code}" -X DELETE "$1" ${2:+-b "$2"}
}

echo "=== Testing Register ==="
RES=$(curl_post "$BASE/register" '{"username": "testuser", "password": "password123"}')
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:201" || { echo "Register failed"; exit 1; }

echo "=== Testing Register Duplicate ==="
RES=$(curl_post "$BASE/register" '{"username": "testuser", "password": "password123"}')
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:409" || { echo "Register duplicate failed"; exit 1; }

echo "=== Testing Register Invalid Username ==="
RES=$(curl_post "$BASE/register" '{"username": "ab", "password": "password123"}')
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:400" || { echo "Register invalid username failed"; exit 1; }

echo "=== Testing Register Short Password ==="
RES=$(curl_post "$BASE/register" '{"username": "testuser2", "password": "short"}')
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:400" || { echo "Register short password failed"; exit 1; }

echo "=== Testing Login ==="
RES=$(curl_post "$BASE/login" '{"username": "testuser", "password": "password123"}')
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:200" || { echo "Login failed"; exit 1; }

# Extract cookie
COOKIE=$(echo "$RES" | grep -i 'Set-Cookie:' | grep -o 'session_id=[^;]*' | head -n 1)
echo "Cookie: $COOKIE"
[ -n "$COOKIE" ] || { echo "No session cookie found"; exit 1; }

echo "=== Testing Get Me ==="
RES=$(curl_get "$BASE/me" "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:200" || { echo "Get me failed"; exit 1; }
echo "$RES" | grep -q "testuser" || { echo "Get me wrong user"; exit 1; }

echo "=== Testing No Auth ==="
RES=$(curl_get "$BASE/me")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:401" || { echo "No auth should fail"; exit 1; }

echo "=== Testing Change Password ==="
RES=$(curl_put "$BASE/password" '{"old_password": "password123", "new_password": "newpassword123"}' "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:200" || { echo "Change password failed"; exit 1; }

echo "=== Testing Change Password Wrong Old ==="
RES=$(curl_put "$BASE/password" '{"old_password": "wrongpassword", "new_password": "newpassword123"}' "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:401" || { echo "Change password wrong old should fail"; exit 1; }

echo "=== Testing Login with New Password ==="
RES=$(curl_post "$BASE/login" '{"username": "testuser", "password": "newpassword123"}')
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:200" || { echo "Login with new password failed"; exit 1; }
COOKIE=$(echo "$RES" | grep -i 'Set-Cookie:' | grep -o 'session_id=[^;]*' | head -n 1)

echo "=== Testing Create Todo ==="
RES=$(curl_post "$BASE/todos" '{"title": "My Todo", "description": "Do this"}' "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:201" || { echo "Create todo failed"; exit 1; }
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | head -n 1 | grep -o '[0-9]*')
echo "Todo ID: $TODO_ID"

echo "=== Testing Create Todo Empty Title ==="
RES=$(curl_post "$BASE/todos" '{"title": ""}' "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:400" || { echo "Create todo empty title should fail"; exit 1; }

echo "=== Testing Get Todos ==="
RES=$(curl_get "$BASE/todos" "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:200" || { echo "Get todos failed"; exit 1; }
echo "$RES" | grep -q "My Todo" || { echo "Get todos missing todo"; exit 1; }

echo "=== Testing Get Specific Todo ==="
RES=$(curl_get "$BASE/todos/$TODO_ID" "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:200" || { echo "Get specific todo failed"; exit 1; }

echo "=== Testing Get Specific Todo Not Found ==="
RES=$(curl_get "$BASE/todos/9999" "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:404" || { echo "Get specific todo not found should fail"; exit 1; }

echo "=== Testing Update Todo ==="
RES=$(curl_put "$BASE/todos/$TODO_ID" '{"completed": true, "title": "Updated Todo"}' "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:200" || { echo "Update todo failed"; exit 1; }
echo "$RES" | grep -q "Updated Todo" || { echo "Update todo title not updated"; exit 1; }
echo "$RES" | grep -q '"completed":true' || { echo "Update todo completed not updated"; exit 1; }

echo "=== Testing Update Todo Empty Title ==="
RES=$(curl_put "$BASE/todos/$TODO_ID" '{"title": ""}' "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:400" || { echo "Update todo empty title should fail"; exit 1; }

echo "=== Testing Delete Todo ==="
RES=$(curl_delete "$BASE/todos/$TODO_ID" "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:204" || { echo "Delete todo failed"; exit 1; }

echo "=== Testing Delete Todo Not Found ==="
RES=$(curl_delete "$BASE/todos/$TODO_ID" "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:404" || { echo "Delete todo not found should fail"; exit 1; }

echo "=== Testing Logout ==="
RES=$(curl -s -i -w "\nHTTP_CODE:%{http_code}" -X POST "$BASE/logout" -b "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:200" || { echo "Logout failed"; exit 1; }

echo "=== Testing Auth After Logout ==="
RES=$(curl_get "$BASE/me" "$COOKIE")
echo "$RES"
echo "$RES" | grep -q "HTTP_CODE:401" || { echo "Auth after logout should fail"; exit 1; }

echo "=== ALL TESTS PASSED ==="
