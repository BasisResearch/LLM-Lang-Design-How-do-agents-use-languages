#!/bin/bash
set -e

PORT=8888
BASE="http://localhost:$PORT"

echo "Starting server in background..."
./run.sh --port $PORT > server.log 2>&1 &
SERVER_PID=$!
sleep 3

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server failed to start. Log:"
    cat server.log
    exit 1
fi

# Helper to extract body and code
get_resp() {
    curl -s -w "\n%{http_code}" "$@"
}

echo "1. Testing POST /register..."
RESP=$(get_resp -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL register: $CODE"; echo "$RESP"; exit 1; fi
echo "PASS register"

echo "2. Testing POST /register (duplicate)..."
RESP=$(get_resp -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "409" ]; then echo "FAIL register duplicate: $CODE"; exit 1; fi
echo "PASS register duplicate"

echo "3. Testing POST /register (invalid username - too short)..."
RESP=$(get_resp -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL register invalid username: $CODE"; exit 1; fi
echo "PASS register invalid username"

echo "4. Testing POST /register (short password)..."
RESP=$(get_resp -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser2","password":"123"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL register short password: $CODE"; exit 1; fi
echo "PASS register short password"

echo "5. Testing POST /login..."
RESP=$(get_resp -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL login: $CODE"; echo "$RESP"; exit 1; fi
echo "PASS login"

echo "6. Testing GET /me..."
RESP=$(get_resp -X GET "$BASE/me" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL me: $CODE"; exit 1; fi
echo "PASS me"

echo "7. Testing GET /me (without auth)..."
RESP=$(get_resp -X GET "$BASE/me")
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL me no auth: $CODE"; exit 1; fi
echo "PASS me no auth"

echo "8. Testing PUT /password..."
RESP=$(get_resp -X PUT "$BASE/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL password: $CODE"; exit 1; fi
echo "PASS password"

echo "9. Testing PUT /password (wrong old password)..."
RESP=$(get_resp -X PUT "$BASE/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"wrong","new_password":"newpassword123"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL password wrong old: $CODE"; exit 1; fi
echo "PASS password wrong old"

echo "10. Testing PUT /password (short new password)..."
RESP=$(get_resp -X PUT "$BASE/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"newpassword123","new_password":"short"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL password short new: $CODE"; exit 1; fi
echo "PASS password short new"

echo "11. Testing POST /todos..."
RESP=$(get_resp -X POST "$BASE/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title":"My Todo","description":"A test"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL create todo: $CODE"; echo "$RESP"; exit 1; fi
TODO_ID=$(echo "$RESP" | head -n1 | grep -o '"id":[0-9]*' | cut -d':' -f2)
echo "PASS create todo (ID: $TODO_ID)"

echo "12. Testing POST /todos (missing title)..."
RESP=$(get_resp -X POST "$BASE/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description":"No title"}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL create todo missing title: $CODE"; exit 1; fi
echo "PASS create todo missing title"

echo "13. Testing GET /todos..."
RESP=$(get_resp -X GET "$BASE/todos" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL get todos: $CODE"; exit 1; fi
echo "PASS get todos"

echo "14. Testing GET /todos/:id..."
RESP=$(get_resp -X GET "$BASE/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL get todo: $CODE"; exit 1; fi
echo "PASS get todo"

echo "15. Testing GET /todos/:id (not found / different user)..."
RESP=$(get_resp -X GET "$BASE/todos/99999" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "404" ]; then echo "FAIL get todo not found: $CODE"; exit 1; fi
echo "PASS get todo not found"

echo "16. Testing PUT /todos/:id (partial update)..."
RESP=$(get_resp -X PUT "$BASE/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed":true}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL update todo: $CODE"; exit 1; fi
if ! echo "$RESP" | head -n1 | grep -q '"completed":true'; then
    echo "FAIL update todo completed not true"
    exit 1
fi
echo "PASS update todo"

echo "17. Testing PUT /todos/:id (empty title)..."
RESP=$(get_resp -X PUT "$BASE/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title":""}')
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL update todo empty title: $CODE"; exit 1; fi
echo "PASS update todo empty title"

echo "18. Testing DELETE /todos/:id..."
RESP=$(get_resp -X DELETE "$BASE/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "204" ]; then echo "FAIL delete todo: $CODE"; exit 1; fi
echo "PASS delete todo"

echo "19. Testing DELETE /todos/:id (not found after delete)..."
RESP=$(get_resp -X DELETE "$BASE/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "404" ]; then echo "FAIL delete todo not found: $CODE"; exit 1; fi
echo "PASS delete todo not found"

echo "20. Testing POST /logout..."
RESP=$(get_resp -X POST "$BASE/logout" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL logout: $CODE"; exit 1; fi
echo "PASS logout"

echo "21. Testing GET /me (after logout)..."
RESP=$(get_resp -X GET "$BASE/me" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL me after logout: $CODE"; exit 1; fi
echo "PASS me after logout"

echo ""
echo "========================================="
echo "ALL TESTS PASSED SUCCESSFULLY!"
echo "========================================="

# Cleanup
kill $SERVER_PID 2>/dev/null || true
rm -f cookies.txt server.log