#!/usr/bin/env bash
set -euo pipefail

# Pick a random high port to avoid collisions with any running instance
PORT=${PORT:-$(( ( RANDOM % 20000 ) + 30000 ))}
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR="/tmp/todo_cookies_$$.txt"
LOG_FILE="/tmp/todo_server_$$.log"
USER="user_$$"

cleanup() {
  rm -f "$COOKIE_JAR"
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
  sudo apt-get update && sudo apt-get install -y jq >/dev/null
fi

./run.sh --port "$PORT" >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

# Wait until server is responsive by probing /register with GET (should 404)
for i in {1..50}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/register" || true)
  if [[ "$code" != "000" ]]; then
    break
  fi
  sleep 0.1
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "Server failed to start. Log:" >&2
    cat "$LOG_FILE" >&2 || true
    exit 1
  fi
done

expect_status() {
  local expected=$1
  shift
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "$@")
  if [[ "$status" != "$expected" ]]; then
    echo "Expected status $expected but got $status for: curl $*" >&2
    echo "Server log:" >&2
    tail -n +1 "$LOG_FILE" >&2 || true
    exit 1
  fi
}

# Register
expect_status 201 -H 'Content-Type: application/json' -d '{"username":"'"$USER"'","password":"password123"}' -X POST "$BASE/register"
# Duplicate username
expect_status 409 -H 'Content-Type: application/json' -d '{"username":"'"$USER"'","password":"password123"}' -X POST "$BASE/register"
# Bad username
expect_status 400 -H 'Content-Type: application/json' -d '{"username":"x","password":"password123"}' -X POST "$BASE/register"
# Short password
expect_status 400 -H 'Content-Type: application/json' -d '{"username":"'"$USER"'_b","password":"short"}' -X POST "$BASE/register"

# Login and store cookie
expect_status 200 -c "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"username":"'"$USER"'","password":"password123"}' -X POST "$BASE/login"

# /me
expect_status 200 -b "$COOKIE_JAR" "$BASE/me"

# Change password wrong old
expect_status 401 -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword1"}' -X PUT "$BASE/password"
# Change password too short
expect_status 400 -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' -X PUT "$BASE/password"
# Change password success
expect_status 200 -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword1"}' -X PUT "$BASE/password"

# Create todos
expect_status 201 -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task A","description":"First"}' -X POST "$BASE/todos"
expect_status 201 -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task B"}' -X POST "$BASE/todos"

# List todos
LIST=$(curl -s -b "$COOKIE_JAR" "$BASE/todos")
echo "$LIST" | jq . >/dev/null
COUNT=$(echo "$LIST" | jq 'length')
if [[ "$COUNT" -ne 2 ]]; then
  echo "Expected 2 todos, got $COUNT" >&2
  exit 1
fi

# Get first todo (id could be >1 for global list; find id from list)
FIRST_ID=$(echo "$LIST" | jq '.[0].id')
SECOND_ID=$(echo "$LIST" | jq '.[1].id')
expect_status 200 -b "$COOKIE_JAR" "$BASE/todos/$FIRST_ID"
# Update first todo
expect_status 200 -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"completed":true}' -X PUT "$BASE/todos/$FIRST_ID"
# Delete second todo
expect_status 204 -b "$COOKIE_JAR" -X DELETE "$BASE/todos/$SECOND_ID"
# Verify 404 after delete
expect_status 404 -b "$COOKIE_JAR" "$BASE/todos/$SECOND_ID"

# Logout
expect_status 200 -b "$COOKIE_JAR" -X POST "$BASE/logout"
sleep 0.2
# Access after logout should be 401
expect_status 401 -b "$COOKIE_JAR" "$BASE/me"

echo "All tests passed"
