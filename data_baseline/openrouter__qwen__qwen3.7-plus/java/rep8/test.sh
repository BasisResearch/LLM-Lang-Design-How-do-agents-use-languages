#!/bin/bash
set -e

PORT=8888
BASE_URL="http://localhost:$PORT"

echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 2

cleanup() {
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt cookies2.txt cookies3.txt /tmp/todo1.json
    exit 0
}
trap cleanup EXIT

echo "1. Register user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "201" ] && echo "PASS: Register" || { echo "FAIL"; exit 1; }

echo "2. Register duplicate user"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "409" ] && echo "PASS: Duplicate register" || { echo "FAIL"; exit 1; }

echo "3. Login"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "PASS: Login" || { echo "FAIL"; exit 1; }

echo "4. Get /me"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "PASS: Get /me" || { echo "FAIL"; exit 1; }

echo "5. Create todo"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title":"My Todo","description":"Do this"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ]; then
    echo "FAIL: Create todo expected 201, got $CODE. Body: $BODY"
    exit 1
fi
TODO_ID=$(echo "$BODY" | sed -n 's/.*"id": *\([0-9]*\).*/\1/p')
echo "PASS: Create todo (ID: $TODO_ID)"

echo "6. Get todos"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "PASS: Get todos" || { echo "FAIL: Get todos, got $CODE"; exit 1; }

echo "7. Get single todo"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "PASS: Get single todo" || { echo "FAIL: Get single todo, got $CODE"; exit 1; }

echo "8. Update todo"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -b cookies.txt -H "Content-Type: application/json" -d '{"completed":true}')
CODE=$(echo "$RES" | tail -n1)
BODY_res=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ]; then
    echo "FAIL: Update todo expected 200, got $CODE"
    exit 1
fi
if ! echo "$BODY_res" | grep -q '"completed": *true'; then
    echo "FAIL: Update todo did not set completed to true. Body was: $BODY_res"
    exit 1
fi
echo "PASS: Update todo"

echo "9. Delete todo"
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "204" ] && echo "PASS: Delete todo" || { echo "FAIL: Delete todo, got $CODE"; exit 1; }

echo "10. Change password"
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password":"password123","new_password":"newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "PASS: Change password" || { echo "FAIL: Change password, got $CODE"; exit 1; }

echo "11. Logout"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "PASS: Logout" || { echo "FAIL: Logout, got $CODE"; exit 1; }

echo "12. Get /me after logout (should be 401)"
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "401" ] && echo "PASS: Get /me after logout" || { echo "FAIL: Get /me after logout, got $CODE"; exit 1; }

echo "13. Login with new password"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' -c cookies2.txt)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "200" ] && echo "PASS: Login with new password" || { echo "FAIL: Login with new password, got $CODE"; exit 1; }

echo "14. Create another user and try to access first user's todo (should be 404)"
# Register other user
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"otheruser","password":"password123"}' > /dev/null
# Login as other user to get a valid session cookie
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"otheruser","password":"password123"}' -c cookies3.txt > /dev/null
# Create a todo for other user (just to prove they can create todos)
curl -s -X POST "$BASE_URL/todos" -b cookies3.txt -H "Content-Type: application/json" -d '{"title":"Other Todo"}' > /dev/null
# Create a todo for first user again to have a known ID
curl -s -X POST "$BASE_URL/todos" -b cookies2.txt -H "Content-Type: application/json" -d '{"title":"First User Todo"}' -o /tmp/todo1.json
TODO_ID_1=$(cat /tmp/todo1.json | sed -n 's/.*"id": *\([0-9]*\).*/\1/p')

RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID_1" -b cookies3.txt)
CODE=$(echo "$RES" | tail -n1)
[ "$CODE" == "404" ] && echo "PASS: Access other user's todo returns 404" || { echo "FAIL: Access other user's todo, got $CODE"; exit 1; }

echo "ALL TESTS PASSED!"