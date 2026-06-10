#!/bin/bash
set -euo pipefail

# Find an available random port
PORT=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(("127.0.0.1",0))
print(s.getsockname()[1])
s.close()
PY
)

COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; [[ -n "${SRV_PID-}" ]] && kill $SRV_PID || true; }
trap cleanup EXIT

./run.sh --port "$PORT" &
SRV_PID=$!
sleep 1

echo "-- Testing register --"
resp=$(curl -sS -X POST http://127.0.0.1:$PORT/register -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$resp" | grep '"id"' >/dev/null

# duplicate username should 409
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/register -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ "$code" == "409" ]]

# login
resp=$(curl -sS -c "$COOKIE_JAR" -X POST http://127.0.0.1:$PORT/login -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$resp" | grep '"username":"user_1"' >/dev/null

# me
resp=$(curl -sS -b "$COOKIE_JAR" http://127.0.0.1:$PORT/me)
echo "$resp" | grep '"username":"user_1"' >/dev/null

# password change wrong old
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X PUT http://127.0.0.1:$PORT/password -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$code" == "401" ]]

# password change right
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X PUT http://127.0.0.1:$PORT/password -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]]

# logout
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/logout)
[[ "$code" == "200" ]]

# me after logout should 401
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/me)
[[ "$code" == "401" ]]

# login again with new password
resp=$(curl -sS -c "$COOKIE_JAR" -X POST http://127.0.0.1:$PORT/login -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword123"}')

# invalid auth to todos should 401
code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/todos)
[[ "$code" == "401" ]]

echo "-- Testing todos --"
# empty list
resp=$(curl -sS -b "$COOKIE_JAR" http://127.0.0.1:$PORT/todos)
echo "$resp" | grep '^\[\]' >/dev/null || true

# create two todos
resp=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Desc 1"}' http://127.0.0.1:$PORT/todos -X POST)
echo "$resp" | grep '"title":"Task 1"' >/dev/null
resp=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task 2"}' http://127.0.0.1:$PORT/todos -X POST)
echo "$resp" | grep '"title":"Task 2"' >/dev/null

# list should have 2
resp=$(curl -sS -b "$COOKIE_JAR" http://127.0.0.1:$PORT/todos)
count=$(echo "$resp" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')
[[ "$count" == "2" ]]

# get /todos/1
resp=$(curl -sS -b "$COOKIE_JAR" http://127.0.0.1:$PORT/todos/1)
echo "$resp" | grep '"id":1' >/dev/null

# update /todos/1 completed true
resp=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"completed":true}' -X PUT http://127.0.0.1:$PORT/todos/1)
echo "$resp" | grep '"completed":true' >/dev/null

# delete /todos/2
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X DELETE http://127.0.0.1:$PORT/todos/2)
[[ "$code" == "204" ]]

# get deleted should 404
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/todos/2)
[[ "$code" == "404" ]]

echo "All tests passed."