#!/bin/sh
set -e
PORT=3456
./run.sh --port $PORT &
SERVER_PID=$!
sleep 0.5

base="http://127.0.0.1:$PORT"

fail() { echo "TEST FAILED: $1"; kill $SERVER_PID || true; exit 1; }

# Register
status=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' $base/register)
[ "$status" = "201" ] || fail "register status $status"

# Duplicate username
status=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' $base/register)
[ "$status" = "409" ] || fail "duplicate username status $status"

# Login
curl -sS -D /tmp/login_headers.$$ -o /tmp/login_body.$$ -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' $base/login >/dev/null
status=$(awk 'NR==1{print $2}' /tmp/login_headers.$$)
[ "$status" = "200" ] || fail "login status $status"
session=$(grep -i '^Set-Cookie:' /tmp/login_headers.$$ | sed -n 's/Set-Cookie: session_id=\([^;]*\).*/\1/p' | tr -d '\r\n')
[ -n "$session" ] || fail "no session cookie"

cookie="Cookie: session_id=$session"

# /me
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" $base/me)
[ "$status" = "200" ] || fail "/me status $status"

# Change password wrong old
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" -H 'Content-Type: application/json' -X PUT -d '{"old_password":"wrong","new_password":"newpassword123"}' $base/password)
[ "$status" = "401" ] || fail "password wrong old status $status"

# Change password too short
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" -H 'Content-Type: application/json' -X PUT -d '{"old_password":"password123","new_password":"short"}' $base/password)
[ "$status" = "400" ] || fail "password too short status $status"

# Change password success
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" -H 'Content-Type: application/json' -X PUT -d '{"old_password":"password123","new_password":"newpassword123"}' $base/password)
[ "$status" = "200" ] || fail "password change status $status"

# Create todo missing title
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" -H 'Content-Type: application/json' -d '{"description":"test"}' $base/todos)
[ "$status" = "400" ] || fail "create missing title $status"

# Create todo 1
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"First"}' $base/todos)
[ "$status" = "201" ] || fail "create todo1 $status"

# Create todo 2
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" -H 'Content-Type: application/json' -d '{"title":"Task 2","description":"Second"}' $base/todos)
[ "$status" = "201" ] || fail "create todo2 $status"

# List todos
list=$(curl -sS -H "$cookie" $base/todos)
count=$(echo "$list" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')
[ "$count" = "2" ] || fail "list count $count"

# Get todo 1
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" $base/todos/1)
[ "$status" = "200" ] || fail "get todo1 $status"

# Update todo 1
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" -H 'Content-Type: application/json' -X PUT -d '{"completed":true}' $base/todos/1)
[ "$status" = "200" ] || fail "update todo1 $status"

# Delete todo 2
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" -X DELETE $base/todos/2)
[ "$status" = "204" ] || fail "delete todo2 $status"

# Logout
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" -X POST $base/logout)
[ "$status" = "200" ] || fail "logout $status"

# Access after logout should be 401
status=$(curl -sS -o /dev/null -w "%{http_code}" -H "$cookie" $base/me)
[ "$status" = "401" ] || fail "post-logout auth $status"

kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true

echo "All tests passed"