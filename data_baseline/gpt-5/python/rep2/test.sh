#!/bin/sh
set -e
PORT=18080
./run.sh --port $PORT &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT
sleep 0.5

jget() { curl -sS -i -X GET "$1" -H 'Accept: application/json'; }
jpost() { curl -sS -i -X POST "$1" -H 'Content-Type: application/json' -d "$2"; }
jput() { curl -sS -i -X PUT "$1" -H 'Content-Type: application/json' -d "$2"; }
jdel() { curl -sS -i -X DELETE "$1"; }

BASE="http://127.0.0.1:$PORT"

echo "Register user1"
RES=$(jpost "$BASE/register" '{"username":"user1","password":"password123"}')
echo "$RES" | sed -n '1,5p'
echo "$RES" | grep -q " 201 "

echo "Duplicate register should 409"
RES=$(jpost "$BASE/register" '{"username":"user1","password":"password123"}')
echo "$RES" | grep -q " 409 "

echo "Login user1"
RES=$(jpost "$BASE/login" '{"username":"user1","password":"password123"}')
echo "$RES" | sed -n '1,6p'
echo "$RES" | grep -q " 200 "
COOKIE=$(echo "$RES" | awk -F': ' '/Set-Cookie:/ {print $2}' | tr -d '\r' | head -n1 | cut -d';' -f1)
[ -n "$COOKIE" ] || { echo "Missing cookie"; exit 1; }

echo "Get /me with cookie"
RES=$(curl -sS -i -X GET "$BASE/me" -H 'Accept: application/json' -H "Cookie: $COOKIE")
echo "$RES" | grep -q " 200 "

echo "List todos (empty)"
RES=$(curl -sS -i -X GET "$BASE/todos" -H 'Accept: application/json' -H "Cookie: $COOKIE")
echo "$RES" | grep -q " 200 "

echo "Create todo"
RES=$(curl -sS -i -X POST "$BASE/todos" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":"Task 1","description":"Desc"}')
echo "$RES" | grep -q " 201 "
TID=$(echo "$RES" | sed -n '/\r$/q; p' | tail -n1 | jq -r '.id' 2>/dev/null || true)
if [ -z "$TID" ] || [ "$TID" = "null" ]; then
  TID=$(echo "$RES" | awk 'END{print}' | sed 's/.*"id":[ ]*\([0-9][0-9]*\).*/\1/')
fi
[ -n "$TID" ] || { echo "Failed to parse todo id"; exit 1; }

echo "Get todo by id"
RES=$(curl -sS -i -X GET "$BASE/todos/$TID" -H 'Accept: application/json' -H "Cookie: $COOKIE")
echo "$RES" | grep -q " 200 "

echo "Update todo partial"
RES=$(curl -sS -i -X PUT "$BASE/todos/$TID" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"completed": true}')
echo "$RES" | grep -q " 200 "

echo "Delete todo"
RES=$(curl -sS -i -X DELETE "$BASE/todos/$TID" -H "Cookie: $COOKIE")
echo "$RES" | grep -q " 204 "

echo "Password change"
RES=$(curl -sS -i -X PUT "$BASE/password" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"password123","new_password":"newpassword456"}')
echo "$RES" | grep -q " 200 "

echo "Logout"
RES=$(curl -sS -i -X POST "$BASE/logout" -H "Cookie: $COOKIE")
echo "$RES" | grep -q " 200 "

echo "Access with old cookie should 401"
RES=$(curl -sS -i -X GET "$BASE/me" -H 'Accept: application/json' -H "Cookie: $COOKIE")
echo "$RES" | grep -q " 401 "

# Login with new password
RES=$(jpost "$BASE/login" '{"username":"user1","password":"newpassword456"}')
echo "$RES" | grep -q " 200 "
NEWCOOKIE=$(echo "$RES" | awk -F': ' '/Set-Cookie:/ {print $2}' | tr -d '\r' | head -n1 | cut -d';' -f1)
[ -n "$NEWCOOKIE" ] || { echo "Missing new cookie"; exit 1; }

# Create second user and ensure isolation
RES=$(jpost "$BASE/register" '{"username":"user2","password":"password123"}')
echo "$RES" | grep -q " 201 "
RES=$(jpost "$BASE/login" '{"username":"user2","password":"password123"}')
COOK2=$(echo "$RES" | awk -F': ' '/Set-Cookie:/ {print $2}' | tr -d '\r' | head -n1 | cut -d';' -f1)

# user2 cannot access user1's nonexistent id should 404
RES=$(curl -sS -i -X GET "$BASE/todos/9999" -H 'Accept: application/json' -H "Cookie: $COOK2")
echo "$RES" | grep -q " 404 "

echo "All tests passed"