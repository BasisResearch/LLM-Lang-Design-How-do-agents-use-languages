#!/usr/bin/env bash
set -euo pipefail
PORT=43123
# Kill any stray servers
pkill -f "target/release/todo_server --port $PORT" 2>/dev/null || true
sleep 0.2
./run.sh --port "$PORT" &
PID=$!
# Wait for server to be ready
for i in {1..60}; do
  if curl -sS "http://127.0.0.1:$PORT/me" >/dev/null; then
    break
  fi
  sleep 1
  if [[ $i -eq 60 ]]; then
    echo "Server failed to start" >&2
    kill $PID || true
    exit 1
  fi
done
base="http://127.0.0.1:$PORT"

jq_post(){
  curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' "$@"
}

# Register
resp=$(jq_post -X POST "$base/register" -d '{"username":"user_one","password":"password123"}')
echo "$resp" | tail -n1 | grep -q '^201$'

# Duplicate username
resp=$(jq_post -X POST "$base/register" -d '{"username":"user_one","password":"password123"}')
echo "$resp" | tail -n1 | grep -q '^409$'

# Login
login_out=$(jq_post -i -X POST "$base/login" -d '{"username":"user_one","password":"password123"}')
# capture cookie header requires -i; extract cookie (case-insensitive)
cookie=$(echo "$login_out" | awk 'BEGIN{IGNORECASE=1}/^set-cookie: session_id=/{print $0}' | head -n1 | sed -E 's/.*session_id=([^;]*).*/\1/i')
code=$(echo "$login_out" | tail -n1)
echo "$code" | grep -q '^200$'

# /me
me=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -b "session_id=$cookie" "$base/me")
echo "$me" | tail -n1 | grep -q '^200$'

# Change password (invalid old)
resp=$(jq_post -X PUT "$base/password" -b "session_id=$cookie" -d '{"old_password":"bad","new_password":"newpassword1"}')
echo "$resp" | tail -n1 | grep -q '^401$'

# Change password (success)
resp=$(jq_post -X PUT "$base/password" -b "session_id=$cookie" -d '{"old_password":"password123","new_password":"newpassword1"}')
echo "$resp" | tail -n1 | grep -q '^200$'

# Logout
resp=$(curl -sS -w "\n%{http_code}" -X POST -H 'Content-Type: application/json' -b "session_id=$cookie" "$base/logout")
echo "$resp" | tail -n1 | grep -q '^200$'

# Auth should now fail
resp=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -b "session_id=$cookie" "$base/me")
echo "$resp" | tail -n1 | grep -q '^401$'

# Login again with new password
login_out=$(jq_post -i -X POST "$base/login" -d '{"username":"user_one","password":"newpassword1"}')
cookie=$(echo "$login_out" | awk 'BEGIN{IGNORECASE=1}/^set-cookie: session_id=/{print $0}' | head -n1 | sed -E 's/.*session_id=([^;]*).*/\1/i')
code=$(echo "$login_out" | tail -n1)
echo "$code" | grep -q '^200$'

# Create todo (missing title)
resp=$(jq_post -X POST "$base/todos" -b "session_id=$cookie" -d '{"description":"desc"}')
echo "$resp" | tail -n1 | grep -q '^400$'

# Create todo success
resp=$(jq_post -X POST "$base/todos" -b "session_id=$cookie" -d '{"title":"Task 1","description":"desc"}')
echo "$resp" | tail -n1 | grep -q '^201$'

# List todos should be one
resp=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -b "session_id=$cookie" "$base/todos")
echo "$resp" | tail -n1 | grep -q '^200$'

# Get first todo
resp=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -b "session_id=$cookie" "$base/todos/1")
echo "$resp" | tail -n1 | grep -q '^200$'

# Update todo
resp=$(jq_post -X PUT "$base/todos/1" -b "session_id=$cookie" -d '{"completed":true}')
echo "$resp" | tail -n1 | grep -q '^200$'

# Delete todo
resp=$(curl -sS -w "\n%{http_code}" -X DELETE -H 'Content-Type: application/json' -b "session_id=$cookie" "$base/todos/1")
echo "$resp" | tail -n1 | grep -q '^204$'

# Get should be 404
resp=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -b "session_id=$cookie" "$base/todos/1")
echo "$resp" | tail -n1 | grep -q '^404$'

kill $PID || true
wait $PID || true
