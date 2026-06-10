#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-8090}
./run.sh --port "$PORT" >/tmp/todo_server_test.log 2>&1 &
PID=$!
trap 'kill $PID || true' EXIT
sleep 1

base() { echo "http://127.0.0.1:$PORT"; }

expect_code() {
  local expected=$1; shift
  local out
  set +e
  out=$(curl -s -i "$@")
  code=$(echo "$out" | awk 'NR==1{print $2}')
  body=$(echo "$out" | sed -n '/^$/,$p' | tail -n +2)
  set -e
  if [[ "$code" != "$expected" ]]; then
    echo "Expected $expected got $code"
    echo "$out"
    exit 1
  fi
}

# Register and login
expect_code 201 -X POST "$(base)/register" -H 'Content-Type: application/json' -d '{"username":"tuser","password":"12345678"}'
login=$(curl -s -i -X POST "$(base)/login" -H 'Content-Type: application/json' -d '{"username":"tuser","password":"12345678"}')
session=$(echo "$login" | grep -i 'Set-Cookie' | sed -E 's/.*session_id=([^;]+).*/\1/i' | tr -d '\r')

# Me
expect_code 200 "$(base)/me" --cookie "session_id=$session"

# Password change
expect_code 200 -X PUT "$(base)/password" --cookie "session_id=$session" -H 'Content-Type: application/json' -d '{"old_password":"12345678","new_password":"abcdefgh"}'

# Create todos
expect_code 201 -X POST "$(base)/todos" --cookie "session_id=$session" -H 'Content-Type: application/json' -d '{"title":"A","description":"B"}'
expect_code 201 -X POST "$(base)/todos" --cookie "session_id=$session" -H 'Content-Type: application/json' -d '{"title":"C"}'

# List
expect_code 200 "$(base)/todos" --cookie "session_id=$session"

# Get
expect_code 200 "$(base)/todos/1" --cookie "session_id=$session"

# Update
expect_code 200 -X PUT "$(base)/todos/1" --cookie "session_id=$session" -H 'Content-Type: application/json' -d '{"completed":true}'

# Delete
set +e
out=$(curl -s -i -X DELETE "$(base)/todos/1" --cookie "session_id=$session")
code=$(echo "$out" | awk 'NR==1{print $2}')
set -e
if [[ "$code" != "204" ]]; then
  echo "Delete expected 204 got $code"; echo "$out"; exit 1; fi

# Not found
expect_code 404 "$(base)/todos/1" --cookie "session_id=$session"

# Logout and verify
expect_code 200 -X POST "$(base)/logout" --cookie "session_id=$session"
expect_code 401 "$(base)/me" --cookie "session_id=$session"

echo "All tests passed"
