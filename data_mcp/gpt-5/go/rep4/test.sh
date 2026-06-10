#!/usr/bin/env bash
set -euo pipefail

PORT=8090

./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID || true' EXIT

# Wait for server
for i in {1..50}; do
  if curl -sSf http://127.0.0.1:$PORT/nonexistent >/dev/null; then
    break
  fi
  sleep 0.1
done

base=http://127.0.0.1:$PORT

hdr() { echo -e "\n==== $1 ====" >&2; }

# Register
hdr "Register user"
RESP=$(curl -s -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
echo "$RESP"

# Duplicate register should 409
hdr "Register duplicate"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[[ "$CODE" == "409" ]] || { echo "Expected 409, got $CODE"; exit 1; }

# Login
hdr "Login"
COOKIE_JAR=$(mktemp)
RESP=$(curl -s -c "$COOKIE_JAR" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
echo "$RESP"

# Me
hdr "Me"
RESP=$(curl -s -b "$COOKIE_JAR" "$base/me")
echo "$RESP"

# Change password
hdr "Change password"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X PUT "$base/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpass123"}')
echo "code=$CODE"
[[ "$CODE" == "200" ]]

# Create todo
hdr "Create todo"
RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"First","description":"Desc"}')
echo "$RESP"
ID=$(echo "$RESP" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')

# List todos
hdr "List todos"
RESP=$(curl -s -b "$COOKIE_JAR" "$base/todos")
echo "$RESP"

# Get todo
hdr "Get todo"
RESP=$(curl -s -b "$COOKIE_JAR" "$base/todos/$ID")
echo "$RESP"

# Update todo partial
hdr "Update todo"
RESP=$(curl -s -b "$COOKIE_JAR" -X PUT "$base/todos/$ID" -H 'Content-Type: application/json' -d '{"completed":true}')
echo "$RESP"

# Delete todo
hdr "Delete todo"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X DELETE "$base/todos/$ID")
echo "code=$CODE"
[[ "$CODE" == "204" ]]

# Ensure deleted
hdr "Get deleted -> 404"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$base/todos/$ID")
echo "code=$CODE"
[[ "$CODE" == "404" ]]

# Logout
hdr "Logout"
RESP=$(curl -s -b "$COOKIE_JAR" -X POST "$base/logout")
echo "$RESP"

# Access after logout -> 401
hdr "Access after logout"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$base/me")
echo "code=$CODE"
[[ "$CODE" == "401" ]]

# Done
kill $PID
trap - EXIT
