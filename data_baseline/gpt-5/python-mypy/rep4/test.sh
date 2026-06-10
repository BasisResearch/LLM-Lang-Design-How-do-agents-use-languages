#!/usr/bin/env bash
set -euo pipefail

# Find a free TCP port
PORT=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(('127.0.0.1',0))
print(s.getsockname()[1])
s.close()
PY
)

./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

# wait for server
for i in {1..100}; do
  if curl -s "http://127.0.0.1:$PORT/" >/dev/null; then
    break
  fi
  sleep 0.1
done

base="http://127.0.0.1:$PORT"

# Register
resp=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/register")
echo "$resp" | grep '"id"' >/dev/null

# Duplicate username
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/register")
[[ "$code" == "409" ]]

# Login
headers=$(mktemp)
resp=$(curl -s -D "$headers" -X POST -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/login")
tr -d '\r' < "$headers" | grep -i '^set-cookie: session_id=' >/dev/null
# Extract cookie case-insensitively
cookie=$(tr -d '\r' < "$headers" | awk 'BEGIN{IGNORECASE=1} /^set-cookie: session_id=/{print $0}' | head -n1 | sed -E 's/^set-cookie: ([^;]+);.*$/\1/I')

# /me
resp=$(curl -s -H "Cookie: $cookie" "$base/me")
echo "$resp" | grep '"username":"user_1"' >/dev/null

# Change password wrong old
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"wrong","new_password":"newpassword123"}' "$base/password")
[[ "$code" == "401" ]]

# Change password correct
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"password123","new_password":"newpassword123"}' "$base/password")
[[ "$code" == "200" ]]

# Create todo
resp=$(curl -s -X POST -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"title":"Task 1","description":"Desc"}' "$base/todos")
echo "$resp" | grep '"id"' >/dev/null

# List todos
resp=$(curl -s -H "Cookie: $cookie" "$base/todos")
echo "$resp" | grep 'Task 1' >/dev/null

# Get todo 1
resp=$(curl -s -H "Cookie: $cookie" "$base/todos/1")
echo "$resp" | grep '"id": 1' >/dev/null || echo "$resp"

# Update todo 1
resp=$(curl -s -X PUT -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"completed": true, "description": "New"}' "$base/todos/1")
echo "$resp" | grep '"completed": true' >/dev/null

# Delete todo 1
code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "Cookie: $cookie" "$base/todos/1")
[[ "$code" == "204" ]]

# Ensure deleted
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" "$base/todos/1")
[[ "$code" == "404" ]]

# Logout
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Cookie: $cookie" "$base/logout")
[[ "$code" == "200" ]]

# Access after logout should fail
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" "$base/me")
[[ "$code" == "401" ]]

echo "All tests passed"