#!/bin/bash
set -euo pipefail
PORT=8123
COOKIE_JAR=$(mktemp)
cleanup() {
  rm -f "$COOKIE_JAR"
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill $SERVER_PID || true
    wait $SERVER_PID 2>/dev/null || true
  fi
}
trap cleanup EXIT

./run.sh --port "$PORT" &
SERVER_PID=$!
# Wait for server
for i in {1..50}; do
  if curl -sS "http://127.0.0.1:$PORT/doesnotexist" -o /dev/null -w '%{http_code}' | grep -qE '404|500'; then
    break
  fi
  sleep 0.1
done

echo "Testing register..."
code=$(curl -sS -o /dev/stderr -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' \
  -d '{"username": "alice_1", "password": "password123"}')
[[ "$code" == "201" ]]

# Duplicate username
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' \
  -d '{"username": "alice_1", "password": "password123"}')
[[ "$code" == "409" ]]

echo "Testing login..."
code=$(curl -sS -D headers.txt -c "$COOKIE_JAR" -o body.json -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' \
  -d '{"username": "alice_1", "password": "password123"}')
[[ "$code" == "200" ]]
cat headers.txt | grep -i '^Set-Cookie: session_id='

# /me
echo "Testing /me..."
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/me")
[[ "$code" == "200" ]]

# Create todo
echo "Testing create todo..."
resp=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title": "Task 1", "description": "desc"}' \
  "http://127.0.0.1:$PORT/todos")
echo "$resp" | jq . >/dev/null 2>&1 || { echo "Response not JSON"; exit 1; }
ID=$(echo "$resp" | jq -r .id)
[[ -n "$ID" && "$ID" != "null" ]]

# List todos
echo "Testing list todos..."
resp=$(curl -sS -b "$COOKIE_JAR" "http://127.0.0.1:$PORT/todos")
echo "$resp" | jq 'length' | grep -q '1'

# Get by id
echo "Testing get todo by id..."
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/todos/$ID")
[[ "$code" == "200" ]]

# Update todo
echo "Testing update todo..."
resp=$(curl -sS -b "$COOKIE_JAR" -X PUT -H 'Content-Type: application/json' -d '{"completed": true}' \
  "http://127.0.0.1:$PORT/todos/$ID")
echo "$resp" | jq -r .completed | grep -qi true

# Delete todo
echo "Testing delete todo..."
code=$(curl -sS -b "$COOKIE_JAR" -X DELETE -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/todos/$ID")
[[ "$code" == "204" ]]

# Ensure deleted
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/todos/$ID")
[[ "$code" == "404" ]]

# Change password
echo "Testing password change..."
code=$(curl -sS -b "$COOKIE_JAR" -X PUT -H 'Content-Type: application/json' -d '{"old_password": "password123", "new_password": "newpassword456"}' \
  -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/password")
[[ "$code" == "200" ]]

# Logout
echo "Testing logout..."
code=$(curl -sS -b "$COOKIE_JAR" -X POST -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/logout")
[[ "$code" == "200" ]]

# Post-logout access should be 401
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/me")
[[ "$code" == "401" ]]

echo "All tests passed."