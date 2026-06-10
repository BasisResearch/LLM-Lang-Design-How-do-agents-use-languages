#!/usr/bin/env bash
set -euo pipefail

PORT=3333
SERVER_LOG=server_test.log

./run.sh --port $PORT > $SERVER_LOG 2>&1 &
PID=$!

echo "Started server PID $PID" >&2

base_url="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
trap 'kill $PID 2>/dev/null || true; rm -f "$COOKIE_JAR"' EXIT

# Wait for server readiness (up to ~15s)
for i in {1..30}; do
  if curl -sS -o /dev/null "$base_url/register"; then
    break
  fi
  sleep 0.5
  if ! kill -0 $PID 2>/dev/null; then
    echo "Server process exited prematurely" >&2
    exit 1
  fi
  if [[ $i -eq 30 ]]; then
    echo "Server did not become ready in time" >&2
    exit 1
  fi
done

USERNAME="alice_${RANDOM}_$$_$(date +%s)"
PASS1="password123"
PASS2="newpassword456"

# Helper to check status code
request() {
  local method=$1
  local path=$2
  local data=${3:-}
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" -H 'Content-Type: application/json' -d "$data" -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /tmp/resp_body -w '%{http_code}' "$base_url$path"
  else
    curl -sS -X "$method" -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /tmp/resp_body -w '%{http_code}' "$base_url$path"
  fi
}

expect_status() {
  local expected=$1
  local got=$(cat /tmp/status)
  if [[ "$expected" != "$got" ]]; then
    echo "Expected status $expected but got $got" >&2
    echo "Response body:" >&2
    cat /tmp/resp_body >&2 || true
    exit 1
  fi
}

# 1. Register
status=$(request POST /register "{\"username\":\"$USERNAME\",\"password\":\"$PASS1\"}")
echo -n "$status" > /tmp/status
expect_status 201

# 2. Login
status=$(request POST /login "{\"username\":\"$USERNAME\",\"password\":\"$PASS1\"}")
echo -n "$status" > /tmp/status
expect_status 200

# 3. GET /me
status=$(request GET /me)
echo -n "$status" > /tmp/status
expect_status 200

# 4. Create todo
status=$(request POST /todos '{"title":"Buy milk","description":"2%"}')
echo -n "$status" > /tmp/status
expect_status 201
TODO_ID=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' /tmp/resp_body)
if [[ -z "$TODO_ID" ]]; then
  echo "Failed to parse todo id" >&2
  cat /tmp/resp_body >&2
  exit 1
fi

# 5. List todos
status=$(request GET /todos)
echo -n "$status" > /tmp/status
expect_status 200

# 6. Get todo by id
status=$(request GET /todos/$TODO_ID)
echo -n "$status" > /tmp/status
expect_status 200

# 7. Update todo
status=$(request PUT /todos/$TODO_ID '{"completed":true}')
echo -n "$status" > /tmp/status
expect_status 200

# 8. Delete todo
status=$(request DELETE /todos/$TODO_ID)
echo -n "$status" > /tmp/status
expect_status 204

# 9. Ensure 404 after delete
status=$(request GET /todos/$TODO_ID)
echo -n "$status" > /tmp/status
expect_status 404

# 10. Change password
status=$(request PUT /password "{\"old_password\":\"$PASS1\",\"new_password\":\"$PASS2\"}")
echo -n "$status" > /tmp/status
expect_status 200

# 11. Logout
status=$(request POST /logout)
echo -n "$status" > /tmp/status
expect_status 200

# 12. Access after logout should be 401
status=$(request GET /me)
echo -n "$status" > /tmp/status
expect_status 401

# 13. Login with new password
status=$(request POST /login "{\"username\":\"$USERNAME\",\"password\":\"$PASS2\"}")
echo -n "$status" > /tmp/status
expect_status 200

# 14. Create todo no description
status=$(request POST /todos '{"title":"Task 2"}')
echo -n "$status" > /tmp/status
expect_status 201

# 15. Validate Content-Type for non-DELETE requests
ct=$(curl -sS -I -b "$COOKIE_JAR" "$base_url/me" | awk -F': ' 'tolower($1)=="content-type"{print $2}' | tr -d '\r')
if [[ "$ct" != application/json* ]]; then
  echo "Content-Type header incorrect: $ct" >&2
  exit 1
fi

# 16. Unauthorized request to protected endpoint
ct=$(curl -sS -o /dev/null -w '%{http_code}' "$base_url/todos")
if [[ "$ct" != "401" ]]; then
  echo "Expected 401 for unauthorized request, got $ct" >&2
  exit 1
fi

# If we reached here, all tests passed
kill $PID
wait $PID 2>/dev/null || true
rm -f "$COOKIE_JAR"
trap - EXIT

echo "All tests passed"
