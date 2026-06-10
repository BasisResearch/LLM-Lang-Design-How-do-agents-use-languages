#!/usr/bin/env bash
set -euo pipefail
PORT=3456
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" &
PID=$!
sleep 0.5

fail() { echo "TEST FAILED: $1" >&2; kill $PID || true; exit 1; }

# Helper to curl with cookies
curlj() {
  curl -sS -D /tmp/headers.$$ -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json' "$@"
}

echo "Registering user..."
resp=$(curlj -X POST "$BASE/register" -d '{"username":"user_one","password":"password123"}')
echo "$resp" | grep -q '"id":1' || fail "register response incorrect: $resp"

# Duplicate username should 409
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/register" -d '{"username":"user_one","password":"password123"}')
[[ "$code" == "409" ]] || fail "expected 409 for duplicate username, got $code"

# Login
echo "Logging in..."
resp=$(curlj -X POST "$BASE/login" -d '{"username":"user_one","password":"password123"}')
echo "$resp" | grep -q '"username":"user_one"' || fail "login response incorrect: $resp"

# /me
echo "Checking /me..."
resp=$(curlj "$BASE/me")
echo "$resp" | grep -q '"id":1' || fail "/me incorrect: $resp"

# Change password with wrong old password -> 401
code=$(curlj -sS -o /dev/null -w "%{http_code}" -X PUT "$BASE/password" -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$code" == "401" ]] || fail "expected 401 for wrong old password, got $code"

# Change password success
code=$(curlj -sS -o /dev/null -w "%{http_code}" -X PUT "$BASE/password" -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]] || fail "expected 200 for password change, got $code"

# Create todo without title -> 400
code=$(curlj -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/todos" -d '{"description":"desc"}')
[[ "$code" == "400" ]] || fail "expected 400 for missing title, got $code"

# Create todo
resp=$(curlj -X POST "$BASE/todos" -d '{"title":"Task 1","description":"First"}')
echo "$resp" | grep -q '"id":1' || fail "todo create incorrect: $resp"

# Get todos
resp=$(curlj "$BASE/todos")
echo "$resp" | grep -F -q '[' || fail "todos list incorrect: $resp"

# Get todo by id
resp=$(curlj "$BASE/todos/1")
echo "$resp" | grep -q '"title":"Task 1"' || fail "todo get incorrect: $resp"

# Update todo partially
resp=$(curlj -X PUT "$BASE/todos/1" -d '{"completed":true}')
echo "$resp" | grep -q '"completed":true' || fail "todo update incorrect: $resp"

# Delete todo
code=$(curl -sS -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X DELETE "$BASE/todos/1" -o /dev/null -w "%{http_code}")
[[ "$code" == "204" ]] || fail "expected 204 for delete, got $code"

# Confirm not found after delete
code=$(curl -sS -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/todos/1" -o /dev/null -w "%{http_code}")
[[ "$code" == "404" ]] || fail "expected 404 after delete, got $code"

# Logout
code=$(curl -sS -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json' -X POST "$BASE/logout" -o /dev/null -w "%{http_code}")
[[ "$code" == "200" ]] || fail "expected 200 for logout, got $code"

# Ensure session invalidated
code=$(curl -sS -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/me" -o /dev/null -w "%{http_code}")
[[ "$code" == "401" ]] || fail "expected 401 after logout, got $code"

# Try login with new password works
resp=$(curlj -X POST "$BASE/login" -d '{"username":"user_one","password":"newpassword123"}')
echo "$resp" | grep -q '"id":1' || fail "re-login failed: $resp"

# Create todo 2
resp=$(curlj -X POST "$BASE/todos" -d '{"title":"Task 2"}')
echo "$resp" | grep -q '"id":2' || fail "todo2 create incorrect: $resp"

# Ensure DELETE returns no body
out=$(mktemp)
code=$(curl -sS -D "$out" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X DELETE "$BASE/todos/2" -o /dev/null -w "%{http_code}")
[[ "$code" == "204" ]] || fail "expected 204 for delete 2, got $code"
# Content-Type checks for JSON endpoints
ct=$(curl -sS -D - -o /dev/null -H 'Content-Type: application/json' "$BASE/me" -b "$COOKIE_JAR" -c "$COOKIE_JAR" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^content-type:/ {print tolower($0); exit}')
[[ "$ct" == "content-type: application/json" ]] || fail "Content-Type header incorrect: $ct"

# Stop server
kill $PID
wait $PID 2>/dev/null || true

echo "All tests passed"