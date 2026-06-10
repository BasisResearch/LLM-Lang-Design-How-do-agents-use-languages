#!/bin/sh
set -eu
PORT=8123
if [ $# -ge 2 ] && [ "$1" = "--port" ]; then PORT="$2"; fi
./run.sh --port "$PORT" >/tmp/todo_server_test.log 2>&1 &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
base="http://127.0.0.1:$PORT"
CJ1=$(mktemp)
CJ2=$(mktemp)

request() {
  # args: method path data cookiejar
  m="$1"; p="$2"; d="${3-}"; cj="${4-}"
  if [ -n "$d" ]; then
    curl -sS -w "\n%{http_code}" -o /tmp/resp_body.$$ -D /tmp/resp_hdrs.$$ -X "$m" \
      -H "Content-Type: application/json" --data "$d" -b "$cj" -c "$cj" "$base$p"
  else
    curl -sS -w "\n%{http_code}" -o /tmp/resp_body.$$ -D /tmp/resp_hdrs.$$ -X "$m" \
      -b "$cj" -c "$cj" "$base$p"
  fi
}

assert_code() { # expected actual context
  if [ "$1" != "$2" ]; then
    echo "Test failed ($3): expected $1 got $2" >&2
    echo "Response headers:" >&2; cat /tmp/resp_hdrs.$$ >&2
    echo "Response body:" >&2; cat /tmp/resp_body.$$ >&2
    exit 1
  fi
}

# Unauthorized /me
code=$(request GET /me '' "$CJ1" | tail -n1); assert_code 401 "$code" "GET /me unauthorized"

echo Register user1
code=$(request POST /register '{"username":"alice_1","password":"password123"}' "$CJ1" | tail -n1); assert_code 201 "$code" "register user1"

# Duplicate username
code=$(request POST /register '{"username":"alice_1","password":"password123"}' "$CJ1" | tail -n1); assert_code 409 "$code" "duplicate username"

# Bad login
code=$(request POST /login '{"username":"alice_1","password":"wrongpass"}' "$CJ1" | tail -n1); assert_code 401 "$code" "bad login"

# Good login (user1)
code=$(request POST /login '{"username":"alice_1","password":"password123"}' "$CJ1" | tail -n1); assert_code 200 "$code" "good login"
# Check Set-Cookie present
if ! grep -qi '^Set-Cookie: session_id=' /tmp/resp_hdrs.$$; then echo "Missing Set-Cookie"; exit 1; fi

# GET /me
code=$(request GET /me '' "$CJ1" | tail -n1); assert_code 200 "$code" "me after login"

# Change password wrong old
code=$(request PUT /password '{"old_password":"bad","new_password":"newpass123"}' "$CJ1" | tail -n1); assert_code 401 "$code" "password wrong old"

# Change password ok
code=$(request PUT /password '{"old_password":"password123","new_password":"newpass123"}' "$CJ1" | tail -n1); assert_code 200 "$code" "password change ok"

# Old password fails
code=$(request POST /login '{"username":"alice_1","password":"password123"}' "$CJ1" | tail -n1); assert_code 401 "$code" "old password should fail"

# New password works (refresh cookie)
code=$(request POST /login '{"username":"alice_1","password":"newpass123"}' "$CJ1" | tail -n1); assert_code 200 "$code" "new password login"

# GET /todos empty
code=$(request GET /todos '' "$CJ1" | tail -n1); assert_code 200 "$code" "todos list empty"
body=$(cat /tmp/resp_body.$$)
[ "$body" = "[]" ] || { echo "Expected empty todos list"; cat /tmp/resp_body.$$; exit 1; }

# Create todo missing title
code=$(request POST /todos '{"description":"x"}' "$CJ1" | tail -n1); assert_code 400 "$code" "create todo missing title"

# Create todo1
code=$(request POST /todos '{"title":"t1","description":"d1"}' "$CJ1" | tail -n1); assert_code 201 "$code" "create todo1"
T1_ID=$(sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' /tmp/resp_body.$$)
[ -n "$T1_ID" ] || { echo "Failed to parse todo1 id"; cat /tmp/resp_body.$$; exit 1; }

# Create todo2
code=$(request POST /todos '{"title":"t2"}' "$CJ1" | tail -n1); assert_code 201 "$code" "create todo2"
T2_ID=$(sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' /tmp/resp_body.$$)

# List todos (should be 2)
code=$(request GET /todos '' "$CJ1" | tail -n1); assert_code 200 "$code" "list 2 todos"
items=$(sed 's/[\[\]]//g' /tmp/resp_body.$$ | tr -d '\n ')
if [ -z "$items" ]; then n=0; else n=$(( $(printf "%s" "$items" | tr -cd '{' | wc -c) )); fi
[ "$n" -eq 2 ] || { echo "Expected 2 todos, got $n"; cat /tmp/resp_body.$$; exit 1; }

# Get todo1
code=$(request GET /todos/$T1_ID '' "$CJ1" | tail -n1); assert_code 200 "$code" "get todo1"

# Update todo1 invalid empty title
code=$(request PUT /todos/$T1_ID '{"title":""}' "$CJ1" | tail -n1); assert_code 400 "$code" "update empty title"

# Partial update completed true and description
code=$(request PUT /todos/$T1_ID '{"completed":true,"description":"updated"}' "$CJ1" | tail -n1); assert_code 200 "$code" "update partial"

# Delete todo2
code=$(request DELETE /todos/$T2_ID '' "$CJ1" | tail -n1); assert_code 204 "$code" "delete todo2"

# Get deleted should 404
code=$(request GET /todos/$T2_ID '' "$CJ1" | tail -n1); assert_code 404 "$code" "get deleted"

# Create user2 and todo
code=$(request POST /register '{"username":"bob_2","password":"password123"}' "$CJ2" | tail -n1); assert_code 201 "$code" "register user2"
code=$(request POST /login '{"username":"bob_2","password":"password123"}' "$CJ2" | tail -n1); assert_code 200 "$code" "login user2"
code=$(request POST /todos '{"title":"u2-t1"}' "$CJ2" | tail -n1); assert_code 201 "$code" "user2 create todo"
U2_T1_ID=$(sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p' /tmp/resp_body.$$)

# user1 cannot access user2 todo
code=$(request GET /todos/$U2_T1_ID '' "$CJ1" | tail -n1); assert_code 404 "$code" "user1 cannot access user2 todo"

# Logout user1 and ensure session invalidated
code=$(request POST /logout '' "$CJ1" | tail -n1); assert_code 200 "$code" "logout user1"
code=$(request GET /me '' "$CJ1" | tail -n1); assert_code 401 "$code" "session invalidated"

echo "All tests passed."
