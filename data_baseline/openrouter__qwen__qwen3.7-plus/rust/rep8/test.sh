#!/bin/bash
set -e

PORT=8085
BASE_URL="http://localhost:$PORT"

echo "Starting server..."
./target/release/todo_app --port "$PORT" &
SERVER_PID=$!
sleep 2

echo "1. Testing POST /register (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
if [[ "$RES" == *"201"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "2. Testing POST /register (invalid username)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "te", "password": "password123"}')
if [[ "$RES" == *"400"*"Invalid username"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "3. Testing POST /register (short password)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
if [[ "$RES" == *"400"*"Password too short"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "4. Testing POST /register (duplicate username)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
if [[ "$RES" == *"409"*"Username already exists"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "5. Testing POST /login (valid)..."
curl -s -i -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' > /tmp/login.txt
if grep -q "200 OK" /tmp/login.txt && grep -qi "set-cookie: session_id=" /tmp/login.txt; then
    echo "PASS"
else
    echo "FAIL"
    cat /tmp/login.txt
    exit 1
fi
COOKIE=$(grep -i "set-cookie" /tmp/login.txt | sed 's/.*session_id=\([^;]*\).*/\1/' | tr -d '\r')
echo "Got cookie: $COOKIE"

echo "6. Testing POST /login (invalid credentials)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrong"}')
if [[ "$RES" == *"401"*"Invalid credentials"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "7. Testing GET /me (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -H "Cookie: session_id=$COOKIE")
if [[ "$RES" == *"200"*"\"id\":1"*"\"username\":\"testuser\""* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "8. Testing GET /me (no auth)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
if [[ "$RES" == *"401"*"Authentication required"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "9. Testing PUT /password (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Cookie: session_id=$COOKIE" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
if [[ "$RES" == *"200"*"{}"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "10. Testing PUT /password (invalid old password)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Cookie: session_id=$COOKIE" -H "Content-Type: application/json" -d '{"old_password": "wrong", "new_password": "newpassword123"}')
if [[ "$RES" == *"401"*"Invalid credentials"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "11. Testing PUT /password (short new password)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Cookie: session_id=$COOKIE" -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}')
if [[ "$RES" == *"400"*"Password too short"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "12. Testing POST /todos (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Cookie: session_id=$COOKIE" -H "Content-Type: application/json" -d '{"title": "My First Todo", "description": "This is a test"}')
if [[ "$RES" == *"201"*"\"title\":\"My First Todo\""* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
echo "Got todo ID: $TODO_ID"

echo "13. Testing POST /todos (missing title)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Cookie: session_id=$COOKIE" -H "Content-Type: application/json" -d '{"description": "No title"}')
if [[ "$RES" == *"400"*"Title is required"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "14. Testing GET /todos..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -H "Cookie: session_id=$COOKIE")
if [[ "$RES" == *"200"*"\"id\":$TODO_ID"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "15. Testing GET /todos/:id (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE")
if [[ "$RES" == *"200"*"\"id\":$TODO_ID"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "16. Testing GET /todos/:id (not found)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/9999" -H "Cookie: session_id=$COOKIE")
if [[ "$RES" == *"404"*"Todo not found"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "17. Testing PUT /todos/:id (valid)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE" -H "Content-Type: application/json" -d '{"completed": true, "title": "Updated Title"}')
if [[ "$RES" == *"200"*"\"completed\":true"*"\"title\":\"Updated Title\""* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "18. Testing PUT /todos/:id (empty title)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE" -H "Content-Type: application/json" -d '{"title": ""}')
if [[ "$RES" == *"400"*"Title is required"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "19. Testing DELETE /todos/:id (valid)..."
RES=$(curl -s -w "%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE")
if [[ "$RES" == "204" ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "20. Testing DELETE /todos/:id (not found)..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -H "Cookie: session_id=$COOKIE")
if [[ "$RES" == *"404"*"Todo not found"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "21. Testing POST /logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -H "Cookie: session_id=$COOKIE")
if [[ "$RES" == *"200"*"{}"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "22. Testing GET /me after logout..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -H "Cookie: session_id=$COOKIE")
if [[ "$RES" == *"401"*"Authentication required"* ]]; then echo "PASS"; else echo "FAIL: $RES"; exit 1; fi

echo "ALL TESTS PASSED!"
kill $SERVER_PID 2>/dev/null || true
