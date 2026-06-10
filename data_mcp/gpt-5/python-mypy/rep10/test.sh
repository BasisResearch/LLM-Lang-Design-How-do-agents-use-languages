#!/usr/bin/env bash
set -euo pipefail

PORT=8765

# Start server in background
./run.sh --port "$PORT" &
SERVER_PID=$!

cleanup() {
  kill $SERVER_PID >/dev/null 2>&1 || true
}
trap cleanup EXIT

# wait for server to start
for i in {1..50}; do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/me"; then
    break
  fi
  sleep 0.1
done

base="http://127.0.0.1:$PORT"

# Helper to extract cookie
COOKIE_JAR=$(mktemp)

echo "Register user"
RESP=$(curl -s -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
[[ $(echo "$RESP" | jq -r '.username') == "alice" ]]

# duplicate username should 409
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
[[ "$CODE" == "409" ]]

echo "Login user"
RESP=$(curl -s -D headers.txt -c "$COOKIE_JAR" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
[[ $(echo "$RESP" | jq -r '.username') == "alice" ]]

SESSION=$(grep -i session_id "$COOKIE_JAR" | awk '{print $7}')
[[ -n "$SESSION" ]]

echo "Get /me"
RESP=$(curl -s -b "$COOKIE_JAR" "$base/me")
[[ $(echo "$RESP" | jq -r '.username') == "alice" ]]

echo "Change password with wrong old password should 401"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X PUT "$base/password" -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword123"}')
[[ "$CODE" == "401" ]]

echo "Change password correctly"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X PUT "$base/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$CODE" == "200" ]]

# Login with old password should 401
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
[[ "$CODE" == "401" ]]

echo "Login with new password"
RESP=$(curl -s -D headers2.txt -c "$COOKIE_JAR" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"newpassword123"}')
[[ $(echo "$RESP" | jq -r '.username') == "alice" ]]

# Create todo without title should 400
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"description":"test"}')
[[ "$CODE" == "400" ]]

# Create todo
RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"First"}')
ID1=$(echo "$RESP" | jq -r '.id')

RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"Task 2"}')
ID2=$(echo "$RESP" | jq -r '.id')

# List todos
RESP=$(curl -s -b "$COOKIE_JAR" "$base/todos")
COUNT=$(echo "$RESP" | jq 'length')
[[ "$COUNT" -eq 2 ]]

# Get one
RESP=$(curl -s -b "$COOKIE_JAR" "$base/todos/$ID1")
[[ $(echo "$RESP" | jq -r '.title') == "Task 1" ]]

# Update partial
RESP=$(curl -s -b "$COOKIE_JAR" -X PUT "$base/todos/$ID1" -H 'Content-Type: application/json' -d '{"completed":true}')
[[ $(echo "$RESP" | jq -r '.completed') == "true" ]]

# Update title validation
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X PUT "$base/todos/$ID1" -H 'Content-Type: application/json' -d '{"title":""}')
[[ "$CODE" == "400" ]]

# Delete
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X DELETE "$base/todos/$ID2")
[[ "$CODE" == "204" ]]

# Ensure deleted not visible
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$base/todos/$ID2")
[[ "$CODE" == "404" ]]

# Logout
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X POST "$base/logout")
[[ "$CODE" == "200" ]]

# Using same cookie again should 401 as invalidated
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$base/me")
[[ "$CODE" == "401" ]]

echo "All tests passed"
