#!/usr/bin/env bash
set -euo pipefail
PORT=0
BASE=""
COOKIE_JAR=$(mktemp)
cleanup(){ rm -f "$COOKIE_JAR"; if [[ -n "${SERVER_PID-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi }
trap cleanup EXIT

# Start server on ephemeral port and capture output
LOG=$(mktemp)
./run.sh --port "$PORT" > "$LOG" 2>&1 &
SERVER_PID=$!
# Wait for server to print the bound port
for i in {1..100}; do
  if grep -Eo 'Server listening on 0.0.0.0:[0-9]+' "$LOG" >/dev/null; then
    PORT=$(grep -Eo 'Server listening on 0.0.0.0:[0-9]+' "$LOG" | tail -n1 | sed -E 's/.*://')
    BASE="http://127.0.0.1:${PORT}"
    break
  fi
  sleep 0.1
done
if [[ -z "$BASE" ]]; then echo "Failed to detect server port"; echo "LOG:"; cat "$LOG"; exit 1; fi

echo "Testing base: $BASE"

function curlj(){
  curl --noproxy '*' -sS -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

# Unauth me should be 401
code=$(curl --noproxy '*' -s -o /dev/null -w "%{http_code}" "$BASE/me")
if [[ "$code" != "401" ]]; then echo "Expected 401 for /me, got $code"; exit 1; fi

# Register
resp=$(curlj -X POST "$BASE/register" -d '{"username":"user_1","password":"password123"}')
echo "$resp" | grep '"id":1' >/dev/null || { echo "Register failed: $resp"; exit 1; }

# Duplicate register should 409
code=$(curlj -o /dev/null -w "%{http_code}" -X POST "$BASE/register" -d '{"username":"user_1","password":"password123"}')
[[ "$code" == "409" ]] || { echo "Expected 409 duplicate register, got $code"; exit 1; }

# Login
resp=$(curlj -X POST "$BASE/login" -d '{"username":"user_1","password":"password123"}')
echo "$resp" | grep '"id":1' >/dev/null || { echo "Login failed: $resp"; exit 1; }

# Get me
resp=$(curlj "$BASE/me")
echo "$resp" | grep '"username":"user_1"' >/dev/null || { echo "Me failed: $resp"; exit 1; }

# Change password with wrong old should 401
code=$(curlj -o /dev/null -w "%{http_code}" -X PUT "$BASE/password" -d '{"old_password":"bad","new_password":"newpassword123"}')
[[ "$code" == "401" ]] || { echo "Expected 401 wrong old password, got $code"; exit 1; }

# Change password success
code=$(curlj -o /dev/null -w "%{http_code}" -X PUT "$BASE/password" -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]] || { echo "Expected 200 password change, got $code"; exit 1; }

# Logout
code=$(curlj -o /dev/null -w "%{http_code}" -X POST "$BASE/logout")
[[ "$code" == "200" ]] || { echo "Expected 200 logout, got $code"; exit 1; }

# Using same cookie after logout should be 401
code=$(curlj -o /dev/null -w "%{http_code}" "$BASE/me")
[[ "$code" == "401" ]] || { echo "Expected 401 after logout, got $code"; exit 1; }

# Login again with new password
resp=$(curlj -X POST "$BASE/login" -d '{"username":"user_1","password":"newpassword123"}')
echo "$resp" | grep '"id":1' >/dev/null || { echo "Re-login failed: $resp"; exit 1; }

# Create todos
resp=$(curlj -X POST "$BASE/todos" -d '{"title":"Task A","description":"Desc A"}')
echo "$resp" | grep '"title":"Task A"' >/dev/null || { echo "Create todo failed: $resp"; exit 1; }
resp=$(curlj -X POST "$BASE/todos" -d '{"title":"Task B"}')
echo "$resp" | grep '"completed":false' >/dev/null || { echo "Create todo 2 failed: $resp"; exit 1; }

# List todos
resp=$(curlj "$BASE/todos")
echo "$resp" | grep '"id":1' >/dev/null || { echo "List todos failed: $resp"; exit 1; }

# Get todo 1
resp=$(curlj "$BASE/todos/1")
echo "$resp" | grep '"title":"Task A"' >/dev/null || { echo "Get todo failed: $resp"; exit 1; }

# Update partial: completed true
resp=$(curlj -X PUT "$BASE/todos/1" -d '{"completed":true}')
echo "$resp" | grep '"completed":true' >/dev/null || { echo "Update todo failed: $resp"; exit 1; }

# Delete todo 2
code=$(curlj -o /dev/null -w "%{http_code}" -X DELETE "$BASE/todos/2")
[[ "$code" == "204" ]] || { echo "Expected 204 delete, got $code"; exit 1; }

# Access another user's todo should 404
# Create user 2
resp=$(curlj -X POST "$BASE/register" -d '{"username":"user2","password":"password123"}')
# Login user2
resp=$(curlj -X POST "$BASE/login" -d '{"username":"user2","password":"password123"}')
# Try to access user1's todo 1
code=$(curlj -o /dev/null -w "%{http_code}" "$BASE/todos/1")
[[ "$code" == "404" ]] || { echo "Expected 404 foreign todo, got $code"; exit 1; }

echo "All tests passed"
