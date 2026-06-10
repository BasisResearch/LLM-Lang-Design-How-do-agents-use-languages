#!/bin/bash
set -e

PORT=8081
echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 2

BASE_URL="http://localhost:$PORT"

echo "1. Register user"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "201" ]; then
  echo "FAIL: Register expected 201, got $CODE. Body: $BODY"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: Register"

echo "2. Register duplicate user"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "409" ]; then
  echo "FAIL: Duplicate register expected 409, got $CODE. Body: $BODY"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: Duplicate register"

echo "3. Login"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: Login expected 200, got $CODE. Body: $BODY"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: Login"

echo "4. GET /me"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ] || ! echo "$BODY" | grep -q '"username":"testuser"'; then
  echo "FAIL: GET /me expected 200 with testuser, got $CODE. Body: $BODY"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: GET /me"

echo "5. Invalid auth"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: Invalid auth expected 401, got $CODE. Body: $BODY"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: Invalid auth"

echo "6. POST /todos"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title":"My Todo","description":"A test"}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "201" ] || ! echo "$BODY" | grep -q '"title":"My Todo"'; then
  echo "FAIL: POST /todos expected 201, got $CODE. Body: $BODY"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: POST /todos"

echo "7. GET /todos"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ] || ! echo "$BODY" | grep -q '"title":"My Todo"'; then
  echo "FAIL: GET /todos expected 200, got $CODE. Body: $BODY"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: GET /todos"

echo "8. GET /todos/1"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/1" -b cookies.txt)
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: GET /todos/1 expected 200, got $CODE. Body: $BODY"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: GET /todos/1"

echo "9. PUT /todos/1"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -b cookies.txt -d '{"completed":true}')
BODY=$(echo "$RESP" | head -n 1)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ] || ! echo "$BODY" | grep -q '"completed":true'; then
  echo "FAIL: PUT /todos/1 expected 200 with completed:true, got $CODE. Body: $BODY"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: PUT /todos/1"

echo "10. PUT /password"
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: PUT /password expected 200, got $CODE"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: PUT /password"

echo "11. Login with new password"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' -c cookies2.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: Login with new password expected 200, got $CODE"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: Login with new password"

echo "12. DELETE /todos/1"
RESP=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/1" -b cookies2.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "204" ]; then
  echo "FAIL: DELETE /todos/1 expected 204, got $CODE"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: DELETE /todos/1"

echo "13. GET /todos/1 (deleted)"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/1" -b cookies2.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "404" ]; then
  echo "FAIL: GET /todos/1 (deleted) expected 404, got $CODE"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: GET /todos/1 (deleted)"

echo "14. POST /logout"
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies2.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "200" ]; then
  echo "FAIL: POST /logout expected 200, got $CODE"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: POST /logout"

echo "15. GET /me after logout"
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies2.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "401" ]; then
  echo "FAIL: GET /me after logout expected 401, got $CODE"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: GET /me after logout"

echo "16. POST /todos with empty title"
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' -c cookies3.txt > /dev/null
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies3.txt -d '{"title":""}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: POST /todos with empty title expected 400, got $CODE"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: POST /todos with empty title"

echo "17. PUT /todos/1 with empty title"
curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies3.txt -d '{"title":"Test Todo"}' > /dev/null
RESP=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/2" -H "Content-Type: application/json" -b cookies3.txt -d '{"title":""}')
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "400" ]; then
  echo "FAIL: PUT /todos/1 with empty title expected 400, got $CODE"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: PUT /todos/1 with empty title"

echo "18. GET /todos/:id for other user"
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"user2","password":"password123"}' > /dev/null
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"user2","password":"password123"}' -c cookies4.txt > /dev/null
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/2" -b cookies4.txt)
CODE=$(echo "$RESP" | tail -n 1)
if [ "$CODE" != "404" ]; then
  echo "FAIL: GET /todos/:id for other user expected 404, got $CODE"
  kill $SERVER_PID
  exit 1
fi
echo "PASS: GET /todos/:id for other user"

kill $SERVER_PID
rm -f cookies.txt cookies2.txt cookies3.txt cookies4.txt
echo "ALL TESTS PASSED!"
