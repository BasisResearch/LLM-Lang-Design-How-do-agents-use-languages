#!/usr/bin/env bash
set -euo pipefail
PORT=9090
COOKIE_JAR=$(mktemp)
ROOT=$(pwd)

cleanup() {
  rm -f "$COOKIE_JAR"
  if [[ -n ${SERVER_PID:-} ]]; then
    kill "$SERVER_PID" || true
  fi
}
trap cleanup EXIT

chmod +x run.sh
./run.sh --port "$PORT" >/tmp/server.log 2>&1 &
SERVER_PID=$!
# Wait for server
for i in {1..60}; do
  if curl -s "http://localhost:$PORT/me" -b "$COOKIE_JAR" -H 'Accept: application/json' >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server exited early" >&2
    tail -n +1 /tmp/server.log || true
    exit 1
  fi
  if [[ $i -eq 60 ]]; then
    echo "Server did not start" >&2
    exit 1
  fi
done

# Helper function
req() {
  local method=$1
  local path=$2
  local data=${3:-}
  local extra=("-H" "Content-Type: application/json")
  if [[ -n "$data" ]]; then
    extra+=("-d" "$data")
  fi
  curl -sS -X "$method" "http://localhost:$PORT$path" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "${extra[@]}"
}

# Expect 401 without auth on protected endpoints
resp=$(req GET /me)
[[ $(echo "$resp" | jq -r .error) == "Authentication required" ]]

# Register
resp=$(req POST /register '{"username":"alice_1","password":"password123"}')
[[ $(echo "$resp" | jq -r .username) == "alice_1" ]]

# Duplicate username
code=$(curl -sS -o /dev/stderr -w "%{http_code}" -X POST "http://localhost:$PORT/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}') || true
[[ "$code" == "409" ]]

# Login
resp=$(req POST /login '{"username":"alice_1","password":"password123"}')
[[ $(echo "$resp" | jq -r .username) == "alice_1" ]]

# Me
resp=$(req GET /me)
[[ $(echo "$resp" | jq -r .username) == "alice_1" ]]

# Password change with wrong old -> 401
code=$(curl -sS -o /dev/stderr -w "%{http_code}" -X PUT "http://localhost:$PORT/password" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword123"}') || true
[[ "$code" == "401" ]]

# Password change success
resp=$(req PUT /password '{"old_password":"password123","new_password":"newpassword123"}')
# Should be empty object
[[ $(echo "$resp" | jq -r 'keys | length') == "0" ]]

# Logout
resp=$(req POST /logout)
[[ $(echo "$resp" | jq -r 'keys | length') == "0" ]]

# Access after logout should be 401
code=$(curl -sS -o /dev/stderr -w "%{http_code}" -X GET "http://localhost:$PORT/me" -b "$COOKIE_JAR" -H 'Content-Type: application/json') || true
[[ "$code" == "401" ]]

# Login again with new password
resp=$(req POST /login '{"username":"alice_1","password":"newpassword123"}')
[[ $(echo "$resp" | jq -r .username) == "alice_1" ]]

# Create todo without title -> 400
code=$(curl -sS -o /dev/stderr -w "%{http_code}" -X POST "http://localhost:$PORT/todos" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"","description":"x"}') || true
[[ "$code" == "400" ]]

# Create todos
resp=$(req POST /todos '{"title":"t1","description":"d1"}')
id1=$(echo "$resp" | jq -r .id)
resp=$(req POST /todos '{"title":"t2"}')
id2=$(echo "$resp" | jq -r .id)

# List todos
resp=$(req GET /todos)
[[ $(echo "$resp" | jq -r 'length') == "2" ]]

# Get specific
resp=$(req GET /todos/$id1)
[[ $(echo "$resp" | jq -r .title) == "t1" ]]

# Update partial - set completed
resp=$(req PUT /todos/$id1 '{"completed":true}')
[[ $(echo "$resp" | jq -r .completed) == "true" ]]

# Update with empty title -> 400
code=$(curl -sS -o /dev/stderr -w "%{http_code}" -X PUT "http://localhost:$PORT/todos/$id1" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":""}') || true
[[ "$code" == "400" ]]

# Delete
code=$(curl -sS -o /dev/stderr -w "%{http_code}" -X DELETE "http://localhost:$PORT/todos/$id2" -b "$COOKIE_JAR") || true
[[ "$code" == "204" ]]

# Get deleted -> 404
code=$(curl -sS -o /dev/stderr -w "%{http_code}" -X GET "http://localhost:$PORT/todos/$id2" -b "$COOKIE_JAR" -H 'Content-Type: application/json') || true
[[ "$code" == "404" ]]

echo "All tests passed"