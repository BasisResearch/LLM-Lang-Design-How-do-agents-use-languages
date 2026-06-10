#!/usr/bin/env bash
set -euo pipefail
PORT=8099
if ! command -v jq >/dev/null 2>&1; then
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq >/dev/null 2>&1 || true
fi
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() { kill $SERVER_PID >/dev/null 2>&1 || true; }
trap cleanup EXIT
# wait for server by polling /me expecting 401
for i in {1..50}; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/me") || true
  if [[ "$code" == "401" ]]; then break; fi
  sleep 0.2
done

base="http://127.0.0.1:$PORT"

# Register
resp=$(curl -sS -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[[ $(echo "$resp" | jq -r .username) == "alice_1" ]]

# Duplicate register should 409
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[[ "$code" == "409" ]]

# Login
headers=$(mktemp)
resp=$(curl -sS -D "$headers" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
session=$(grep -i '^set-cookie:' "$headers" | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r')
[[ -n "$session" ]]

# /me
resp=$(curl -sS -b "session_id=$session" "$base/me")
[[ $(echo "$resp" | jq -r .username) == "alice_1" ]]

# Change password with wrong old -> 401
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$base/password" -H 'Content-Type: application/json' -b "session_id=$session" -d '{"old_password":"wrong","new_password":"newpassword1"}')
[[ "$code" == "401" ]]

# Change password success
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "$base/password" -H 'Content-Type: application/json' -b "session_id=$session" -d '{"old_password":"password123","new_password":"newpassword1"}')
[[ "$code" == "200" ]]

# Create todo missing title -> 400
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$base/todos" -H 'Content-Type: application/json' -b "session_id=$session" -d '{"description":"d"}')
[[ "$code" == "400" ]]

# Create todo
resp=$(curl -sS -X POST "$base/todos" -H 'Content-Type: application/json' -b "session_id=$session" -d '{"title":"t1","description":"d1"}')
id1=$(echo "$resp" | jq -r .id)

# List todos
resp=$(curl -sS -b "session_id=$session" "$base/todos")
[[ $(echo "$resp" | jq 'length') -eq 1 ]]

# Get todo by id
resp=$(curl -sS -b "session_id=$session" "$base/todos/$id1")
[[ $(echo "$resp" | jq -r .title) == "t1" ]]

# Update todo
resp=$(curl -sS -X PUT "$base/todos/$id1" -H 'Content-Type: application/json' -b "session_id=$session" -d '{"completed":true,"title":"t1b"}')
[[ $(echo "$resp" | jq -r .completed) == "true" ]]

# Delete todo
code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$base/todos/$id1" -b "session_id=$session")
[[ "$code" == "204" ]]

# Confirm 404 after delete
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "session_id=$session" "$base/todos/$id1")
[[ "$code" == "404" ]]

# Logout
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$base/logout" -b "session_id=$session")
[[ "$code" == "200" ]]

# Subsequent /me should 401
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "session_id=$session" "$base/me")
[[ "$code" == "401" ]]

echo "All tests passed"