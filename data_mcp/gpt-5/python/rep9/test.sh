#!/bin/sh
set -eu
PORT=$(python3 - <<'PY'
import random
print(random.randint(20000,40000))
PY
)
SERVER_PID=

tmpfile() { mktemp /tmp/todoapi.XXXXXX; }

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill $SERVER_PID || true
    wait $SERVER_PID || true
  fi
}
trap cleanup EXIT INT TERM

./run.sh --port $PORT &
SERVER_PID=$!
# Wait for server
for i in $(seq 1 100); do
  if curl -s -o /dev/null http://127.0.0.1:$PORT/me; then
    break
  fi
  sleep 0.1
done

base=http://127.0.0.1:$PORT

fail() { echo "TEST FAILED: $1" >&2; exit 1; }

# 1. Register
body=$(tmpfile)
code=$(curl -s -o "$body" -w "%{http_code}" -X POST -H 'Content-Type: application/json' \
  -d '{"username":"alice_1","password":"password123"}' $base/register)
[ "$code" = "201" ] || fail "Register code $code body $(cat "$body")"
uid=$(python3 - "$body" <<'PY'
import sys,json
print(json.load(open(sys.argv[1]))['id'])
PY
)
[ -n "$uid" ] || fail "No user id"

# 2. Login
headers=$(tmpfile)
body=$(tmpfile)
code=$(curl -s -D "$headers" -o "$body" -w "%{http_code}" -X POST -H 'Content-Type: application/json' \
  -d '{"username":"alice_1","password":"password123"}' $base/login)
[ "$code" = "200" ] || fail "Login code $code body $(cat "$body")"
cookie=$(awk -F': ' '/^Set-Cookie:/{print $2}' "$headers" | head -n1 | tr -d '\r')
[ -n "$cookie" ] || fail "No Set-Cookie"
session_cookie=$(printf "%s" "$cookie" | awk -F';' '{print $1}')

# 3. /me
body=$(tmpfile)
code=$(curl -s -o "$body" -w "%{http_code}" -b "$session_cookie" $base/me)
[ "$code" = "200" ] || fail "/me code $code body $(cat "$body")"
username=$(python3 - "$body" <<'PY'
import sys,json
print(json.load(open(sys.argv[1]))['username'])
PY
)
[ "$username" = "alice_1" ] || fail "/me wrong username $username"

# 4. Create todo
body=$(tmpfile)
code=$(curl -s -o "$body" -w "%{http_code}" -X POST -H 'Content-Type: application/json' -b "$session_cookie" \
  -d '{"title":"Task A","description":"desc"}' $base/todos)
[ "$code" = "201" ] || fail "Create todo code $code body $(cat "$body")"
todo_id=$(python3 - "$body" <<'PY'
import sys,json
print(json.load(open(sys.argv[1]))['id'])
PY
)

# 5. List todos
body=$(tmpfile)
code=$(curl -s -o "$body" -w "%{http_code}" -b "$session_cookie" $base/todos)
[ "$code" = "200" ] || fail "List code $code body $(cat "$body")"
count=$(python3 - "$body" <<'PY'
import sys, json
print(len(json.load(open(sys.argv[1]))))
PY
)
[ "$count" = "1" ] || fail "List count $count"

# 6. Get todo
body=$(tmpfile)
code=$(curl -s -o "$body" -w "%{http_code}" -b "$session_cookie" $base/todos/$todo_id)
[ "$code" = "200" ] || fail "Get todo code $code body $(cat "$body")"
get_id=$(python3 - "$body" <<'PY'
import sys,json
print(json.load(open(sys.argv[1]))['id'])
PY
)
[ "$get_id" = "$todo_id" ] || fail "Get todo id mismatch"

# 7. Update todo (partial)
body=$(tmpfile)
code=$(curl -s -o "$body" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -b "$session_cookie" \
  -d '{"completed": true}' $base/todos/$todo_id)
[ "$code" = "200" ] || fail "Update code $code body $(cat "$body")"

# 8. Delete todo
code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -b "$session_cookie" $base/todos/$todo_id)
[ "$code" = "204" ] || fail "Delete code $code"

# 9. Confirm not found after delete
code=$(curl -s -o /dev/null -w "%{http_code}" -b "$session_cookie" $base/todos/$todo_id)
[ "$code" = "404" ] || fail "Get after delete code $code"

# 10. Change password
body=$(tmpfile)
code=$(curl -s -o "$body" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -b "$session_cookie" \
  -d '{"old_password":"password123","new_password":"newpass123"}' $base/password)
[ "$code" = "200" ] || fail "Password change code $code body $(cat "$body")"

# 11. Logout
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -b "$session_cookie" $base/logout)
[ "$code" = "200" ] || fail "Logout code $code"
# Check authenticated endpoint now yields 401
code=$(curl -s -o /dev/null -w "%{http_code}" -b "$session_cookie" $base/me)
[ "$code" = "401" ] || fail "Expected 401 after logout, got $code"

echo "All tests passed"