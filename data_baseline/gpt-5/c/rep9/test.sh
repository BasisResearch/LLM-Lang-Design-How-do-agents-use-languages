#!/usr/bin/env bash
set -euo pipefail

PORT=19081

# Ensure curl and jq exist
if ! command -v curl >/dev/null 2>&1 || ! command_v=$(command -v jq); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq || true
  apt-get install -y -qq curl jq || true
fi

# Start server
./run.sh --port "$PORT" >/tmp/todo_server.log 2>&1 &
SRV_PID=$!
echo "Server PID: $SRV_PID"
# wait until port open
for i in {1..50}; do
  if curl -sS localhost:$PORT/doesnotexist -o /dev/null -w '%{http_code}' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; kill $SRV_PID || true; exit 1; }

echo "Register user1"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' -X POST http://127.0.0.1:$PORT/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"user1","password":"password123"}')
[[ "$code" == "201" ]] || fail "register user1"
uid1=$(jq -r '.id' /tmp/out.json)
[[ "$uid1" == "1" ]] || fail "user1 id"
pass "register user1"

echo "Duplicate register"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' -X POST http://127.0.0.1:$PORT/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"user1","password":"password123"}')
[[ "$code" == "409" ]] || fail "duplicate register"
pass "duplicate register"

echo "Login user1"
code=$(curl -s -D /tmp/headers.txt -o /tmp/out.json -w '%{http_code}' -X POST http://127.0.0.1:$PORT/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"user1","password":"password123"}')
[[ "$code" == "200" ]] || { cat /tmp/out.json; fail "login user1 code $code"; }
session=$(grep -i '^Set-Cookie:' /tmp/headers.txt | tr -d '\r' | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | head -n1)
[[ -n "$session" ]] || fail "no session cookie"
pass "login user1"

echo "GET /me"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' http://127.0.0.1:$PORT/me \
  -H "Cookie: session_id=$session")
[[ "$code" == "200" ]] || fail "me"
pass "me"

echo "Change password"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' -X PUT http://127.0.0.1:$PORT/password \
  -H 'Content-Type: application/json' -H "Cookie: session_id=$session" \
  -d '{"old_password":"password123","new_password":"newpassword456"}')
[[ "$code" == "200" ]] || { cat /tmp/out.json; fail "password change"; }
pass "password change"

echo "Logout"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' -X POST http://127.0.0.1:$PORT/logout \
  -H "Cookie: session_id=$session")
[[ "$code" == "200" ]] || fail "logout"
pass "logout"

echo "Access after logout should 401"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' http://127.0.0.1:$PORT/me \
  -H "Cookie: session_id=$session")
[[ "$code" == "401" ]] || fail "post-logout 401"
pass "post-logout 401"

echo "Login with old password should fail"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' -X POST http://127.0.0.1:$PORT/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"user1","password":"password123"}')
[[ "$code" == "401" ]] || fail "login old password should 401"
pass "login old password"

echo "Login with new password"
code=$(curl -s -D /tmp/headers2.txt -o /tmp/out.json -w '%{http_code}' -X POST http://127.0.0.1:$PORT/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"user1","password":"newpassword456"}')
[[ "$code" == "200" ]] || fail "login new password"
session=$(grep -i '^Set-Cookie:' /tmp/headers2.txt | tr -d '\r' | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | head -n1)
[[ -n "$session" ]] || fail "no session cookie2"
pass "login new password"

echo "Create todo 1"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' -X POST http://127.0.0.1:$PORT/todos \
  -H 'Content-Type: application/json' -H "Cookie: session_id=$session" \
  -d '{"title":"Task A","description":"Desc A"}')
[[ "$code" == "201" ]] || { cat /tmp/out.json; fail "create todo1"; }
id1=$(jq -r '.id' /tmp/out.json)
[[ "$id1" == "1" ]] || fail "todo1 id"
pass "create todo1"

echo "Create todo 2"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' -X POST http://127.0.0.1:$PORT/todos \
  -H 'Content-Type: application/json' -H "Cookie: session_id=$session" \
  -d '{"title":"Task B"}')
[[ "$code" == "201" ]] || fail "create todo2"
id2=$(jq -r '.id' /tmp/out.json)
[[ "$id2" == "2" ]] || fail "todo2 id"
pass "create todo2"

echo "List todos"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' http://127.0.0.1:$PORT/todos \
  -H "Cookie: session_id=$session")
[[ "$code" == "200" ]] || fail "list todos"
count=$(jq 'length' /tmp/out.json)
[[ "$count" == "2" ]] || fail "list count"
first=$(jq -r '.[0].id' /tmp/out.json)
[[ "$first" == "1" ]] || fail "order"
pass "list todos"

echo "Get todo 1"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' http://127.0.0.1:$PORT/todos/$id1 \
  -H "Cookie: session_id=$session")
[[ "$code" == "200" ]] || fail "get todo1"
pass "get todo1"

echo "Update todo 1"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' -X PUT http://127.0.0.1:$PORT/todos/$id1 \
  -H 'Content-Type: application/json' -H "Cookie: session_id=$session" \
  -d '{"completed": true, "title": "Task A+"}')
[[ "$code" == "200" ]] || fail "update todo1"
iscomp=$(jq -r '.completed' /tmp/out.json)
[[ "$iscomp" == "true" ]] || fail "completed true"
pass "update todo1"

echo "Delete todo 2"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' -X DELETE http://127.0.0.1:$PORT/todos/$id2 \
  -H "Cookie: session_id=$session")
[[ "$code" == "204" ]] || fail "delete todo2"
pass "delete todo2"

echo "List after delete"
code=$(curl -s -o /tmp/out.json -w '%{http_code}' http://127.0.0.1:$PORT/todos \
  -H "Cookie: session_id=$session")
[[ "$code" == "200" ]] || fail "list after delete"
count=$(jq 'length' /tmp/out.json)
[[ "$count" == "1" ]] || fail "count after delete"
pass "list after delete"

echo "Create user2 and test 404 access to other user's todo"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/register \
  -H 'Content-Type: application/json' -d '{"username":"user2","password":"password123"}')
[[ "$code" == "201" ]] || fail "register user2"
code=$(curl -s -D /tmp/h3.txt -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/login \
  -H 'Content-Type: application/json' -d '{"username":"user2","password":"password123"}')
[[ "$code" == "200" ]] || fail "login user2"
s2=$(grep -i '^Set-Cookie:' /tmp/h3.txt | tr -d '\r' | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | head -n1)
code=$(curl -s -o /tmp/out.json -w '%{http_code}' http://127.0.0.1:$PORT/todos/$id1 -H "Cookie: session_id=$s2")
[[ "$code" == "404" ]] || fail "user2 should get 404 for user1 todo"
pass "user2 404 on other user's todo"

echo "All tests passed"
kill $SRV_PID || true
exit 0
