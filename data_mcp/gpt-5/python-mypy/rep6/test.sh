#!/bin/sh
set -eu
PORT=8765
./run.sh --port "$PORT" &
PID=$!
cleanup() {
  kill $PID 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
base="http://127.0.0.1:$PORT"

# Helper to extract cookie
cookie_file=$(mktemp)

echo "Register user"
code=$(curl -s -o /tmp/out1 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$base/register")
cat /tmp/out1
[ "$code" = 201 ] || { echo "register failed"; exit 1; }

# Duplicate username
code=$(curl -s -o /tmp/outdup -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$base/register")
[ "$code" = 409 ] || { echo "duplicate register failed"; exit 1; }

# Login
code=$(curl -s -D "$cookie_file" -o /tmp/out2 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$base/login")
[ "$code" = 200 ] || { echo "login failed"; cat /tmp/out2; exit 1; }
session=$(grep -i '^Set-Cookie:' "$cookie_file" | sed -n 's/Set-Cookie: \(session_id=[^;]*\).*/\1/p' | tr -d '\r')
[ -n "$session" ] || { echo "no session cookie"; exit 1; }

# /me
code=$(curl -s -o /tmp/out3 -w "%{http_code}" -H 'Cookie: '$session "$base/me")
[ "$code" = 200 ] || { echo "/me failed"; cat /tmp/out3; exit 1; }

# create todo
code=$(curl -s -o /tmp/out4 -w "%{http_code}" -H 'Cookie: '$session -H 'Content-Type: application/json' -d '{"title":"Task A","description":"desc"}' "$base/todos")
[ "$code" = 201 ] || { echo "create todo failed"; cat /tmp/out4; exit 1; }

# list todos
code=$(curl -s -o /tmp/out5 -w "%{http_code}" -H 'Cookie: '$session "$base/todos")
[ "$code" = 200 ] || { echo "list todos failed"; cat /tmp/out5; exit 1; }

id=$(jq -r '.[0].id' /tmp/out5)

# get todo by id
code=$(curl -s -o /tmp/out6 -w "%{http_code}" -H 'Cookie: '$session "$base/todos/$id")
[ "$code" = 200 ] || { echo "get todo failed"; cat /tmp/out6; exit 1; }

# update todo partial
code=$(curl -s -o /tmp/out7 -w "%{http_code}" -X PUT -H 'Cookie: '$session -H 'Content-Type: application/json' -d '{"completed":true}' "$base/todos/$id")
[ "$code" = 200 ] || { echo "update todo failed"; cat /tmp/out7; exit 1; }

# delete todo
code=$(curl -s -o /tmp/out8 -w "%{http_code}" -X DELETE -H 'Cookie: '$session "$base/todos/$id")
[ "$code" = 204 ] || { echo "delete todo failed"; cat /tmp/out8; exit 1; }

# logout
code=$(curl -s -o /tmp/out9 -w "%{http_code}" -X POST -H 'Cookie: '$session "$base/logout")
[ "$code" = 200 ] || { echo "logout failed"; cat /tmp/out9; exit 1; }

# verify session invalidated
code=$(curl -s -o /tmp/out10 -w "%{http_code}" -H 'Cookie: '$session "$base/me")
[ "$code" = 401 ] || { echo "post-logout auth should fail"; cat /tmp/out10; exit 1; }

echo "All tests passed"
