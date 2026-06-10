#!/bin/sh
set -eu
# choose a likely-free port
BASE=8500
PORT=$((BASE + ($$ % 1000)))
./run.sh --port "$PORT" &
PID=$!
cleanup() {
  kill $PID 2>/dev/null || true
}
trap cleanup EXIT INT TERM
base="http://127.0.0.1:$PORT"
# wait for server ready
for i in $(seq 1 100); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$base/me" || true)
  if [ "$code" != "000" ]; then
    break
  fi
  sleep 0.05
done

echo "Register user"
code=$(curl -s -o /tmp/out_reg.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/register")
cat /tmp/out_reg.json
[ "$code" = "201" ] || (echo "register failed $code"; exit 1)

# duplicate username
code=$(curl -s -o /tmp/out_dup.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/register")
[ "$code" = "409" ] || (echo "dup register failed $code"; cat /tmp/out_dup.json; exit 1)

echo "Login"
code=$(curl -i -s -o /tmp/out_login_full.txt -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/login")
[ "$code" = "200" ] || (echo "login failed $code"; cat /tmp/out_login_full.txt; exit 1)
sid=$(grep -i "Set-Cookie: session_id=" /tmp/out_login_full.txt | sed -E 's/.*session_id=([^;]+).*/\1/' | tr -d '\r\n')
[ -n "$sid" ] || (echo "no session id"; cat /tmp/out_login_full.txt; exit 1)

# GET /me unauthorized
code=$(curl -s -o /tmp/out_me_unauth.json -w "%{http_code}" "$base/me")
[ "$code" = "401" ] || (echo "me unauth failed $code"; cat /tmp/out_me_unauth.json; exit 1)

# GET /me authorized
code=$(curl -s -o /tmp/out_me.json -w "%{http_code}" --cookie "session_id=$sid" "$base/me")
[ "$code" = "200" ] || (echo "me failed $code"; cat /tmp/out_me.json; exit 1)

# Change password wrong old
code=$(curl -s -o /tmp/out_pw_bad.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword123"}' --cookie "session_id=$sid" -X PUT "$base/password")
[ "$code" = "401" ] || (echo "pw bad failed $code"; cat /tmp/out_pw_bad.json; exit 1)

# Change password too short
code=$(curl -s -o /tmp/out_pw_short.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' --cookie "session_id=$sid" -X PUT "$base/password")
[ "$code" = "400" ] || (echo "pw short failed $code"; cat /tmp/out_pw_short.json; exit 1)

# Change password ok
code=$(curl -s -o /tmp/out_pw_ok.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}' --cookie "session_id=$sid" -X PUT "$base/password")
[ "$code" = "200" ] || (echo "pw ok failed $code"; cat /tmp/out_pw_ok.json; exit 1)

# Create todo missing title
code=$(curl -s -o /tmp/out_todo_bad.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"description":"desc"}' --cookie "session_id=$sid" "$base/todos")
[ "$code" = "400" ] || (echo "todo bad failed $code"; cat /tmp/out_todo_bad.json; exit 1)

# Create todo ok
code=$(curl -s -o /tmp/out_todo1.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"First"}' --cookie "session_id=$sid" "$base/todos")
[ "$code" = "201" ] || (echo "todo1 failed $code"; cat /tmp/out_todo1.json; exit 1)

# List todos
code=$(curl -s -o /tmp/out_todos.json -w "%{http_code}" --cookie "session_id=$sid" "$base/todos")
[ "$code" = "200" ] || (echo "list todos failed $code"; cat /tmp/out_todos.json; exit 1)

id1=$(jq -r '.[0].id' /tmp/out_todos.json)
[ "$id1" != "null" ] || (echo "jq failed"; exit 1)

# Get todo by id
code=$(curl -s -o /tmp/out_todo_get.json -w "%{http_code}" --cookie "session_id=$sid" "$base/todos/$id1")
[ "$code" = "200" ] || (echo "get todo failed $code"; cat /tmp/out_todo_get.json; exit 1)

# Update todo partial
code=$(curl -s -o /tmp/out_todo_upd.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"completed":true}' --cookie "session_id=$sid" -X PUT "$base/todos/$id1")
[ "$code" = "200" ] || (echo "update todo failed $code"; cat /tmp/out_todo_upd.json; exit 1)

# Delete todo
code=$(curl -s -o /tmp/out_todo_del_body.txt -w "%{http_code}" --cookie "session_id=$sid" -X DELETE "$base/todos/$id1")
[ "$code" = "204" ] || (echo "delete todo failed $code"; cat /tmp/out_todo_del_body.txt; exit 1)

# Should be 404 after deletion
code=$(curl -s -o /tmp/out_todo_get2.json -w "%{http_code}" --cookie "session_id=$sid" "$base/todos/$id1")
[ "$code" = "404" ] || (echo "get deleted todo failed $code"; cat /tmp/out_todo_get2.json; exit 1)

# Logout
code=$(curl -s -o /tmp/out_logout.json -w "%{http_code}" --cookie "session_id=$sid" -X POST "$base/logout")
[ "$code" = "200" ] || (echo "logout failed $code"; cat /tmp/out_logout.json; exit 1)

# Requests with same cookie should be 401 now
code=$(curl -s -o /tmp/out_me_post_logout.json -w "%{http_code}" --cookie "session_id=$sid" "$base/me")
[ "$code" = "401" ] || (echo "post logout still auth $code"; cat /tmp/out_me_post_logout.json; exit 1)

echo "All tests passed on port $PORT"