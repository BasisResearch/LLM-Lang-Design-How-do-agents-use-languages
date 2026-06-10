#!/bin/bash
set -e

PORT=8888
BASE_URL="http://localhost:$PORT"

echo "Starting server in background..."
./run.sh --port $PORT > server.log 2>&1 &
SERVER_PID=$!
sleep 6 # Give it time to download deps, compile, and start

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt
    echo "Server stopped."
}
trap cleanup EXIT

echo "1. Testing POST /register (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "201" ]; then echo "FAIL: Expected 201, got $CODE. Body: $(echo "$RESP" | head -n 1)"; exit 1; fi
echo "PASS"

echo "2. Testing POST /register (invalid username)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "FAIL: Expected 400, got $CODE"; exit 1; fi
echo "PASS"

echo "3. Testing POST /register (password too short)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "FAIL: Expected 400, got $CODE"; exit 1; fi
echo "PASS"

echo "4. Testing POST /register (duplicate username)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "409" ]; then echo "FAIL: Expected 409, got $CODE"; exit 1; fi
echo "PASS"

echo "5. Testing POST /login (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: Expected 200, got $CODE"; exit 1; fi
echo "PASS"

echo "6. Testing POST /login (invalid credentials)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "FAIL: Expected 401, got $CODE"; exit 1; fi
echo "PASS"

echo "7. Testing GET /me (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: Expected 200, got $CODE"; exit 1; fi
echo "PASS"

echo "8. Testing GET /me (no auth)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "FAIL: Expected 401, got $CODE"; exit 1; fi
echo "PASS"

echo "9. Testing PUT /password (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: Expected 200, got $CODE"; exit 1; fi
echo "PASS"

echo "10. Testing PUT /password (wrong old password)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "wrong", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "FAIL: Expected 401, got $CODE"; exit 1; fi
echo "PASS"

echo "11. Testing POST /todos (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "My Todo", "description": "Do this"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "201" ]; then echo "FAIL: Expected 201, got $CODE"; exit 1; fi
TODO_ID=$(echo "$RESP" | head -n 1 | grep -o '"id":[0-9]*' | cut -d':' -f2)
echo "Created todo with ID: $TODO_ID"
echo "PASS"

echo "12. Testing POST /todos (missing title)"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description": "No title"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "FAIL: Expected 400, got $CODE"; exit 1; fi
echo "PASS"

echo "13. Testing GET /todos"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: Expected 200, got $CODE"; exit 1; fi
echo "PASS"

echo "14. Testing GET /todos/:id (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: Expected 200, got $CODE"; exit 1; fi
echo "PASS"

echo "15. Testing GET /todos/:id (not found)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/9999" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "404" ]; then echo "FAIL: Expected 404, got $CODE"; exit 1; fi
echo "PASS"

echo "16. Testing PUT /todos/:id (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: Expected 200, got $CODE"; exit 1; fi
echo "PASS"

echo "17. Testing PUT /todos/:id (empty title)"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "FAIL: Expected 400, got $CODE"; exit 1; fi
echo "PASS"

echo "18. Testing DELETE /todos/:id (valid)"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "204" ]; then echo "FAIL: Expected 204, got $CODE"; exit 1; fi
echo "PASS"

echo "19. Testing DELETE /todos/:id (not found)"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "404" ]; then echo "FAIL: Expected 404, got $CODE"; exit 1; fi
echo "PASS"

echo "20. Testing POST /logout"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL: Expected 200, got $CODE"; exit 1; fi
echo "PASS"

echo "21. Testing GET /me after logout (should be 401)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "FAIL: Expected 401, got $CODE"; exit 1; fi
echo "PASS"

echo "All tests passed!"