#!/bin/bash
set -e

PORT=3000
BASE="http://localhost:$PORT"

# Start server in background
node server.js --port $PORT &
SERVER_PID=$!
sleep 1

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  rm -f cookies.txt
}
trap cleanup EXIT

echo "=== Testing Register ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' $BASE/register)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "201" ] && echo "Register: PASS" || { echo "Register: FAIL (Expected 201, got $CODE)"; echo "$RES"; exit 1; }

echo "=== Testing Register Duplicate ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' $BASE/register)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "409" ] && echo "Register Duplicate: PASS" || { echo "Register Duplicate: FAIL (Expected 409, got $CODE)"; exit 1; }

echo "=== Testing Register Invalid Username ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}' $BASE/register)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "400" ] && echo "Register Invalid Username: PASS" || { echo "Register Invalid Username: FAIL (Expected 400, got $CODE)"; exit 1; }

echo "=== Testing Register Short Password ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser2","password":"short"}' $BASE/register)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "400" ] && echo "Register Short Password: PASS" || { echo "Register Short Password: FAIL (Expected 400, got $CODE)"; exit 1; }

echo "=== Testing Login ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt $BASE/login)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "Login: PASS" || { echo "Login: FAIL (Expected 200, got $CODE)"; exit 1; }

echo "=== Testing Login Invalid Creds ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"wrongpassword"}' $BASE/login)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "401" ] && echo "Login Invalid Creds: PASS" || { echo "Login Invalid Creds: FAIL (Expected 401, got $CODE)"; exit 1; }

echo "=== Testing GET /me ==="
RES=$(curl -s -w "\n%{http_code}" -X GET -b cookies.txt $BASE/me)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "GET /me: PASS" || { echo "GET /me: FAIL (Expected 200, got $CODE)"; exit 1; }

echo "=== Testing PUT /password ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}' $BASE/password)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "PUT /password: PASS" || { echo "PUT /password: FAIL (Expected 200, got $CODE)"; exit 1; }

echo "=== Testing PUT /password Invalid Old ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"wrong","new_password":"newpassword123"}' $BASE/password)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "401" ] && echo "PUT /password Invalid Old: PASS" || { echo "PUT /password Invalid Old: FAIL (Expected 401, got $CODE)"; exit 1; }

echo "=== Testing PUT /password Short New ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"newpassword123","new_password":"short"}' $BASE/password)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "400" ] && echo "PUT /password Short New: PASS" || { echo "PUT /password Short New: FAIL (Expected 400, got $CODE)"; exit 1; }

echo "=== Testing POST /todos ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -b cookies.txt -d '{"title":"My Todo","description":"A description"}' $BASE/todos)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "201" ] && echo "POST /todos: PASS" || { echo "POST /todos: FAIL (Expected 201, got $CODE)"; exit 1; }
TODO_ID=$(echo "$RES" | sed '$d' | grep -o '"id":[0-9]*' | cut -d':' -f2)

echo "=== Testing POST /todos Missing Title ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -b cookies.txt -d '{"description":"No title"}' $BASE/todos)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "400" ] && echo "POST /todos Missing Title: PASS" || { echo "POST /todos Missing Title: FAIL (Expected 400, got $CODE)"; exit 1; }

echo "=== Testing POST /todos Empty Title ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -b cookies.txt -d '{"title":""}' $BASE/todos)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "400" ] && echo "POST /todos Empty Title: PASS" || { echo "POST /todos Empty Title: FAIL (Expected 400, got $CODE)"; exit 1; }

echo "=== Testing GET /todos ==="
RES=$(curl -s -w "\n%{http_code}" -X GET -b cookies.txt $BASE/todos)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "GET /todos: PASS" || { echo "GET /todos: FAIL (Expected 200, got $CODE)"; exit 1; }

echo "=== Testing GET /todos/:id ==="
RES=$(curl -s -w "\n%{http_code}" -X GET -b cookies.txt $BASE/todos/$TODO_ID)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "GET /todos/:id: PASS" || { echo "GET /todos/:id: FAIL (Expected 200, got $CODE)"; exit 1; }

echo "=== Testing GET /todos/:id Not Found ==="
RES=$(curl -s -w "\n%{http_code}" -X GET -b cookies.txt $BASE/todos/9999)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "404" ] && echo "GET /todos/:id Not Found: PASS" || { echo "GET /todos/:id Not Found: FAIL (Expected 404, got $CODE)"; exit 1; }

echo "=== Testing PUT /todos/:id ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b cookies.txt -d '{"completed":true, "title":"Updated Title"}' $BASE/todos/$TODO_ID)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "PUT /todos/:id: PASS" || { echo "PUT /todos/:id: FAIL (Expected 200, got $CODE)"; exit 1; }

echo "=== Testing PUT /todos/:id Empty Title ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b cookies.txt -d '{"title":""}' $BASE/todos/$TODO_ID)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "400" ] && echo "PUT /todos/:id Empty Title: PASS" || { echo "PUT /todos/:id Empty Title: FAIL (Expected 400, got $CODE)"; exit 1; }

echo "=== Testing DELETE /todos/:id ==="
RES=$(curl -s -w "\n%{http_code}" -X DELETE -b cookies.txt $BASE/todos/$TODO_ID)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "204" ] && echo "DELETE /todos/:id: PASS" || { echo "DELETE /todos/:id: FAIL (Expected 204, got $CODE)"; exit 1; }

echo "=== Testing DELETE /todos/:id Not Found ==="
RES=$(curl -s -w "\n%{http_code}" -X DELETE -b cookies.txt $BASE/todos/$TODO_ID)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "404" ] && echo "DELETE /todos/:id Not Found: PASS" || { echo "DELETE /todos/:id Not Found: FAIL (Expected 404, got $CODE)"; exit 1; }

echo "=== Testing POST /logout ==="
RES=$(curl -s -w "\n%{http_code}" -X POST -b cookies.txt $BASE/logout)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "POST /logout: PASS" || { echo "POST /logout: FAIL (Expected 200, got $CODE)"; exit 1; }

echo "=== Testing GET /me after logout ==="
RES=$(curl -s -w "\n%{http_code}" -X GET -b cookies.txt $BASE/me)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "401" ] && echo "GET /me after logout: PASS" || { echo "GET /me after logout: FAIL (Expected 401, got $CODE)"; exit 1; }

echo "=== ALL TESTS PASSED ==="