#!/usr/bin/env bash
set -euo pipefail
PORT=$(( 20000 + (RANDOM % 20000) ))
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; if [[ -n "${PID:-}" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi }
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" &
PID=$!

# Wait for server ready
for i in {1..50}; do
  if curl -sS -o /dev/null "$BASE/me"; then break; fi
  sleep 0.1
done

fail() { echo "TEST FAILED: $*"; exit 1; }

# Register
echo "Register user"
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/register")
[[ "$code" == "201" ]] || fail "register status $code"

# Duplicate username
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/register" || true)
[[ "$code" == "409" ]] || fail "duplicate register status $code"

# Login
echo "Login"
code=$(curl -sS -D headers.txt -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/login")
[[ "$code" == "200" ]] || fail "login status $code"

# Me
echo "Me"
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" "$BASE/me")
[[ "$code" == "200" ]] || fail "/me status $code"

# Password change validations
echo "Password change wrong old"
code=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword1"}' -o /dev/null -w "%{http_code}" -X PUT "$BASE/password")
[[ "$code" == "401" ]] || fail "password change wrong old status $code"

echo "Password change too short"
code=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' -o /dev/null -w "%{http_code}" -X PUT "$BASE/password")
[[ "$code" == "400" ]] || fail "password change too short status $code"

echo "Password change success"
code=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword1"}' -o /dev/null -w "%{http_code}" -X PUT "$BASE/password")
[[ "$code" == "200" ]] || fail "password change status $code"

# Create todo
echo "Create todo"
code=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"First","description":"desc"}' -o /dev/null -w "%{http_code}" "$BASE/todos")
[[ "$code" == "201" ]] || fail "create todo status $code"

# List todos
echo "List todos"
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" "$BASE/todos")
[[ "$code" == "200" ]] || fail "list todos status $code"

# Get todo 1
echo "Get todo 1"
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" "$BASE/todos/1")
[[ "$code" == "200" ]] || fail "get todo status $code"

# Update todo 1
echo "Update todo 1"
code=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"completed": true}' -o /dev/null -w "%{http_code}" -X PUT "$BASE/todos/1")
[[ "$code" == "200" ]] || fail "update todo status $code"

# Delete todo 1
echo "Delete todo 1"
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X DELETE "$BASE/todos/1")
[[ "$code" == "204" ]] || fail "delete todo status $code"

# 404 after delete
echo "Get deleted should 404"
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" "$BASE/todos/1" || true)
[[ "$code" == "404" ]] || fail "get deleted todo status $code"

# Logout
echo "Logout"
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X POST "$BASE/logout")
[[ "$code" == "200" ]] || fail "logout status $code"

# Auth after logout should fail
echo "Auth after logout should fail"
code=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" "$BASE/me" || true)
[[ "$code" == "401" ]] || fail "/me after logout status $code"

# Login with old password should fail
echo "Login with old password should fail"
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/login" || true)
[[ "$code" == "401" ]] || fail "login old password status $code"

# Login with new password should succeed
echo "Login with new password should succeed"
code=$(curl -sS -D headers2.txt -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword1"}' "$BASE/login")
[[ "$code" == "200" ]] || fail "login new password status $code"

echo "All tests passed"