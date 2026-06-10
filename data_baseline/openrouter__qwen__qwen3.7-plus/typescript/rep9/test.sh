#!/bin/bash
set -e

PORT=3456
echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!

# Function to wait for server to be ready
wait_for_server() {
  for i in {1..10}; do
    if curl -s http://localhost:$PORT/me > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Server failed to start"
  kill $SERVER_PID 2>/dev/null || true
  exit 1
}

wait_for_server

COOKIE_JAR="cookies.txt"
> $COOKIE_JAR

BASE="http://localhost:$PORT"

check() {
  local expected=$1
  local actual=$2
  if [ "$expected" = "$actual" ]; then
    echo "PASS"
  else
    echo "FAIL: Expected $expected, got $actual"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
  fi
}

echo "1. Testing POST /register - success"
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/register -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
check "201" "$CODE"

echo "2. Testing POST /register - invalid username"
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/register -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
check "400" "$CODE"

echo "3. Testing POST /register - password too short"
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/register -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RES" | tail -n1)
check "400" "$CODE"

echo "4. Testing POST /register - username exists"
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/register -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
check "409" "$CODE"

echo "5. Testing POST /login - success"
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/login -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c $COOKIE_JAR)
CODE=$(echo "$RES" | tail -n1)
check "200" "$CODE"

echo "6. Testing POST /login - invalid credentials"
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/login -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RES" | tail -n1)
check "401" "$CODE"

echo "7. Testing GET /me - success"
RES=$(curl -s -w "\n%{http_code}" -X GET $BASE/me -b $COOKIE_JAR)
CODE=$(echo "$RES" | tail -n1)
check "200" "$CODE"

echo "8. Testing GET /me - no auth"
RES=$(curl -s -w "\n%{http_code}" -X GET $BASE/me)
CODE=$(echo "$RES" | tail -n1)
check "401" "$CODE"

echo "9. Testing PUT /password - success"
RES=$(curl -s -w "\n%{http_code}" -X PUT $BASE/password -H "Content-Type: application/json" -b $COOKIE_JAR -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
check "200" "$CODE"

echo "10. Testing PUT /password - old password wrong"
RES=$(curl -s -w "\n%{http_code}" -X PUT $BASE/password -H "Content-Type: application/json" -b $COOKIE_JAR -d '{"old_password": "wrong", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
check "401" "$CODE"

echo "11. Testing PUT /password - new password too short"
RES=$(curl -s -w "\n%{http_code}" -X PUT $BASE/password -H "Content-Type: application/json" -b $COOKIE_JAR -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RES" | tail -n1)
check "400" "$CODE"

echo "12. Testing POST /todos - success"
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/todos -H "Content-Type: application/json" -b $COOKIE_JAR -d '{"title": "My first todo", "description": "Do this"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
check "201" "$CODE"
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
echo "Created todo ID: $TODO_ID"

echo "13. Testing POST /todos - missing title"
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/todos -H "Content-Type: application/json" -b $COOKIE_JAR -d '{"description": "No title"}')
CODE=$(echo "$RES" | tail -n1)
check "400" "$CODE"

echo "14. Testing GET /todos - success"
RES=$(curl -s -w "\n%{http_code}" -X GET $BASE/todos -b $COOKIE_JAR)
CODE=$(echo "$RES" | tail -n1)
check "200" "$CODE"

echo "15. Testing GET /todos/:id - success"
RES=$(curl -s -w "\n%{http_code}" -X GET $BASE/todos/$TODO_ID -b $COOKIE_JAR)
CODE=$(echo "$RES" | tail -n1)
check "200" "$CODE"

echo "16. Testing GET /todos/:id - not found (other user)"
curl -s -X POST $BASE/register -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "password123"}' > /dev/null
curl -s -X POST $BASE/login -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "password123"}' -c cookies2.txt > /dev/null
RES=$(curl -s -w "\n%{http_code}" -X GET $BASE/todos/$TODO_ID -b cookies2.txt)
CODE=$(echo "$RES" | tail -n1)
check "404" "$CODE"

echo "17. Testing PUT /todos/:id - success"
RES=$(curl -s -w "\n%{http_code}" -X PUT $BASE/todos/$TODO_ID -H "Content-Type: application/json" -b $COOKIE_JAR -d '{"title": "Updated title", "completed": true}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
check "200" "$CODE"
echo "$BODY" | grep -q '"completed":true' && echo "PASS" || { echo "FAIL: completed not true"; kill $SERVER_PID 2>/dev/null || true; exit 1; }

echo "18. Testing PUT /todos/:id - empty title"
RES=$(curl -s -w "\n%{http_code}" -X PUT $BASE/todos/$TODO_ID -H "Content-Type: application/json" -b $COOKIE_JAR -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n1)
check "400" "$CODE"

echo "19. Testing DELETE /todos/:id - success"
RES=$(curl -s -w "\n%{http_code}" -X DELETE $BASE/todos/$TODO_ID -b $COOKIE_JAR)
CODE=$(echo "$RES" | tail -n1)
check "204" "$CODE"

echo "20. Testing DELETE /todos/:id - not found"
RES=$(curl -s -w "\n%{http_code}" -X DELETE $BASE/todos/$TODO_ID -b $COOKIE_JAR)
CODE=$(echo "$RES" | tail -n1)
check "404" "$CODE"

echo "21. Testing POST /logout - success"
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/logout -b $COOKIE_JAR)
CODE=$(echo "$RES" | tail -n1)
check "200" "$CODE"

echo "22. Testing GET /me after logout - should fail"
RES=$(curl -s -w "\n%{http_code}" -X GET $BASE/me -b $COOKIE_JAR)
CODE=$(echo "$RES" | tail -n1)
check "401" "$CODE"

echo "All tests passed!"
kill $SERVER_PID 2>/dev/null || true
rm -f cookies.txt cookies2.txt
