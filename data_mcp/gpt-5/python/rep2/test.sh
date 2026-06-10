#!/bin/sh
set -eu
PORT=8123
BASE="http://127.0.0.1:$PORT"
COOKIEJAR=$(mktemp)
cleanup() {
  rm -f "$COOKIEJAR" headers.txt body.txt create.json list.json get.json update.json || true
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" &
SERVER_PID=$!
# Wait for server to start
for i in $(seq 1 50); do
  if curl -sS "$BASE/me" -o /dev/null; then
    break
  fi
  sleep 0.2
done

# Helper to check status code
check_status() {
  expected=$1
  code=$2
  if [ "$code" -ne "$expected" ]; then
    echo "Expected status $expected but got $code" >&2
    exit 1
  fi
}

echo "1) Register user"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"username":"user_one","password":"longpassword"}' "$BASE/register")
check_status 201 "$code"

# Duplicate username should 409
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"username":"user_one","password":"longpassword"}' "$BASE/register")
check_status 409 "$code"

echo "2) Login"
code=$(curl -sS -D headers.txt -o body.txt -w '%{http_code}' -H 'Content-Type: application/json' \
  -d '{"username":"user_one","password":"longpassword"}' -c "$COOKIEJAR" "$BASE/login")
check_status 200 "$code"
# Confirm Set-Cookie present
if ! grep -qi '^set-cookie:.*session_id=' headers.txt; then
  echo "Missing Set-Cookie on login" >&2
  exit 1
fi

# /me should work
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIEJAR" "$BASE/me")
check_status 200 "$code"

# Create todo
echo "3) Create todo"
code=$(curl -sS -o create.json -w '%{http_code}' -H 'Content-Type: application/json' -b "$COOKIEJAR" \
  -d '{"title":"Task A","description":"First"}' "$BASE/todos")
check_status 201 "$code"

# List todos
code=$(curl -sS -o list.json -w '%{http_code}' -b "$COOKIEJAR" "$BASE/todos")
check_status 200 "$code"

# Get todo id from create.json
TID=$(python3 - <<'PY'
import json
with open('create.json') as f:
    print(json.load(f)['id'])
PY
)

# GET /todos/:id
code=$(curl -sS -o get.json -w '%{http_code}' -b "$COOKIEJAR" "$BASE/todos/$TID")
check_status 200 "$code"

# PUT /todos/:id (partial)
code=$(curl -sS -o update.json -w '%{http_code}' -H 'Content-Type: application/json' -b "$COOKIEJAR" \
  -X PUT -d '{"completed": true}' "$BASE/todos/$TID")
check_status 200 "$code"

# DELETE /todos/:id
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIEJAR" -X DELETE "$BASE/todos/$TID")
check_status 204 "$code"

# Confirm deleted returns 404
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIEJAR" "$BASE/todos/$TID")
check_status 404 "$code"

# Test password change
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -b "$COOKIEJAR" \
  -X PUT -d '{"old_password":"longpassword","new_password":"newlongpassword"}' "$BASE/password")
check_status 200 "$code"

# Logout
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIEJAR" -X POST "$BASE/logout")
check_status 200 "$code"

# Confirm session invalidated
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIEJAR" "$BASE/me")
check_status 401 "$code"

echo "All tests passed."