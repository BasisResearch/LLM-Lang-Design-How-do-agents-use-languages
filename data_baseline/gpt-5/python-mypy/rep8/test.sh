#!/bin/sh
set -eu
PORT=8765
./run.sh --port "$PORT" &
PID=$!
trap 'kill "$PID"' EXIT
# Wait for server
for i in `seq 1 50`; do
  if curl -sS "http://127.0.0.1:$PORT/me" -H 'Accept: application/json' -c /tmp/cookiejar.txt -b /tmp/cookiejar.txt >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

base="http://127.0.0.1:$PORT"

# Helper to send JSON with cookies
cookiejar=$(mktemp)
trap 'rm -f "$cookiejar"; kill "$PID"' EXIT

echo "Testing register with invalid username (too short)"
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"ab","password":"password123"}' "$base/register")
[ "$code" = "400" ] || { echo "Expected 400, got $code"; exit 1; }

echo "Register user"
resp=$(curl -s -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' "$base/register")
echo "$resp" | grep '"id"' >/dev/null || { echo "Register failed: $resp"; exit 1; }

# Duplicate username
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' "$base/register")
[ "$code" = "409" ] || { echo "Expected 409, got $code"; exit 1; }

echo "Login with wrong password"
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"wrongpass"}' "$base/login")
[ "$code" = "401" ] || { echo "Expected 401, got $code"; exit 1; }

echo "Login with correct password"
resp=$(curl -i -s -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' "$base/login" -c "$cookiejar")
echo "$resp" | grep 'Set-Cookie: session_id=' >/dev/null || { echo "Login failed: $resp"; exit 1; }

echo "GET /me"
resp=$(curl -s -b "$cookiejar" "$base/me")
echo "$resp" | grep '"username":"alice_1"' >/dev/null || { echo "/me failed: $resp"; exit 1; }

echo "Change password with wrong old password"
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword"}' -b "$cookiejar" "$base/password")
[ "$code" = "401" ] || { echo "Expected 401, got $code"; exit 1; }

echo "Change password with short new password"
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' -b "$cookiejar" "$base/password")
[ "$code" = "400" ] || { echo "Expected 400, got $code"; exit 1; }

echo "Change password success"
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword"}' -b "$cookiejar" "$base/password")
[ "$code" = "200" ] || { echo "Expected 200, got $code"; exit 1; }

# Logout and ensure session invalidated
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -b "$cookiejar" "$base/logout")
[ "$code" = "200" ] || { echo "Expected 200 logout, got $code"; exit 1; }

code=$(curl -s -o /dev/null -w "%{http_code}" -b "$cookiejar" "$base/me")
[ "$code" = "401" ] || { echo "Expected 401 after logout, got $code"; exit 1; }

# Login again with new password
resp=$(curl -i -s -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"newpassword"}' "$base/login" -c "$cookiejar")
echo "$resp" | grep 'Set-Cookie: session_id=' >/dev/null || { echo "Re-login failed: $resp"; exit 1; }

# Create todo missing title
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"description":"desc"}' -b "$cookiejar" "$base/todos")
[ "$code" = "400" ] || { echo "Expected 400, got $code"; exit 1; }

# Create valid todo
resp=$(curl -s -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"First"}' -b "$cookiejar" "$base/todos")
echo "$resp" | grep '"id":1' >/dev/null || { echo "Create todo failed: $resp"; exit 1; }

# List todos
resp=$(curl -s -b "$cookiejar" "$base/todos")
echo "$resp" | grep '"title":"Task 1"' >/dev/null || { echo "List todos failed: $resp"; exit 1; }

# Get todo 1
resp=$(curl -s -b "$cookiejar" "$base/todos/1")
echo "$resp" | grep '"id":1' >/dev/null || { echo "Get todo failed: $resp"; exit 1; }

# Update todo 1 title
resp=$(curl -s -X PUT -H 'Content-Type: application/json' -d '{"title":"Task 1 updated","completed":true}' -b "$cookiejar" "$base/todos/1")
echo "$resp" | grep '"title":"Task 1 updated"' >/dev/null || { echo "Update todo failed: $resp"; exit 1; }

# Delete todo 1
code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -b "$cookiejar" "$base/todos/1")
[ "$code" = "204" ] || { echo "Expected 204, got $code"; exit 1; }

# Ensure get after delete is 404
code=$(curl -s -o /dev/null -w "%{http_code}" -b "$cookiejar" "$base/todos/1")
[ "$code" = "404" ] || { echo "Expected 404, got $code"; exit 1; }

echo "All tests passed"
