#!/usr/bin/env bash
set -euo pipefail
PORT=18080
COOKIE_JAR=$(mktemp)
SERVER_LOG=$(mktemp)

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  rm -f "$COOKIE_JAR" "$SERVER_LOG"
}
trap cleanup EXIT

./run.sh --port "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
# Wait for server
sleep 1

base="http://127.0.0.1:${PORT}"

# 1) Register
resp=$(curl -sS -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ $(echo "$resp" | jq -r .username) == "user_1" ]]

# 1b) Register duplicate -> 409
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ "$code" == "409" ]]

# 2) Login
resp=$(curl -sS -c "$COOKIE_JAR" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ $(echo "$resp" | jq -r .username) == "user_1" ]]

# 3) /me
resp=$(curl -sS -b "$COOKIE_JAR" "$base/me")
[[ $(echo "$resp" | jq -r .username) == "user_1" ]]

# 4) Change password
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X PUT "$base/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword456"}')
[[ "$code" == "200" ]]

# 5) Create todos
resp=$(curl -sS -b "$COOKIE_JAR" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"A","description":"D1"}')
id1=$(echo "$resp" | jq -r .id)
resp=$(curl -sS -b "$COOKIE_JAR" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"B"}')
id2=$(echo "$resp" | jq -r .id)

# 6) List todos
resp=$(curl -sS -b "$COOKIE_JAR" "$base/todos")
count=$(echo "$resp" | jq 'length')
[[ "$count" -ge 2 ]]

# 7) Get todo by id
resp=$(curl -sS -b "$COOKIE_JAR" "$base/todos/$id1")
[[ $(echo "$resp" | jq -r .title) == "A" ]]

# 8) Update todo
resp=$(curl -sS -b "$COOKIE_JAR" -X PUT "$base/todos/$id1" -H 'Content-Type: application/json' -d '{"completed":true,"title":"A2"}')
[[ $(echo "$resp" | jq -r .completed) == "true" ]]
[[ $(echo "$resp" | jq -r .title) == "A2" ]]

# 9) Delete todo
code=$(curl -s -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X DELETE "$base/todos/$id2")
[[ "$code" == "204" ]]

# 10) Logout
code=$(curl -s -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X POST "$base/logout")
[[ "$code" == "200" ]]

# 11) Access after logout should be 401
code=$(curl -s -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' "$base/me")
[[ "$code" == "401" ]]

echo "All tests passed"
