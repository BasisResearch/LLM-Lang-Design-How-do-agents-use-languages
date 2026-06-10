#!/bin/bash
set -euo pipefail
PORT=${PORT:-18080}
ROOT=$(pwd)

./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Wait for server
for i in {1..50}; do
  if curl -sS http://127.0.0.1:$PORT/ >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

fail() { echo "TEST FAILED: $1" >&2; exit 1; }

echo "Register user1"
status=$(curl -sS -o /tmp/reg1.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' http://127.0.0.1:$PORT/register)
[[ "$status" == "201" ]] || fail "register user1 status $status"
USER1_ID=$(grep -o '"id":[0-9]\+' /tmp/reg1.json | head -n1 | cut -d: -f2)
[[ -n "$USER1_ID" ]] || fail "user1 id parse"

echo "Register duplicate user1"
status=$(curl -sS -o /tmp/regdup.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' http://127.0.0.1:$PORT/register)
[[ "$status" == "409" ]] || fail "duplicate register expected 409 got $status"

echo "Login wrong password"
status=$(curl -sS -o /tmp/login_bad.json -w "%{http_code}" -c /tmp/cookies1.txt -H 'Content-Type: application/json' -d '{"username":"user_one","password":"badpass"}' http://127.0.0.1:$PORT/login)
[[ "$status" == "401" ]] || fail "login wrong expected 401 got $status"

echo "Login user1 good"
status=$(curl -sS -D /tmp/login_headers.txt -o /tmp/login_ok.json -w "%{http_code}" -c /tmp/cookies1.txt -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' http://127.0.0.1:$PORT/login)
[[ "$status" == "200" ]] || fail "login good status $status"
grep -i '^Set-Cookie: .*session_id=' /tmp/login_headers.txt >/dev/null || fail "Set-Cookie missing"

echo "GET /me"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/me.json -w "%{http_code}" http://127.0.0.1:$PORT/me)
[[ "$status" == "200" ]] || fail "/me status $status"

echo "PUT /password wrong old"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/pw_bad.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"nope","new_password":"newpassword123"}' http://127.0.0.1:$PORT/password)
[[ "$status" == "401" ]] || fail "password wrong expected 401 got $status"

echo "PUT /password good"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/pw_ok.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}' http://127.0.0.1:$PORT/password)
[[ "$status" == "200" ]] || fail "password change expected 200 got $status"

echo "POST /logout"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/logout.json -w "%{http_code}" -X POST http://127.0.0.1:$PORT/logout)
[[ "$status" == "200" ]] || fail "logout expected 200 got $status"

echo "Access after logout should 401"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/me_unauth.json -w "%{http_code}" http://127.0.0.1:$PORT/me)
[[ "$status" == "401" ]] || fail "expected 401 after logout got $status"

echo "Login again with new password"
status=$(curl -sS -o /tmp/login2.json -w "%{http_code}" -c /tmp/cookies1.txt -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpassword123"}' http://127.0.0.1:$PORT/login)
[[ "$status" == "200" ]] || fail "login2 expected 200 got $status"

echo "GET /todos empty"
resp=$(curl -sS -b /tmp/cookies1.txt http://127.0.0.1:$PORT/todos)
[[ "$resp" == '[]' ]] || echo "Non-empty todos initially: $resp"


echo "POST /todos missing title"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/todo_bad.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"description":"test"}' http://127.0.0.1:$PORT/todos)
[[ "$status" == "400" ]] || fail "todo missing title expected 400 got $status"

echo "Create todo1"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/todo1.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"First"}' http://127.0.0.1:$PORT/todos)
[[ "$status" == "201" ]] || fail "todo1 create expected 201 got $status"
TODO1_ID=$(grep -o '"id":[0-9]\+' /tmp/todo1.json | head -n1 | cut -d: -f2)


echo "Create todo2"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/todo2.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"Task 2","description":"Second"}' http://127.0.0.1:$PORT/todos)
[[ "$status" == "201" ]] || fail "todo2 create expected 201 got $status"
TODO2_ID=$(grep -o '"id":[0-9]\+' /tmp/todo2.json | head -n1 | cut -d: -f2)


echo "List todos"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/todos_list.json -w "%{http_code}" http://127.0.0.1:$PORT/todos)
[[ "$status" == "200" ]] || fail "list todos expected 200 got $status"
COUNT=$(grep -o '"id":' /tmp/todos_list.json | wc -l | tr -d ' ')
[[ "$COUNT" -ge 2 ]] || fail "expected at least 2 todos got $COUNT"

echo "Get todo1"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/todo1_get.json -w "%{http_code}" http://127.0.0.1:$PORT/todos/$TODO1_ID)
[[ "$status" == "200" ]] || fail "get todo1 expected 200 got $status"

echo "Update todo1 partial"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/todo1_upd.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"description":"Updated","completed":true}' http://127.0.0.1:$PORT/todos/$TODO1_ID)
[[ "$status" == "200" ]] || fail "update todo1 expected 200 got $status"

echo "Update todo1 bad title"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/todo1_upd_bad.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"title":""}' http://127.0.0.1:$PORT/todos/$TODO1_ID)
[[ "$status" == "400" ]] || fail "update bad title expected 400 got $status"

echo "Delete todo2"
status=$(curl -sS -D /tmp/del_headers.txt -o /tmp/todo2_del.out -w "%{http_code}" -X DELETE -b /tmp/cookies1.txt http://127.0.0.1:$PORT/todos/$TODO2_ID)
[[ "$status" == "204" ]] || fail "delete todo2 expected 204 got $status"
if [[ -s /tmp/todo2_del.out ]]; then fail "DELETE returned body"; fi


echo "Get deleted todo2 should 404"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/todo2_get_404.json -w "%{http_code}" http://127.0.0.1:$PORT/todos/$TODO2_ID)
[[ "$status" == "404" ]] || fail "expected 404 for deleted todo"

# Create another user and a todo, ensure 404 when accessing from user1

echo "Register user2"
status=$(curl -sS -o /tmp/reg2.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password456"}' http://127.0.0.1:$PORT/register)
[[ "$status" == "201" ]] || fail "register user2"

echo "Login user2"
status=$(curl -sS -o /tmp/login_user2.json -w "%{http_code}" -c /tmp/cookies2.txt -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password456"}' http://127.0.0.1:$PORT/login)
[[ "$status" == "200" ]] || fail "login user2"

echo "User2 creates todo"
status=$(curl -sS -b /tmp/cookies2.txt -o /tmp/todo_u2.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"U2 Task","description":"u2"}' http://127.0.0.1:$PORT/todos)
[[ "$status" == "201" ]] || fail "user2 create todo"
U2_ID=$(grep -o '"id":[0-9]\+' /tmp/todo_u2.json | head -n1 | cut -d: -f2)

echo "User1 cannot access user2 todo (404)"
status=$(curl -sS -b /tmp/cookies1.txt -o /tmp/u2get_404.json -w "%{http_code}" http://127.0.0.1:$PORT/todos/$U2_ID)
[[ "$status" == "404" ]] || fail "expected 404 for other user's todo"

echo "All tests passed"
