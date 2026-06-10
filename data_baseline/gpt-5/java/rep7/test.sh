#!/usr/bin/env bash
set -euo pipefail
PORT=9096
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

echo "== Register user1 =="
curl -sS -D /tmp/h1 -o /tmp/b1 -X POST "$BASE/register" -H 'Content-Type: application/json' \
  -d '{"username":"user_one","password":"password123"}'
cat /tmp/b1; echo

# Duplicate username
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
echo "Duplicate register status: $code"

# Login
echo "== Login =="
curl -sS -D /tmp/headers_login -c "$COOKIE_JAR" -o /tmp/body_login -X POST "$BASE/login" -H 'Content-Type: application/json' \
  -d '{"username":"user_one","password":"password123"}'
cat /tmp/headers_login | tr -d '\r' | grep -i '^Set-Cookie' || true
cat /tmp/body_login; echo

# Me
echo "== Me =="
curl -sS -b "$COOKIE_JAR" "$BASE/me"; echo

# Change password
echo "== Change password =="
curl -sS -b "$COOKIE_JAR" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword456"}'

# Logout
echo "== Logout =="
curl -sS -b "$COOKIE_JAR" -X POST "$BASE/logout"; echo

# Access after logout should 401
code=$(curl -s -o /tmp/after_logout -w '%{http_code}' -b "$COOKIE_JAR" "$BASE/me")
echo "After logout status: $code"
cat /tmp/after_logout; echo

# Login again with new password
curl -sS -D /tmp/headers_login2 -c "$COOKIE_JAR" -o /tmp/body_login2 -X POST "$BASE/login" -H 'Content-Type: application/json' \
  -d '{"username":"user_one","password":"newpassword456"}'

# Create todos
echo "== Create todos =="
curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Desc1"}' "$BASE/todos" -X POST; echo
curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task 2"}' "$BASE/todos" -X POST; echo

# List todos
echo "== List todos =="
curl -sS -b "$COOKIE_JAR" "$BASE/todos"; echo

# Get todo 1
echo "== Get todo 1 =="
curl -sS -b "$COOKIE_JAR" "$BASE/todos/1"; echo

# Update todo 1
echo "== Update todo 1 =="
curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT -d '{"completed":true, "description":"Updated"}' "$BASE/todos/1"; echo

# Get updated todo 1
curl -sS -b "$COOKIE_JAR" "$BASE/todos/1"; echo

# Delete todo 1
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X DELETE "$BASE/todos/1")
echo "Delete status: $code"

# Get deleted should 404
code=$(curl -s -o /tmp/td404 -w '%{http_code}' -b "$COOKIE_JAR" "$BASE/todos/1")
echo "Get after delete status: $code"
cat /tmp/td404; echo

# Register and login another user
curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password123"}' >/dev/null
curl -sS -D /tmp/headers_login3 -c /tmp/cj2 -o /tmp/body_login3 -X POST "$BASE/login" -H 'Content-Type: application/json' \
  -d '{"username":"user_two","password":"password123"}' >/dev/null

# Try to access user_one's remaining todo (id 2) should 404
code=$(curl -s -o /tmp/oth -w '%{http_code}' -b /tmp/cj2 "$BASE/todos/2")
echo "Cross access status: $code"
cat /tmp/oth; echo

echo "All tests executed"