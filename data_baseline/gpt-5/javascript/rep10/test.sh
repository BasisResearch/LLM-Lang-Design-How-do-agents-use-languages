#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-$(shuf -i 20000-65000 -n 1)}
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
CURL=(curl -sS -i -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json')

./run.sh --port $PORT &
PID=$!
cleanup() {
  kill $PID 2>/dev/null || true
  rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

# Wait for server to be ready
for i in {1..50}; do
  if curl -sS --max-time 0.2 "$BASE/healthz" >/dev/null 2>&1 || curl -sS --max-time 0.2 "$BASE/doesnotexist" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

echo "Register user"
RESP=$(${CURL[@]} -X POST "$BASE/register" --data '{"username":"user_1","password":"password123"}')
echo "$RESP" | sed -n '1,5p'
[[ "$RESP" == *$' 201 '* ]] || { echo "Expected 201"; echo "$RESP"; exit 1; }
[[ "$RESP" == *'Content-Type: application/json'* ]] || { echo "Missing JSON content-type"; exit 1; }

# Register duplicate
RESP=$(${CURL[@]} -X POST "$BASE/register" --data '{"username":"user_1","password":"password123"}' || true)
[[ "$RESP" == *$' 409 '* ]] || { echo "Expected 409 duplicate"; echo "$RESP"; exit 1; }

# Login
RESP=$(${CURL[@]} -X POST "$BASE/login" --data '{"username":"user_1","password":"password123"}')
[[ "$RESP" == *$' 200 '* ]] || { echo "Login expected 200"; echo "$RESP"; exit 1; }
[[ "$RESP" == *'Set-Cookie: session_id='* ]] || { echo "Missing session cookie"; echo "$RESP"; exit 1; }

# /me
RESP=$(${CURL[@]} "$BASE/me")
[[ "$RESP" == *$' 200 '* ]] || { echo "/me expected 200"; echo "$RESP"; exit 1; }

# Change password wrong old
RESP=$(${CURL[@]} -X PUT "$BASE/password" --data '{"old_password":"wrong","new_password":"newpass123"}' || true)
[[ "$RESP" == *$' 401 '* ]] || { echo "Password wrong old expected 401"; echo "$RESP"; exit 1; }
# Change password short
RESP=$(${CURL[@]} -X PUT "$BASE/password" --data '{"old_password":"password123","new_password":"short"}' || true)
[[ "$RESP" == *$' 400 '* ]] || { echo "Password too short expected 400"; echo "$RESP"; exit 1; }
# Change password success
RESP=$(${CURL[@]} -X PUT "$BASE/password" --data '{"old_password":"password123","new_password":"newpass123"}')
[[ "$RESP" == *$' 200 '* ]] || { echo "Password change expected 200"; echo "$RESP"; exit 1; }

# Logout
RESP=$(${CURL[@]} -X POST "$BASE/logout")
[[ "$RESP" == *$' 200 '* ]] || { echo "Logout expected 200"; echo "$RESP"; exit 1; }

# Access after logout should fail
RESP=$(${CURL[@]} "$BASE/me" || true)
[[ "$RESP" == *$' 401 '* ]] || { echo "me after logout expected 401"; echo "$RESP"; exit 1; }

# Login with new password
RESP=$(${CURL[@]} -X POST "$BASE/login" --data '{"username":"user_1","password":"newpass123"}')
[[ "$RESP" == *$' 200 '* ]] || { echo "Re-login expected 200"; echo "$RESP"; exit 1; }

# Create todo missing title
RESP=$(${CURL[@]} -X POST "$BASE/todos" --data '{"description":"desc"}' || true)
[[ "$RESP" == *$' 400 '* ]] || { echo "Missing title expected 400"; echo "$RESP"; exit 1; }

# Create todos
RESP=$(${CURL[@]} -X POST "$BASE/todos" --data '{"title":"Task 1","description":"First"}')
[[ "$RESP" == *$' 201 '* ]] || { echo "Todo create 201"; echo "$RESP"; exit 1; }
RESP=$(${CURL[@]} -X POST "$BASE/todos" --data '{"title":"Task 2"}')
[[ "$RESP" == *$' 201 '* ]] || { echo "Todo create 201"; echo "$RESP"; exit 1; }

# List todos
RESP=$(${CURL[@]} "$BASE/todos")
[[ "$RESP" == *$' 200 '* ]] || { echo "List expected 200"; echo "$RESP"; exit 1; }
BODY=$(echo "$RESP" | sed -n '/^\r$/,$p' | tail -n +2)
# basic check: should be JSON array
[[ "$BODY" == \[* ]] || { echo "List body not array"; echo "$BODY"; exit 1; }

# Get todo 1
RESP=$(${CURL[@]} "$BASE/todos/1")
[[ "$RESP" == *$' 200 '* ]] || { echo "Get todo 1 expected 200"; echo "$RESP"; exit 1; }

# Update todo 1
RESP=$(${CURL[@]} -X PUT "$BASE/todos/1" --data '{"completed":true}')
[[ "$RESP" == *$' 200 '* ]] || { echo "Update todo 1 expected 200"; echo "$RESP"; exit 1; }

# Delete todo 2
RESP=$(${CURL[@]} -X DELETE "$BASE/todos/2")
STATUS=$(echo "$RESP" | head -n1)
if [[ "$STATUS" != *$' 204 '* ]]; then echo "Delete expected 204"; echo "$RESP"; exit 1; fi

# Get deleted todo -> 404
RESP=$(${CURL[@]} "$BASE/todos/2" || true)
[[ "$RESP" == *$' 404 '* ]] || { echo "Get deleted expected 404"; echo "$RESP"; exit 1; }

echo "All tests passed"