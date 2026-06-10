#!/usr/bin/env bash
set -euo pipefail

PORT=18080

# Start server in background
./run.sh --port "$PORT" &
SERVER_PID=$!

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# wait for server
for i in {1..50}; do
  if curl -sS "http://127.0.0.1:$PORT/me" -H 'Accept: application/json' -o /dev/null; then
    break
  fi
  sleep 0.2
done

base="http://127.0.0.1:$PORT"

# Helper to assert HTTP code
assert_code() {
  local expected=$1; shift
  local got=$1; shift
  if [[ "$expected" != "$got" ]]; then
    echo "Expected HTTP $expected, got $got" >&2
    exit 1
  fi
}

# Register
resp=$(curl -sS -D - -o /dev/stderr -X POST "$base/register" \
  -H 'Content-Type: application/json' \
  --data '{"username":"user_1","password":"password123"}') || true
# Expect 201
code=$(echo "$resp" | head -n1 | awk '{print $2}')
assert_code 201 "$code"

# Duplicate username
resp=$(curl -sS -D - -o /dev/stderr -X POST "$base/register" \
  -H 'Content-Type: application/json' \
  --data '{"username":"user_1","password":"password123"}') || true
code=$(echo "$resp" | head -n1 | awk '{print $2}')
assert_code 409 "$code"

# Login
resp_headers=$(mktemp)
resp_body=$(mktemp)
status=$(curl -sS -D "$resp_headers" -o "$resp_body" -X POST "$base/login" \
  -H 'Content-Type: application/json' \
  --data '{"username":"user_1","password":"password123"}' \
  -w '%{http_code}')
assert_code 200 "$status"

cookie=$(grep -i '^Set-Cookie:' "$resp_headers" | sed -n 's/Set-Cookie: //Ip' | tr -d '\r' | head -n1)
if [[ -z "$cookie" ]]; then
  echo "No Set-Cookie header" >&2
  exit 1
fi

# Me
status=$(curl -sS -b "$cookie" -o /dev/null -w '%{http_code}' "$base/me")
assert_code 200 "$status"

# Change password wrong old
status=$(curl -sS -b "$cookie" -X PUT -H 'Content-Type: application/json' \
  -d '{"old_password":"wrong","new_password":"newpassword123"}' \
  -o /dev/null -w '%{http_code}' "$base/password")
assert_code 401 "$status"

# Change password correct
status=$(curl -sS -b "$cookie" -X PUT -H 'Content-Type: application/json' \
  -d '{"old_password":"password123","new_password":"newpassword123"}' \
  -o /dev/null -w '%{http_code}' "$base/password")
assert_code 200 "$status"

# Create todos
status=$(curl -sS -b "$cookie" -X POST -H 'Content-Type: application/json' \
  -d '{"title":"Task 1","description":"Desc 1"}' \
  -o /dev/null -w '%{http_code}' "$base/todos")
assert_code 201 "$status"
status=$(curl -sS -b "$cookie" -X POST -H 'Content-Type: application/json' \
  -d '{"title":"Task 2"}' \
  -o /dev/null -w '%{http_code}' "$base/todos")
assert_code 201 "$status"

# List todos
status=$(curl -sS -b "$cookie" -o /dev/null -w '%{http_code}' "$base/todos")
assert_code 200 "$status"

# Get todo 1
status=$(curl -sS -b "$cookie" -o /dev/null -w '%{http_code}' "$base/todos/1")
assert_code 200 "$status"

# Update todo 1
status=$(curl -sS -b "$cookie" -X PUT -H 'Content-Type: application/json' \
  -d '{"completed": true, "description": "Updated"}' \
  -o /dev/null -w '%{http_code}' "$base/todos/1")
assert_code 200 "$status"

# Delete todo 2
status=$(curl -sS -b "$cookie" -X DELETE -o /dev/null -w '%{http_code}' "$base/todos/2")
assert_code 204 "$status"

# Confirm 404 for deleted
status=$(curl -sS -b "$cookie" -o /dev/null -w '%{http_code}' "$base/todos/2")
assert_code 404 "$status"

# Logout
status=$(curl -sS -b "$cookie" -X POST -o /dev/null -w '%{http_code}' "$base/logout")
assert_code 200 "$status"

# After logout, auth should fail
status=$(curl -sS -b "$cookie" -o /dev/null -w '%{http_code}' "$base/me")
assert_code 401 "$status"

echo "All tests passed"