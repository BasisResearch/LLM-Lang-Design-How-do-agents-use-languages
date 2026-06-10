#!/usr/bin/env bash
set -euo pipefail

# Find a free port
find_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
PY
}
PORT=$(find_free_port)
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
HDR=
cleanup() {
  [[ -n "${SERVER_PID-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
  [[ -n "${SERVER_PID-}" ]] && wait "$SERVER_PID" 2>/dev/null || true
  rm -f "$COOKIE_JAR" "$HDR" 2>/dev/null || true
}
trap cleanup EXIT

./run.sh --port "$PORT" &
SERVER_PID=$!

# Wait until server is ready
RETRIES=50
until curl -sS -o /dev/null -w '%{http_code}' "$BASE/me" | grep -qE '^(401|404)$'; do
  sleep 0.1
  RETRIES=$((RETRIES-1))
  if [[ $RETRIES -le 0 ]]; then
    echo "Server did not become ready" >&2
    exit 1
  fi
done

check_json_ct() {
  local headers_file=$1
  if ! grep -qi "Content-Type: application/json" "$headers_file"; then
    echo "Missing or wrong Content-Type" >&2
    exit 1
  fi
}

# Register
HDR=$(mktemp)
STATUS=$(curl -sS -o /dev/null -D "$HDR" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' "$BASE/register")
check_json_ct "$HDR"
[[ "$STATUS" == "201" ]]

# Duplicate register should 409
HDR=$(mktemp)
STATUS=$(curl -sS -o /dev/null -D "$HDR" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' "$BASE/register")
check_json_ct "$HDR"
[[ "$STATUS" == "409" ]]

# Login
HDR=$(mktemp)
STATUS=$(curl -sS -c "$COOKIE_JAR" -o /dev/null -D "$HDR" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' "$BASE/login")
check_json_ct "$HDR"
[[ "$STATUS" == "200" ]]
# ensure cookie is set
if ! grep -qi "Set-Cookie:.*session_id=" "$HDR"; then echo "No Set-Cookie" >&2; exit 1; fi

# GET /me
HDR=$(mktemp)
STATUS=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -D "$HDR" -w "%{http_code}" "$BASE/me")
check_json_ct "$HDR"
[[ "$STATUS" == "200" ]]

# Create todo
HDR=$(mktemp)
STATUS=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -D "$HDR" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"desc"}' "$BASE/todos")
check_json_ct "$HDR"
[[ "$STATUS" == "201" ]]

# List todos
HDR=$(mktemp)
STATUS=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -D "$HDR" -w "%{http_code}" "$BASE/todos")
check_json_ct "$HDR"
[[ "$STATUS" == "200" ]]

# Get todo by id 1
HDR=$(mktemp)
STATUS=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -D "$HDR" -w "%{http_code}" "$BASE/todos/1")
check_json_ct "$HDR"
[[ "$STATUS" == "200" ]]

# Update todo
HDR=$(mktemp)
STATUS=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -D "$HDR" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"completed":true}' "$BASE/todos/1")
check_json_ct "$HDR"
[[ "$STATUS" == "200" ]]

# Delete todo
HDR=$(mktemp)
STATUS=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -D "$HDR" -w "%{http_code}" -X DELETE "$BASE/todos/1")
# DELETE should have no body and no content-type
if grep -qi "Content-Type" "$HDR"; then echo "DELETE should not include Content-Type" >&2; exit 1; fi
[[ "$STATUS" == "204" ]]

# Logout
HDR=$(mktemp)
STATUS=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -D "$HDR" -w "%{http_code}" -X POST "$BASE/logout")
check_json_ct "$HDR"
[[ "$STATUS" == "200" ]]

# Confirm session invalidated
HDR=$(mktemp)
STATUS=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -D "$HDR" -w "%{http_code}" "$BASE/me")
check_json_ct "$HDR"
[[ "$STATUS" == "401" ]]

echo "All tests passed on port $PORT"
