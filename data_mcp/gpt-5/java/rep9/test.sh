#!/usr/bin/env bash
set -euo pipefail
PORT=${1:-8085}
BASE="http://127.0.0.1:$PORT"

# Start server
./run.sh --port "$PORT" &
PID=$!
sleep 1
trap 'kill $PID 2>/dev/null || true' EXIT

j() { jq -r .; }

echo "== Register user =="
code=$(curl -s -o /tmp/reg.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/register")
cat /tmp/reg.json | j || true
[[ "$code" == "201" ]]

# Duplicate username
code=$(curl -s -o /tmp/reg2.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/register")
[[ "$code" == "409" ]]

# Login
cookie=$(mktemp)
code=$(curl -s -o /tmp/login.json -c "$cookie" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/login")
cat /tmp/login.json | j || true
[[ "$code" == "200" ]]

# /me
code=$(curl -s -o /tmp/me.json -b "$cookie" -w "%{http_code}" "$BASE/me")
cat /tmp/me.json | j || true
[[ "$code" == "200" ]]

# Change password invalid old
code=$(curl -s -o /tmp/pwbad.json -b "$cookie" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword"}' "$BASE/password")
[[ "$code" == "401" ]]

# Change password success
code=$(curl -s -o /tmp/pwok.json -b "$cookie" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword"}' "$BASE/password")
[[ "$code" == "200" ]]

# Re-login with new password to ensure old session still valid but let's create new cookie
cookie2=$(mktemp)
code=$(curl -s -o /tmp/login2.json -c "$cookie2" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword"}' "$BASE/login")
[[ "$code" == "200" ]]

# Create todo
code=$(curl -s -o /tmp/t1.json -b "$cookie2" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"desc"}' "$BASE/todos")
cat /tmp/t1.json | j || true
[[ "$code" == "201" ]]

# List todos
code=$(curl -s -o /tmp/list.json -b "$cookie2" -w "%{http_code}" "$BASE/todos")
cat /tmp/list.json | j || true
[[ "$code" == "200" ]]

# Get todo 1
code=$(curl -s -o /tmp/get1.json -b "$cookie2" -w "%{http_code}" "$BASE/todos/1")
cat /tmp/get1.json | j || true
[[ "$code" == "200" ]]

# Update todo 1 partial
code=$(curl -s -o /tmp/upd1.json -b "$cookie2" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"completed":true}' "$BASE/todos/1")
cat /tmp/upd1.json | j || true
[[ "$code" == "200" ]]

# Delete todo 1
code=$(curl -s -o /tmp/del1.txt -b "$cookie2" -w "%{http_code}" -X DELETE "$BASE/todos/1")
[[ "$code" == "204" ]]

# Get deleted -> 404
code=$(curl -s -o /tmp/get404.json -b "$cookie2" -w "%{http_code}" "$BASE/todos/1")
[[ "$code" == "404" ]]

# Logout
code=$(curl -s -o /tmp/logout.json -b "$cookie2" -w "%{http_code}" -X POST "$BASE/logout")
[[ "$code" == "200" ]]

# Use same cookie -> should be 401
code=$(curl -s -o /tmp/me2.json -b "$cookie2" -w "%{http_code}" "$BASE/me")
[[ "$code" == "401" ]]

echo "All tests passed"
