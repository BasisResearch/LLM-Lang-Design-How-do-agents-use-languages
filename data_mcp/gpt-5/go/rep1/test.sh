#!/usr/bin/env bash
set -euo pipefail
PORT=19321
COOKIE1="cookie1.txt"
COOKIE2="cookie2.txt"
HDR="headers.txt"
BODY="body.txt"

rm -f "$COOKIE1" "$COOKIE2" "$HDR" "$BODY"

./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# Wait for server
for i in {1..50}; do
  if curl -s "http://127.0.0.1:$PORT/me" -o /dev/null; then
    break
  fi
  sleep 0.1
done

echo "Testing /register"
# Valid register
code=$(curl -s -S -D "$HDR" -o "$BODY" -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' --data '{"username":"alice","password":"password123"}' -w "%{http_code}")
[[ "$code" == "201" ]]
[[ $(grep -i '^content-type: ' "$HDR" | tr -d '\r' | awk '{print tolower($0)}') == *"application/json"* ]]
[[ $(cat "$BODY") == *'"username":"alice"'* ]]

# Duplicate
code=$(curl -s -S -D "$HDR" -o "$BODY" -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' --data '{"username":"alice","password":"password123"}' -w "%{http_code}")
[[ "$code" == "409" ]]
[[ $(cat "$BODY") == *'"error"'* ]]

# Invalid username
code=$(curl -s -S -D "$HDR" -o "$BODY" -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' --data '{"username":"a!","password":"password123"}' -w "%{http_code}")
[[ "$code" == "400" ]]

# Short password
code=$(curl -s -S -D "$HDR" -o "$BODY" -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' --data '{"username":"bob","password":"short"}' -w "%{http_code}")
[[ "$code" == "400" ]]

# Register bob
code=$(curl -s -S -D "$HDR" -o "$BODY" -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' --data '{"username":"bob","password":"password123"}' -w "%{http_code}")
[[ "$code" == "201" ]]

# Login wrong password
code=$(curl -s -S -D "$HDR" -o "$BODY" -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' --data '{"username":"alice","password":"wrong"}' -w "%{http_code}")
[[ "$code" == "401" ]]

# Login alice
code=$(curl -s -S -D "$HDR" -o "$BODY" -c "$COOKIE1" -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' --data '{"username":"alice","password":"password123"}' -w "%{http_code}")
[[ "$code" == "200" ]]
# Check Set-Cookie header
grep -i '^set-cookie: ' "$HDR" | grep -qi 'session_id='

# /me
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" "http://127.0.0.1:$PORT/me" -w "%{http_code}")
[[ "$code" == "200" ]]
[[ $(cat "$BODY") == *'"username":"alice"'* ]]

# Create todo invalid
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' --data '{"title":"","description":"desc"}' -w "%{http_code}")
[[ "$code" == "400" ]]

# Create todo valid
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' --data '{"title":"Task1","description":"desc"}' -w "%{http_code}")
[[ "$code" == "201" ]]
[[ $(cat "$BODY") == *'"title":"Task1"'* ]]

# List todos
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" "http://127.0.0.1:$PORT/todos" -w "%{http_code}")
[[ "$code" == "200" ]]
[[ $(cat "$BODY") == *'"title":"Task1"'* ]]

# Get todo by id 1
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" "http://127.0.0.1:$PORT/todos/1" -w "%{http_code}")
[[ "$code" == "200" ]]

# Update todo completed
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" -X PUT "http://127.0.0.1:$PORT/todos/1" -H 'Content-Type: application/json' --data '{"completed":true}' -w "%{http_code}")
[[ "$code" == "200" ]]
[[ $(cat "$BODY") == *'"completed":true'* ]]

# Delete todo
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" -X DELETE "http://127.0.0.1:$PORT/todos/1" -w "%{http_code}")
[[ "$code" == "204" ]]
[[ ! -s "$BODY" ]]

# Get deleted
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" "http://127.0.0.1:$PORT/todos/1" -w "%{http_code}")
[[ "$code" == "404" ]]

# Login bob
code=$(curl -s -S -D "$HDR" -o "$BODY" -c "$COOKIE2" -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' --data '{"username":"bob","password":"password123"}' -w "%{http_code}")
[[ "$code" == "200" ]]

# Bob create todo id 2
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE2" -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' --data '{"title":"BobTask","description":"d"}' -w "%{http_code}")
[[ "$code" == "201" ]]

# Alice tries to access bob's todo
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" "http://127.0.0.1:$PORT/todos/2" -w "%{http_code}")
[[ "$code" == "404" ]]

# Change password
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" -X PUT "http://127.0.0.1:$PORT/password" -H 'Content-Type: application/json' --data '{"old_password":"password123","new_password":"newpassword123"}' -w "%{http_code}")
[[ "$code" == "200" ]]

# Logout
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" -X POST "http://127.0.0.1:$PORT/logout" -w "%{http_code}")
[[ "$code" == "200" ]]

# Access after logout should be 401
code=$(curl -s -S -D "$HDR" -o "$BODY" -b "$COOKIE1" "http://127.0.0.1:$PORT/me" -w "%{http_code}")
[[ "$code" == "401" ]]

# Non-auth access protected
code=$(curl -s -S -D "$HDR" -o "$BODY" "http://127.0.0.1:$PORT/todos" -w "%{http_code}")
[[ "$code" == "401" ]]

# Content-Type on error
[[ $(grep -i '^content-type: ' "$HDR" | tr -d '\r' | awk '{print tolower($0)}') == *"application/json"* ]]

echo "All tests passed"
