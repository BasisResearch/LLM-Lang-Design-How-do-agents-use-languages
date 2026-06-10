#!/usr/bin/env bash
set -euo pipefail
PORT=8090
COOKIE_JAR=$(mktemp)
COOKIE_JAR2=$(mktemp)
cleanup() {
  rm -f "$COOKIE_JAR" "$COOKIE_JAR2"
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
  fi
}
trap cleanup EXIT

./run.sh --port $PORT &
SERVER_PID=$!
# Wait for server
for i in {1..50}; do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/register"; then
    break
  fi
  sleep 0.1
done

# 1) GET /me unauthorized
echo "1) GET /me unauthorized"
code=$(curl -s -o /tmp/body1 -w "%{http_code}" -b "$COOKIE_JAR" http://127.0.0.1:$PORT/me)
[[ "$code" == "401" ]]
grep -q 'Authentication required' /tmp/body1

# Register invalid username
echo "2) POST /register invalid username"
code=$(curl -s -o /tmp/body2 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"ab","password":"secret123"}' http://127.0.0.1:$PORT/register)
[[ "$code" == "400" ]]
grep -q 'Invalid username' /tmp/body2

# Register valid
echo "3) POST /register valid"
code=$(curl -s -D /tmp/headers3 -o /tmp/body3 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"john_doe","password":"secret123"}' http://127.0.0.1:$PORT/register)
[[ "$code" == "201" ]]
grep -iq '^content-type: application/json' /tmp/headers3
grep -q '"username":"john_doe"' /tmp/body3

# Register duplicate
echo "4) POST /register duplicate"
code=$(curl -s -o /tmp/body4 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"john_doe","password":"secret123"}' http://127.0.0.1:$PORT/register)
[[ "$code" == "409" ]]

# Login wrong
echo "5) POST /login wrong password"
code=$(curl -s -o /tmp/body5 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"john_doe","password":"wrongpass"}' http://127.0.0.1:$PORT/login)
[[ "$code" == "401" ]]

# Login correct
echo "6) POST /login correct"
code=$(curl -s -D /tmp/headers6 -b "$COOKIE_JAR" -c "$COOKIE_JAR" -o /tmp/body6 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"john_doe","password":"secret123"}' http://127.0.0.1:$PORT/login)
[[ "$code" == "200" ]]
grep -i '^set-cookie: session_id=' /tmp/headers6 >/dev/null

# Me
echo "7) GET /me"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body7 -w "%{http_code}" http://127.0.0.1:$PORT/me)
[[ "$code" == "200" ]]
grep -q '"username":"john_doe"' /tmp/body7

# Password change invalid old
echo "8) PUT /password wrong old"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body8 -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newsecret1"}' http://127.0.0.1:$PORT/password)
[[ "$code" == "401" ]]

# Password too short
echo "9) PUT /password too short"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body9 -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"secret123","new_password":"short"}' http://127.0.0.1:$PORT/password)
[[ "$code" == "400" ]]

# Password change success
echo "10) PUT /password success"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body10 -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"secret123","new_password":"newsecret1"}' http://127.0.0.1:$PORT/password)
[[ "$code" == "200" ]]

# Logout
echo "11) POST /logout"
code=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" -o /tmp/body11 -w "%{http_code}" -X POST http://127.0.0.1:$PORT/logout)
[[ "$code" == "200" ]]

# Me should be 401 now
echo "12) GET /me after logout -> 401"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body12 -w "%{http_code}" http://127.0.0.1:$PORT/me)
[[ "$code" == "401" ]]

# Login with new password
echo "13) POST /login with new password"
code=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" -o /tmp/body13 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"john_doe","password":"newsecret1"}' http://127.0.0.1:$PORT/login)
[[ "$code" == "200" ]]

# Todos list empty
echo "14) GET /todos empty"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body14 -w "%{http_code}" http://127.0.0.1:$PORT/todos)
[[ "$code" == "200" ]]

# Create todo missing title
echo "15) POST /todos missing title"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body15 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"description":"desc"}' http://127.0.0.1:$PORT/todos)
[[ "$code" == "400" ]]

# Create todo ok
echo "16) POST /todos create"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body16 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"First"}' http://127.0.0.1:$PORT/todos)
[[ "$code" == "201" ]]

echo "Extracting TODO_ID"
TODO_ID=$(sed -n 's/.*"id":\([0-9]*\).*/\1/p' /tmp/body16)
[[ -n "$TODO_ID" ]]

# List todos has one
echo "17) GET /todos has one"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body17 -w "%{http_code}" http://127.0.0.1:$PORT/todos)
[[ "$code" == "200" ]]
grep -q '"id":'$TODO_ID /tmp/body17

# Get todo by id
echo "18) GET /todos/$TODO_ID"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body18 -w "%{http_code}" http://127.0.0.1:$PORT/todos/$TODO_ID)
[[ "$code" == "200" ]]

# Update todo completed true
echo "19) PUT /todos/$TODO_ID set completed"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body19 -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"completed":true}' http://127.0.0.1:$PORT/todos/$TODO_ID)
[[ "$code" == "200" ]]
grep -q '"completed":true' /tmp/body19

# Delete todo
echo "20) DELETE /todos/$TODO_ID"
code=$(curl -s -D /tmp/headers20 -o /tmp/body20 -w "%{http_code}" -X DELETE -b "$COOKIE_JAR" http://127.0.0.1:$PORT/todos/$TODO_ID)
[[ "$code" == "204" ]]
[[ ! -s /tmp/body20 ]]

# Get deleted -> 404
echo "21) GET deleted -> 404"
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body21 -w "%{http_code}" http://127.0.0.1:$PORT/todos/$TODO_ID)
[[ "$code" == "404" ]]

# Create second user and ensure isolation
echo "22) Register and login second user"
code=$(curl -s -o /tmp/body22 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"passpass1"}' http://127.0.0.1:$PORT/register)
[[ "$code" == "201" ]]
code=$(curl -s -b "$COOKIE_JAR2" -c "$COOKIE_JAR2" -o /tmp/body23 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"passpass1"}' http://127.0.0.1:$PORT/login)
[[ "$code" == "200" ]]

# Create todo as user1 again
code=$(curl -s -b "$COOKIE_JAR" -o /tmp/body24 -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"U1 Task","description":"D"}' http://127.0.0.1:$PORT/todos)
[[ "$code" == "201" ]]
U1_TODO=$(sed -n 's/.*"id":\([0-9]*\).*/\1/p' /tmp/body24)
[[ -n "$U1_TODO" ]]

# Try to access user1's todo as user2 -> 404
echo "23) Cross-user access should 404"
code=$(curl -s -b "$COOKIE_JAR2" -o /tmp/body25 -w "%{http_code}" http://127.0.0.1:$PORT/todos/$U1_TODO)
[[ "$code" == "404" ]]

# All tests passed
echo "All tests passed"
