#!/usr/bin/env bash
set -euo pipefail

# Pick a random high port to avoid conflicts with stale servers
PORT=$(( (RANDOM % 10000) + 30000 ))
SERVER_LOG=server.log
./run.sh --port "$PORT" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

# Wait for server to be ready
base="http://127.0.0.1:$PORT"
for i in {1..50}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/me" || true)
  if [[ "$code" = "401" || "$code" = "200" || "$code" = "400" ]]; then
    break
  fi
  sleep 0.1
  if [[ $i -eq 50 ]]; then
    echo "Server failed to start" >&2
    exit 1
  fi
done

# helper to extract cookies and reuse
COOKIE_JAR=$(mktemp)

# Register user
res=$(curl -s -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_01","password":"supersecret"}')
[ "$(echo "$res" | jq -r .username)" = "alice_01" ]

# Duplicate username
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_01","password":"anotherpass"}')
[ "$code" = "409" ]

# Login
res=$(curl -s -c "$COOKIE_JAR" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_01","password":"supersecret"}')
[ "$(echo "$res" | jq -r .id)" = "1" ]

# /me
res=$(curl -s -b "$COOKIE_JAR" "$base/me")
[ "$(echo "$res" | jq -r .username)" = "alice_01" ]

# Change password wrong old
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X PUT "$base/password" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword"}')
[ "$code" = "401" ]

# Change password ok
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X PUT "$base/password" -H 'Content-Type: application/json' -d '{"old_password":"supersecret","new_password":"newpassword"}')
[ "$code" = "200" ]

# Create todo without title
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"description":"no title"}')
[ "$code" = "400" ]

# Create todos
res=$(curl -s -b "$COOKIE_JAR" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"First"}')
id1=$(echo "$res" | jq -r .id)
res=$(curl -s -b "$COOKIE_JAR" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"Task 2"}')
id2=$(echo "$res" | jq -r .id)

# List todos
res=$(curl -s -b "$COOKIE_JAR" "$base/todos")
count=$(echo "$res" | jq 'length')
[ "$count" = "2" ]

# Get todo
res=$(curl -s -b "$COOKIE_JAR" "$base/todos/$id1")
[ "$(echo "$res" | jq -r .title)" = "Task 1" ]

# Update todo partial
res=$(curl -s -b "$COOKIE_JAR" -X PUT "$base/todos/$id1" -H 'Content-Type: application/json' -d '{"completed":true}')
[ "$(echo "$res" | jq -r .completed)" = "true" ]

# Delete todo
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X DELETE "$base/todos/$id2")
[ "$code" = "204" ]

# Verify list now 1
res=$(curl -s -b "$COOKIE_JAR" "$base/todos")
count=$(echo "$res" | jq 'length')
[ "$count" = "1" ]

# Logout
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X POST "$base/logout")
[ "$code" = "200" ]

# Access after logout should be 401
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$base/me")
[ "$code" = "401" ]

echo "All tests passed"
