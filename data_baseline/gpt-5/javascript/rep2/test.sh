#!/bin/bash
set -euo pipefail

# Choose a random high port to avoid collision
RANDOM_PORT=$(( 40000 + (RANDOM % 20000) ))
PORT=${1:-$RANDOM_PORT}
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

./run.sh --port "$PORT" &
SVPID=$!
trap 'kill $SVPID 2>/dev/null || true' EXIT

# Wait for server listening (up to ~5s)
for i in {1..100}; do
  if curl -sS -o /dev/null "$BASE/does-not-exist"; then
    break
  fi
  sleep 0.05
done

# Helper to curl with cookies and JSON, printing headers to stderr for debugging
curlj() {
  method="$1"; url="$2"; data="${3-}"
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" "$BASE$url" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data "$data" -D /dev/stderr
  else
    curl -sS -X "$method" "$BASE$url" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" -D /dev/stderr
  fi
}

# Register
resp=$(curlj POST /register '{"username":"user_one","password":"password123"}')
[[ "$resp" == *'"id":1'* ]]

# Duplicate username -> 409
code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/register" -H 'Content-Type: application/json' --data '{"username":"user_one","password":"password123"}')
[[ "$code" == "409" ]]

# Login
hdrs=$(curl -sS -X POST "$BASE/login" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data '{"username":"user_one","password":"password123"}' -D - -o /dev/null)
[[ "$hdrs" == *$'Set-Cookie: session_id='* ]]

# /me
me=$(curlj GET /me)
[[ "$me" == *'"username":"user_one"'* ]]

# Change password wrong old -> 401
code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data '{"old_password":"bad","new_password":"newpassword123"}')
[[ "$code" == "401" ]]

# Change password ok
code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]]

# Create todo - missing title -> 400
code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/todos" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" --data '{"description":"desc only"}')
[[ "$code" == "400" ]]

# Create todo ok
resp=$(curlj POST /todos '{"title":"Task 1","description":"First"}')
[[ "$resp" == *'"id":1'* ]]

# List todos
list=$(curlj GET /todos)
[[ "$list" == *'"id":1'* ]]

# Get todo 1
get1=$(curlj GET /todos/1)
[[ "$get1" == *'"title":"Task 1"'* ]]

# Update todo 1
upd=$(curlj PUT /todos/1 '{"completed":true}')
[[ "$upd" == *'"completed":true'* ]]

# Delete todo 1
code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$BASE/todos/1" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "204" ]]

# Get deleted -> 404
code=$(curl -sS -o /dev/null -w "%{http_code}" -X GET "$BASE/todos/1" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "404" ]]

# Logout
code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/logout" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "200" ]]

# After logout, access should be 401
code=$(curl -sS -o /dev/null -w "%{http_code}" -X GET "$BASE/me" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$code" == "401" ]]

kill $SVPID
wait $SVPID 2>/dev/null || true

echo "All tests passed."