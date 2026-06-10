#!/usr/bin/env bash
set -euo pipefail
PORT=$(shuf -i 12000-20000 -n 1)
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)

echo "Building..."
go build -o server .

# Start server
./server --port "$PORT" &
PID=$!
sleep 0.5
trap 'kill $PID 2>/dev/null || true; rm -f "$COOKIE_JAR"' EXIT

jget() { curl -sS -b "$COOKIE_JAR" -H 'Accept: application/json' "$@"; }
jpost() { curl -sS -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json' -H 'Accept: application/json' -X POST "$@"; }
jput() { curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -H 'Accept: application/json' -X PUT "$@"; }
jdel() { curl -sS -b "$COOKIE_JAR" -H 'Accept: application/json' -X DELETE "$@"; }

# Helper to get HTTP status code
status() { curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" "$@"; }
status_post() { curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json' -X POST "$@"; }
status_put() { curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT "$@"; }
status_delete() { curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -X DELETE "$@"; }

# Unauthorized access
code=$(status "$BASE/me")
[[ "$code" == "401" ]] || { echo "Expected 401 for /me, got $code"; exit 1; }

# Register
resp=$(jpost "$BASE/register" -d '{"username":"user_one","password":"password1"}')
# Extract id from JSON
id=$(echo "$resp" | sed -E 's/.*"id"\s*:\s*([0-9]+).*/\1/')
[[ "$id" == "1" ]] || { echo "Expected user id 1, got $id"; echo "$resp"; exit 1; }

# Duplicate username
code=$(status_post "$BASE/register" -d '{"username":"user_one","password":"password1"}')
[[ "$code" == "409" ]] || { echo "Expected 409 duplicate, got $code"; exit 1; }

# Login
code=$(status_post "$BASE/login" -d '{"username":"user_one","password":"password1"}')
[[ "$code" == "200" ]] || { echo "Expected 200 login, got $code"; exit 1; }

# Me
code=$(status "$BASE/me")
[[ "$code" == "200" ]] || { echo "Expected 200 me, got $code"; exit 1; }

# Create todos
resp=$(jpost "$BASE/todos" -d '{"title":"Task A","description":"First"}')
id1=$(echo "$resp" | sed -E 's/.*"id"\s*:\s*([0-9]+).*/\1/')
resp=$(jpost "$BASE/todos" -d '{"title":"Task B"}')
id2=$(echo "$resp" | sed -E 's/.*"id"\s*:\s*([0-9]+).*/\1/')

# List should have 2
list=$(jget "$BASE/todos")
count=$(echo "$list" | grep -o '\{' | wc -l | awk '{print $1}')
[[ "$count" == "2" ]] || { echo "Expected 2 todos, got $count"; echo "$list"; exit 1; }

# Get by id
code=$(status "$BASE/todos/$id1")
[[ "$code" == "200" ]] || { echo "Expected 200 get todo, got $code"; exit 1; }

# Update partial
resp=$(jput "$BASE/todos/$id1" -d '{"completed":true}')
comp=$(echo "$resp" | sed -E 's/.*"completed"\s*:\s*(true|false).*/\1/')
[[ "$comp" == "true" ]] || { echo "Expected completed true, got $comp"; echo "$resp"; exit 1; }

# Update title empty -> 400
code=$(status_put "$BASE/todos/$id1" -d '{"title":""}')
[[ "$code" == "400" ]] || { echo "Expected 400 empty title, got $code"; exit 1; }

# Delete
code=$(status_delete "$BASE/todos/$id2")
[[ "$code" == "204" ]] || { echo "Expected 204 delete, got $code"; exit 1; }

# Password change wrong old -> 401
code=$(status_put "$BASE/password" -d '{"old_password":"wrong","new_password":"newpassword"}')
[[ "$code" == "401" ]] || { echo "Expected 401 wrong old password, got $code"; exit 1; }

# Password change success
code=$(status_put "$BASE/password" -d '{"old_password":"password1","new_password":"newpass123"}')
[[ "$code" == "200" ]] || { echo "Expected 200 password change, got $code"; exit 1; }

# Logout
code=$(status_post "$BASE/logout" -d '')
[[ "$code" == "200" ]] || { echo "Expected 200 logout, got $code"; exit 1; }

# Auth should now fail
code=$(status "$BASE/me")
[[ "$code" == "401" ]] || { echo "Expected 401 after logout, got $code"; exit 1; }

echo "All tests passed."
