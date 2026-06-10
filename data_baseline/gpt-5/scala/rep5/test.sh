#!/usr/bin/env bash
set -euo pipefail

# Pick a random high port if not provided
PORT=${PORT:-$(( (RANDOM % 10000) + 10000 ))}
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
COOKIE2=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR" "$COOKIE2"; if [[ -n "${PID:-}" ]]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi }
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" &
PID=$!

# Wait for server to be ready
for i in {1..50}; do
  if curl -sS "$BASE/register" -o /dev/null -w '' 2>/dev/null; then
    break
  fi
  sleep 0.2
  if [[ $i -eq 50 ]]; then
    echo "Server failed to start" >&2
    exit 1
  fi
done

curlj() {
  method=$1
  url=$2
  data=${3-}
  if [[ -n ${data:-} ]]; then
    curl -sS -X "$method" "$url" -H 'Content-Type: application/json' --data "$data" -b "$COOKIE_JAR" -c "$COOKIE_JAR"
  else
    curl -sS -X "$method" "$url" -b "$COOKIE_JAR" -c "$COOKIE_JAR"
  fi
}

# Register
RESP=$(curlj POST "$BASE/register" '{"username":"alice_1","password":"password123"}')
[[ -n "$RESP" ]] && echo "$RESP" | grep '"id"' >/dev/null

# Duplicate username
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/register" -H 'Content-Type: application/json' --data '{"username":"alice_1","password":"password123"}')
[[ "$code" == "409" ]]

# Login
RESP=$(curlj POST "$BASE/login" '{"username":"alice_1","password":"password123"}')
[[ -n "$RESP" ]] && echo "$RESP" | grep '"username":"alice_1"' >/dev/null

# Get me
RESP=$(curlj GET "$BASE/me")
[[ -n "$RESP" ]] && echo "$RESP" | grep '"username":"alice_1"' >/dev/null

# Password change: wrong old -> 401
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' --data '{"old_password":"bad","new_password":"newpassword123"}' -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "401" ]]

# Password change: short new -> 400
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' --data '{"old_password":"password123","new_password":"short"}' -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "400" ]]

# Password change ok
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' --data '{"old_password":"password123","new_password":"newpassword123"}' -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "200" ]]

# Logout
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/logout" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "200" ]]

# Access after logout should be 401
code=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$BASE/me" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "401" ]]

# Login again with new password
RESP=$(curlj POST "$BASE/login" '{"username":"alice_1","password":"newpassword123"}')
[[ -n "$RESP" ]] && echo "$RESP" | grep '"username":"alice_1"' >/dev/null

# Todos list empty
RESP=$(curlj GET "$BASE/todos")
[[ "$RESP" == "[]" ]]

# Create todo (no description)
RESP=$(curlj POST "$BASE/todos" '{"title":"Task A"}')
[[ -n "$RESP" ]] && echo "$RESP" | grep '"title":"Task A"' >/dev/null

# Create todo with description
RESP=$(curlj POST "$BASE/todos" '{"title":"Task B","description":"desc"}')
[[ -n "$RESP" ]] && echo "$RESP" | grep '"description":"desc"' >/dev/null

# List todos should have 2
RESP=$(curlj GET "$BASE/todos")
COUNT=$(echo "$RESP" | grep -o '"id"' | wc -l | awk '{print $1}')
[[ "$COUNT" == "2" ]]

# Get todo 1
RESP=$(curlj GET "$BASE/todos/1")
[[ -n "$RESP" ]] && echo "$RESP" | grep '"id":1' >/dev/null

# Update todo 1 partial: set completed true
RESP=$(curlj PUT "$BASE/todos/1" '{"completed":true}')
[[ -n "$RESP" ]] && echo "$RESP" | grep '"completed":true' >/dev/null

# Update todo 1 invalid title empty -> 400
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE/todos/1" -H 'Content-Type: application/json' --data '{"title":""}' -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "400" ]]

# Delete todo 1
code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/todos/1" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "204" ]]

# Get deleted -> 404
code=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$BASE/todos/1" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "404" ]]

# Ensure another user cannot access -> 404
curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' --data '{"username":"bob_2","password":"password123"}' >/dev/null
curl -sS -X POST "$BASE/login" -H 'Content-Type: application/json' --data '{"username":"bob_2","password":"password123"}' -c "$COOKIE2" -b "$COOKIE2" >/dev/null
# Bob tries to get Alice's todo 2
code=$(curl -s -o /dev/null -w "%{http_code}" -X GET "$BASE/todos/2" -b "$COOKIE2" -c "$COOKIE2")
[[ "$code" == "404" ]]

echo "All tests passed"