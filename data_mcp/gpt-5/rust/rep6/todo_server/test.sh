#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-18912}
ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

# Build first
cargo build -q

# Start server directly
./target/debug/todo_server --port "$PORT" >/tmp/todo_server_test.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

base="http://127.0.0.1:$PORT"
# Wait for server becoming responsive
for i in {1..100}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/me" || true)
  if [[ "$code" =~ ^[0-9]{3}$ ]]; then
    break
  fi
  sleep 0.2
done

COOKIEJAR=$(mktemp)

echo "Testing register..."
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' -X POST "$base/register")
[[ "$code" == "201" ]]

code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' -X POST "$base/register")
[[ "$code" == "409" ]]

# login invalid
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"username":"alice","password":"wrong"}' -X POST "$base/login")
[[ "$code" == "401" ]]

# login ok
resp=$(curl -s -D /tmp/headers.txt -c "$COOKIEJAR" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' -X POST "$base/login")
code=$(grep -m1 -Eo 'HTTP/1\.[01] [0-9]+' /tmp/headers.txt | awk '{print $2}')
[[ "$code" == "200" ]]
# check set-cookie
grep -i '^Set-Cookie: session_id=' /tmp/headers.txt >/dev/null

# me
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' "$base/me")
[[ "$code" == "200" ]]

# change password wrong old
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword"}' -X PUT "$base/password")
[[ "$code" == "401" ]]

# change password too short
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' -X PUT "$base/password")
[[ "$code" == "400" ]]

# change password ok
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword"}' -X PUT "$base/password")
[[ "$code" == "200" ]]

# create todo without title
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"description":"desc"}' -X POST "$base/todos")
[[ "$code" == "400" ]]

# create todo ok
resp=$(curl -s -b "$COOKIEJAR" -H 'Content-Type: application/json' -d '{"title":"Task1","description":"desc"}' -X POST "$base/todos")
# should contain id 1
echo "$resp" | grep '"id": 1' >/dev/null

# list todos
resp=$(curl -s -b "$COOKIEJAR" "$base/todos")
echo "$resp" | grep '"id": 1' >/dev/null

# get todo
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' "$base/todos/1")
[[ "$code" == "200" ]]

# update todo empty title -> 400
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"title":""}' -X PUT "$base/todos/1")
[[ "$code" == "400" ]]

# update completed
resp=$(curl -s -b "$COOKIEJAR" -H 'Content-Type: application/json' -d '{"completed":true}' -X PUT "$base/todos/1")
echo "$resp" | grep '"completed": true' >/dev/null

# delete
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' -X DELETE "$base/todos/1")
[[ "$code" == "204" ]]

# get after delete -> 404
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' "$base/todos/1")
[[ "$code" == "404" ]]

# logout
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' -X POST "$base/logout")
[[ "$code" == "200" ]]

# me after logout -> 401
code=$(curl -s -b "$COOKIEJAR" -o /dev/null -w '%{http_code}' "$base/me")
[[ "$code" == "401" ]]

echo "ALL TESTS PASSED"
