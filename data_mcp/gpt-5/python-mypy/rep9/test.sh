#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-8123}
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR="/tmp/todo_cookies_$$.txt"
trap 'rm -f "$COOKIE_JAR"; kill $SERVER_PID 2>/dev/null || true' EXIT

./run.sh --port "$PORT" &
SERVER_PID=$!
sleep 0.5

echo "== Register user1 =="
HTTP=$(curl -s -o /dev/stderr -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$BASE/register")
if [[ "$HTTP" != "201" ]]; then exit 1; fi

# Duplicate username
HTTP=$(curl -s -o /dev/stderr -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$BASE/register")
if [[ "$HTTP" != "409" ]]; then exit 1; fi

echo "== Login user1 =="
HTTP=$(curl -s -D /dev/stderr -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$BASE/login" -c "$COOKIE_JAR")
if [[ "$HTTP" != "200" ]]; then exit 1; fi

# /me
echo "== /me =="
HTTP=$(curl -s -b "$COOKIE_JAR" -o /dev/stderr -w "%{http_code}" "$BASE/me")
if [[ "$HTTP" != "200" ]]; then exit 1; fi

# Change password
echo "== change password =="
HTTP=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT -d '{"old_password":"password123","new_password":"newpassword456"}' -o /dev/stderr -w "%{http_code}" "$BASE/password")
if [[ "$HTTP" != "200" ]]; then exit 1; fi

# Logout
echo "== logout =="
HTTP=$(curl -s -b "$COOKIE_JAR" -o /dev/stderr -w "%{http_code}" -X POST "$BASE/logout")
if [[ "$HTTP" != "200" ]]; then exit 1; fi

# Access after logout should fail
echo "== /me after logout =="
HTTP=$(curl -s -b "$COOKIE_JAR" -o /dev/stderr -w "%{http_code}" "$BASE/me")
if [[ "$HTTP" != "401" ]]; then exit 1; fi

# Login again with new password
echo "== login with new password =="
HTTP=$(curl -s -D /dev/stderr -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpassword456"}' "$BASE/login" -c "$COOKIE_JAR")
if [[ "$HTTP" != "200" ]]; then exit 1; fi

# Create todos
echo "== create todos =="
HTTP=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Desc 1"}' -o /dev/stderr -w "%{http_code}" "$BASE/todos")
if [[ "$HTTP" != "201" ]]; then exit 1; fi
HTTP=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task 2"}' -o /dev/stderr -w "%{http_code}" "$BASE/todos")
if [[ "$HTTP" != "201" ]]; then exit 1; fi

# List todos
echo "== list todos =="
HTTP=$(curl -s -b "$COOKIE_JAR" -o /dev/stderr -w "%{http_code}" "$BASE/todos")
if [[ "$HTTP" != "200" ]]; then exit 1; fi

# Get todo 1
echo "== get todo 1 =="
HTTP=$(curl -s -b "$COOKIE_JAR" -o /dev/stderr -w "%{http_code}" "$BASE/todos/1")
if [[ "$HTTP" != "200" ]]; then exit 1; fi

# Update todo 1
echo "== update todo 1 =="
HTTP=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT -d '{"completed":true,"title":"Task 1 updated"}' -o /dev/stderr -w "%{http_code}" "$BASE/todos/1")
if [[ "$HTTP" != "200" ]]; then exit 1; fi

# Delete todo 2
echo "== delete todo 2 =="
HTTP=$(curl -s -b "$COOKIE_JAR" -o /dev/stderr -w "%{http_code}" -X DELETE "$BASE/todos/2")
if [[ "$HTTP" != "204" ]]; then exit 1; fi

# Get deleted todo -> 404
echo "== get deleted todo =="
HTTP=$(curl -s -b "$COOKIE_JAR" -o /dev/stderr -w "%{http_code}" "$BASE/todos/2")
if [[ "$HTTP" != "404" ]]; then exit 1; fi

echo "All tests passed"
