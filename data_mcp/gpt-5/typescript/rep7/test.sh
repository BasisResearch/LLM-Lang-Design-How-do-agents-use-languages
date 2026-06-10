#!/usr/bin/env bash
set -euo pipefail
PORT=3456
./run.sh --port $PORT &
PID=$!
# Wait for server
for i in {1..50}; do
  if curl -sSf http://127.0.0.1:$PORT/me -H 'Accept: application/json' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1 || true
done

base=http://127.0.0.1:$PORT

jq() { command jq -r "$@"; }

status() { echo "== $1"; }

# All responses should be JSON content-type (except delete 204)

status "Register user"
reg=$(curl -sS -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
[[ $(echo "$reg" | command jq -r .username) == "alice" ]]

status "Login user"
login_headers=$(mktemp)
login_body=$(curl -sS -D "$login_headers" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
[[ $(echo "$login_body" | command jq -r .username) == "alice" ]]
session=$(grep -i '^Set-Cookie:' "$login_headers" | sed -n 's/Set-Cookie: \s*session_id=\([^;]*\).*/\1/p' | tr -d '\r')
if [[ -z "$session" ]]; then echo "No session cookie"; kill $PID; exit 1; fi
cookie="session_id=$session"

status "Get /me"
me=$(curl -sS "$base/me" -H "Cookie: $cookie")
[[ $(echo "$me" | command jq -r .username) == "alice" ]]

status "Change password with wrong old"
code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$code" == "401" ]]

status "Change password with short new"
code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"password123","new_password":"short"}')
[[ "$code" == "400" ]]

status "Change password success"
code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]]

status "Create todo 1"
t1=$(curl -sS -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"title":"Task 1","description":"First"}')
[[ $(echo "$t1" | command jq -r .title) == "Task 1" ]]

status "Create todo 2"
t2=$(curl -sS -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"title":"Task 2"}')
[[ $(echo "$t2" | command jq -r .description) == "" ]]

status "List todos"
list=$(curl -sS "$base/todos" -H "Cookie: $cookie")
count=$(echo "$list" | command jq 'length')
[[ "$count" -ge 2 ]]

id1=$(echo "$t1" | command jq -r .id)

status "Get todo by id"
get1=$(curl -sS "$base/todos/$id1" -H "Cookie: $cookie")
[[ $(echo "$get1" | command jq -r .title) == "Task 1" ]]

status "Update todo partial"
upd=$(curl -sS -X PUT "$base/todos/$id1" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"completed":true}')
[[ $(echo "$upd" | command jq -r .completed) == "true" ]]

status "Delete todo"
code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$base/todos/$id1" -H "Cookie: $cookie")
[[ "$code" == "204" ]]

status "Logout"
code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$base/logout" -H "Cookie: $cookie")
[[ "$code" == "200" ]]

status "Access after logout should 401"
code=$(curl -sS -o /dev/null -w "%{http_code}" "$base/me" -H "Cookie: $cookie")
[[ "$code" == "401" ]]

# Cleanup
kill $PID
wait $PID 2>/dev/null || true

echo "All tests passed"
