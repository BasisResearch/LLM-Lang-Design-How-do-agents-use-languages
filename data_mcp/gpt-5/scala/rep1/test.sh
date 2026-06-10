#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-8090}
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; if [[ -n "${PID:-}" ]]; then kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; fi }
trap cleanup EXIT

# Start server in background
./run.sh --port "$PORT" >/tmp/server.log 2>&1 &
PID=$!
echo "Server PID: $PID"
# Wait briefly for server
for i in {1..50}; do
  if curl -s -o /dev/null "$BASE/login"; then break; fi
  sleep 0.2
done

# Helper to assert status code
status_of() {
  url=$1; shift
  curl -s -o /dev/null -w '%{http_code}' "$url" "$@"
}

# Register
resp=$(curl -s -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$resp" | grep '"id"' >/dev/null
# Content-Type must be JSON
ct=$(curl -s -D - -o /dev/null -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"tempuser","password":"password123"}' | tr -d '\r' | awk -F': ' '/^Content-Type: /{print $2}' | tail -n1)
[[ "$ct" == application/json* ]]

# Duplicate register should 409
status=$(status_of "$BASE/register" -X POST -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ "$status" == "409" ]]

# Login
resp=$(curl -s -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$resp" | grep '"username":"user_1"' >/dev/null

# /me
resp=$(curl -s -b "$COOKIE_JAR" "$BASE/me")
echo "$resp" | grep '"username":"user_1"' >/dev/null

# Change password (wrong old)
status=$(status_of "$BASE/password" -b "$COOKIE_JAR" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$status" == "401" ]]

# Change password (correct)
status=$(status_of "$BASE/password" -b "$COOKIE_JAR" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$status" == "200" ]]

# Create todo (missing title)
status=$(status_of "$BASE/todos" -b "$COOKIE_JAR" -X POST -H 'Content-Type: application/json' -d '{"description":"desc"}')
[[ "$status" == "400" ]]

# Create todo
resp=$(curl -s -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Do it"}')
echo "$resp" | grep '"title":"Task 1"' >/dev/null

# List todos
resp=$(curl -s -b "$COOKIE_JAR" "$BASE/todos")
echo "$resp" | grep '"title":"Task 1"' >/dev/null

# Get todo 1
resp=$(curl -s -b "$COOKIE_JAR" "$BASE/todos/1")
echo "$resp" | grep '"id":1' >/dev/null

# Update todo 1
resp=$(curl -s -b "$COOKIE_JAR" -X PUT "$BASE/todos/1" -H 'Content-Type: application/json' -d '{"completed":true}')
echo "$resp" | grep '"completed":true' >/dev/null

# Delete todo 1
status=$(status_of "$BASE/todos/1" -b "$COOKIE_JAR" -X DELETE)
[[ "$status" == "204" ]]

# Check not found after delete
status=$(status_of "$BASE/todos/1" -b "$COOKIE_JAR")
[[ "$status" == "404" ]]

# Logout
status=$(status_of "$BASE/logout" -b "$COOKIE_JAR" -X POST)
[[ "$status" == "200" ]]

# Confirm session invalidated
status=$(status_of "$BASE/me" -b "$COOKIE_JAR")
[[ "$status" == "401" ]]

# Login again with new password
resp=$(curl -s -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword123"}')
echo "$resp" | grep '"username":"user_1"' >/dev/null

# Create two todos and test ordering
curl -s -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"A","description":""}' >/dev/null
curl -s -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"B"}' >/dev/null
list=$(curl -s -b "$COOKIE_JAR" "$BASE/todos")
# Extract ids using python or awk fallback
if command -v python3 >/dev/null 2>&1; then
  read -r id2 id3 < <(LIST="$list" python3 - <<'PY'
import os, json
arr=json.loads(os.environ['LIST'])
print(arr[0]['id'], arr[1]['id'])
PY
)
else
  id2=$(echo "$list" | sed -n 's/.*\"id\":\([0-9]\+\).*/\1/p' | sed -n '1p')
  id3=$(echo "$list" | sed -n 's/.*\"id\":\([0-9]\+\).*/\1/p' | sed -n '2p')
fi
if [[ -z "${id2:-}" || -z "${id3:-}" ]]; then echo "Failed to parse todo ids"; exit 1; fi
if [[ "$id2" -gt "$id3" ]]; then echo "Order not ascending"; exit 1; fi

# Test 404 for other users' todo access
# Register second user
curl -s -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password123"}' >/dev/null
# Login as second user
curl -s -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password123"}' >/dev/null
# Try to fetch first user's todo id 2
status=$(status_of "$BASE/todos/2" -b "$COOKIE_JAR")
[[ "$status" == "404" ]]

echo "All tests passed"