#!/usr/bin/env bash
set -euo pipefail
PORT=3456
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID || true' EXIT

wait_for() {
  for i in {1..50}; do
    if curl -sS "http://127.0.0.1:$PORT/me" -o /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for || true

base="http://127.0.0.1:$PORT"

# Register
resp=$(curl -s -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/register")
body=$(echo "$resp" | head -n1)
code=$(echo "$resp" | tail -n1)
[ "$code" = "201" ] || { echo "Register failed: $resp"; exit 1; }

# Duplicate register should 409
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/register")
[ "$code" = "409" ] || { echo "Duplicate register status $code"; exit 1; }

# Login wrong
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"wrongpass"}' "$base/login")
[ "$code" = "401" ] || { echo "Login wrong status $code"; exit 1; }

# Login OK
login_headers=$(mktemp)
login_body=$(curl -s -D "$login_headers" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/login")
[ -n "$login_body" ] || { echo "Empty login body"; exit 1; }
session=$(grep -i '^Set-Cookie:' "$login_headers" | grep -o 'session_id=[^;]*' | head -n1 | cut -d= -f2)
[ -n "$session" ] || { echo "No session cookie"; exit 1; }
COOKIE="session_id=$session"

# /me
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" "$base/me")
[ "$code" = "200" ] || { echo "/me status $code"; exit 1; }

# Change password wrong old
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -X PUT -d '{"old_password":"bad","new_password":"newpassword"}' "$base/password")
[ "$code" = "401" ] || { echo "change password wrong old $code"; exit 1; }

# Change password short new
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -X PUT -d '{"old_password":"password123","new_password":"short"}' "$base/password")
[ "$code" = "400" ] || { echo "change password short $code"; exit 1; }

# Change password ok
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -X PUT -d '{"old_password":"password123","new_password":"newpassword"}' "$base/password")
[ "$code" = "200" ] || { echo "change password ok $code"; exit 1; }

# Logout
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" -X POST "$base/logout")
[ "$code" = "200" ] || { echo "logout $code"; exit 1; }

# After logout, /me should 401
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" "$base/me")
[ "$code" = "401" ] || { echo "/me after logout $code"; exit 1; }

# Login again with new password
login_headers=$(mktemp)
login_body=$(curl -s -D "$login_headers" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword"}' "$base/login")
session=$(grep -i '^Set-Cookie:' "$login_headers" | grep -o 'session_id=[^;]*' | head -n1 | cut -d= -f2)
COOKIE="session_id=$session"

# List todos empty
resp=$(curl -s -H "Cookie: $COOKIE" "$base/todos")
[ "$resp" = "[]" ] || { echo "todos not empty: $resp"; exit 1; }

# Create todo missing title
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"description":"desc"}' "$base/todos")
[ "$code" = "400" ] || { echo "create missing title $code"; exit 1; }

# Create todo ok
resp=$(curl -s -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":"Task 1","description":"First"}' "$base/todos")
id=$(echo "$resp" | jq -r '.id')
[ "$id" != "null" ] || { echo "create todo bad resp $resp"; exit 1; }

# Get todo
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" "$base/todos/$id")
[ "$code" = "200" ] || { echo "get todo $code"; exit 1; }

# Update todo empty title error
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -X PUT -d '{"title":""}' "$base/todos/$id")
[ "$code" = "400" ] || { echo "update empty title $code"; exit 1; }

# Update todo completed true
resp=$(curl -s -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -X PUT -d '{"completed":true}' "$base/todos/$id")
comp=$(echo "$resp" | jq -r '.completed')
[ "$comp" = "true" ] || { echo "update not true: $resp"; exit 1; }

# Delete nonexistent another user id 9999 -> 404
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" -X DELETE "$base/todos/9999")
[ "$code" = "404" ] || { echo "delete nonexistent $code"; exit 1; }

# Delete ok
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" -X DELETE "$base/todos/$id")
[ "$code" = "204" ] || { echo "delete ok $code"; exit 1; }

# Confirm delete
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" "$base/todos/$id")
[ "$code" = "404" ] || { echo "get after delete $code"; exit 1; }

echo "All tests passed"
