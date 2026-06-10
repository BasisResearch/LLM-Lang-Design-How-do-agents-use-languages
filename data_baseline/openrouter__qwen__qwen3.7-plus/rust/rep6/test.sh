#!/bin/bash
set -e

echo "Building the server..."
cargo build --release

PORT=8080
BASE_URL="http://localhost:$PORT"

# Allow overriding port for testing
if [ -n "$1" ]; then
    PORT=$1
    BASE_URL="http://localhost:$PORT"
fi

echo "Starting server on port $PORT..."
./target/release/todo_api --port $PORT &
SERVER_PID=$!

# Wait for server to be ready
for i in {1..15}; do
    if curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/me" | grep -q "401"; then
        echo "Server is ready!"
        break
    fi
    sleep 1
done

# Cleanup function
cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt cookies2.txt
}
trap cleanup EXIT

echo "1. Register a new user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
    echo "FAIL: Register expected 201, got $CODE. Body: $(echo "$RES" | sed '$d')"
    exit 1
fi
echo "PASS: Register"

echo "2. Register duplicate user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "409" ] || [[ "$BODY" != *"Username already exists"* ]]; then
    echo "FAIL: Duplicate register expected 409, got $CODE. Body: $BODY"
    exit 1
fi
echo "PASS: Duplicate register"

echo "3. Login"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Login expected 200, got $CODE. Body: $(echo "$RES" | sed '$d')"
    exit 1
fi
echo "PASS: Login"

echo "4. Get /me"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ] || [[ "$BODY" != *"testuser"* ]]; then
    echo "FAIL: Get /me expected 200, got $CODE. Body: $BODY"
    exit 1
fi
echo "PASS: Get /me"

echo "5. Check Content-Type"
RES_HEADERS=$(curl -s -I -X GET "$BASE_URL/me" -b cookies.txt)
if ! echo "$RES_HEADERS" | grep -qi "content-type: application/json"; then
    echo "FAIL: Content-Type should be application/json"
    echo "$RES_HEADERS"
    exit 1
fi
echo "PASS: Content-Type check"

echo "6. Create todo"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title":"My Todo","description":"Do this"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ] || [[ "$BODY" != *"My Todo"* ]]; then
    echo "FAIL: Create todo expected 201, got $CODE. Body: $BODY"
    exit 1
fi
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | cut -d':' -f2)
echo "PASS: Create todo (ID: $TODO_ID)"

echo "7. Get all todos"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ] || [[ "$BODY" != *"My Todo"* ]]; then
    echo "FAIL: Get todos expected 200, got $CODE. Body: $BODY"
    exit 1
fi
echo "PASS: Get all todos"

echo "8. Get specific todo"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ] || [[ "$BODY" != *"My Todo"* ]]; then
    echo "FAIL: Get specific todo expected 200, got $CODE. Body: $BODY"
    exit 1
fi
echo "PASS: Get specific todo"

echo "9. Update todo"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed":true}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ] || [[ "$BODY" != *"true"* ]]; then
    echo "FAIL: Update todo expected 200, got $CODE. Body: $BODY"
    exit 1
fi
echo "PASS: Update todo"

echo "10. Delete todo"
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then
    echo "FAIL: Delete todo expected 204, got $CODE"
    exit 1
fi
echo "PASS: Delete todo"

echo "11. Get deleted todo (should be 404)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
    echo "FAIL: Get deleted todo expected 404, got $CODE"
    exit 1
fi
echo "PASS: Get deleted todo"

echo "12. Update password"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Update password expected 200, got $CODE"
    exit 1
fi
echo "PASS: Update password"

echo "13. Login with new password"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' -c cookies2.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Login with new password expected 200, got $CODE"
    exit 1
fi
echo "PASS: Login with new password"

echo "14. Logout"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies2.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAIL: Logout expected 200, got $CODE"
    exit 1
fi
echo "PASS: Logout"

echo "15. Get /me after logout (should be 401)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies2.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: Get /me after logout expected 401, got $CODE"
    exit 1
fi
echo "PASS: Get /me after logout"

echo "16. Unauthorized access (no cookie)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAIL: Unauthorized access expected 401, got $CODE"
    exit 1
fi
echo "PASS: Unauthorized access"

echo "All tests passed!"
