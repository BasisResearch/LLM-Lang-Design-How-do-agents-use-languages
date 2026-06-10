#!/bin/bash
set -e

PORT=8888
BASE_URL="http://127.0.0.1:$PORT"

# Start server in background
python3 server.py --port $PORT &
SERVER_PID=$!
sleep 2

# Function to cleanup
cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt other_cookies.txt
}
trap cleanup EXIT

echo "Testing /register..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
BODY=$(echo "$RES" | head -n 1)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "201" ]; then echo "Register failed: $RES"; exit 1; fi
echo "Register passed."

echo "Testing /register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "409" ]; then echo "Register duplicate failed: $RES"; exit 1; fi
echo "Register duplicate passed."

echo "Testing /register invalid username..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "Register invalid username failed: $RES"; exit 1; fi
echo "Register invalid username passed."

echo "Testing /register short password..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "Register short password failed: $RES"; exit 1; fi
echo "Register short password passed."

echo "Testing /login..."
RES=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "Login failed: $RES"; exit 1; fi
if ! grep -q "session_id" cookies.txt; then echo "Login missing session_id cookie"; exit 1; fi
echo "Login passed."

echo "Testing /login invalid credentials..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "Login invalid credentials failed: $RES"; exit 1; fi
echo "Login invalid credentials passed."

echo "Testing /me..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "Me failed: $RES"; exit 1; fi
echo "Me passed."

echo "Testing /me without auth..."
RES=$(curl -s -w "\n%{http_code}" "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "Me without auth failed: $RES"; exit 1; fi
echo "Me without auth passed."

echo "Testing /password..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "Password change failed: $RES"; exit 1; fi
echo "Password change passed."

echo "Testing /password wrong old password..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "Password wrong old failed: $RES"; exit 1; fi
echo "Password wrong old passed."

echo "Testing /todos (empty)..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "Get todos failed: $RES"; exit 1; fi
echo "Get todos passed."

echo "Testing POST /todos..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Do this"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "201" ]; then echo "Post todo failed: $RES"; exit 1; fi
TODO_ID=$(echo "$RES" | head -n 1 | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
echo "Post todo passed (ID: $TODO_ID)"

echo "Testing POST /todos empty title..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "", "description": "Do this"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "Post todo empty title failed: $RES"; exit 1; fi
echo "Post todo empty title passed."

echo "Testing GET /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "Get todo failed: $RES"; exit 1; fi
echo "Get todo passed."

echo "Testing GET /todos/:id not found..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/9999")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then echo "Get todo not found failed: $RES"; exit 1; fi
echo "Get todo not found passed."

echo "Testing PUT /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"completed": true, "title": "Updated Todo"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "Put todo failed: $RES"; exit 1; fi
echo "Put todo passed."

echo "Testing PUT /todos/:id empty title..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "Put todo empty title failed: $RES"; exit 1; fi
echo "Put todo empty title passed."

# Create another user to test isolation
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "otheruser", "password": "password123"}' > /dev/null
curl -s -c other_cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "otheruser", "password": "password123"}' > /dev/null

echo "Testing GET /todos/:id other user (should be 404)..."
RES=$(curl -s -w "\n%{http_code}" -b other_cookies.txt "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then echo "Get todo other user failed: $RES"; exit 1; fi
echo "Get todo other user passed."

echo "Testing DELETE /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "204" ]; then echo "Delete todo failed: $RES"; exit 1; fi
echo "Delete todo passed."

echo "Testing DELETE /todos/:id not found..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then echo "Delete todo not found failed: $RES"; exit 1; fi
echo "Delete todo not found passed."

echo "Testing /logout..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/logout")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "Logout failed: $RES"; exit 1; fi
echo "Logout passed."

echo "Testing /me after logout..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "Me after logout failed: $RES"; exit 1; fi
echo "Me after logout passed."

echo "ALL TESTS PASSED!"
