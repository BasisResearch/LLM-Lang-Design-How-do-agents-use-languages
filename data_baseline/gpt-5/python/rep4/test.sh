#!/bin/bash
set -euo pipefail
PORT=8099
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)

cleanup() {
  rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

./run.sh --port $PORT &
SRV_PID=$!
trap 'kill $SRV_PID || true; cleanup' EXIT

# wait for server to be available
for i in {1..50}; do
  if curl -sS "$BASE/me" -b "$COOKIE_JAR" -o /dev/null -w '' ; then
    break
  fi
  sleep 0.1
done

# Helper: curl with JSON headers
cj() {
  curl -sS -X "$1" "$2" -H 'Content-Type: application/json' -d "$3" -c "$COOKIE_JAR" -b "$COOKIE_JAR" -D /dev/stderr
}

# Unauth access to protected endpoint
code=$(curl -s -o >(cat >/dev/null) -w "%{http_code}" "$BASE/me")
[[ "$code" == "401" ]] || { echo "Expected 401 for unauth /me"; exit 1; }

# Register
resp=$(curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' -D /dev/stderr)
[[ $(echo "$resp" | jq -r .username) == "user_1" ]]

# Duplicate register
code=$(curl -s -o >(cat >/dev/null) -w "%{http_code}" -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ "$code" == "409" ]] || { echo "Expected 409 duplicate username"; exit 1; }

# Login
resp=$(curl -sS -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' -c "$COOKIE_JAR")
[[ $(echo "$resp" | jq -r .username) == "user_1" ]]

# Me
resp=$(curl -sS "$BASE/me" -b "$COOKIE_JAR")
[[ $(echo "$resp" | jq -r .username) == "user_1" ]]

# Change password - wrong old
code=$(curl -s -o >(cat >/dev/null) -w "%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword123"}' -b "$COOKIE_JAR")
[[ "$code" == "401" ]] || { echo "Expected 401 wrong old password"; exit 1; }

# Change password - too short
code=$(curl -s -o >(cat >/dev/null) -w "%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' -b "$COOKIE_JAR")
[[ "$code" == "400" ]] || { echo "Expected 400 short new password"; exit 1; }

# Change password - success
code=$(curl -s -o >(cat >/dev/null) -w "%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}' -b "$COOKIE_JAR")
[[ "$code" == "200" ]] || { echo "Expected 200 password change"; exit 1; }

# Todos list empty
resp=$(curl -sS "$BASE/todos" -b "$COOKIE_JAR")
[[ "$resp" == "[]" ]]

# Create todo
resp=$(curl -sS -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"First","description":"Desc"}' -b "$COOKIE_JAR")
first_id=$(echo "$resp" | jq -r .id)
[[ -n "$first_id" ]]

# Get todo
resp=$(curl -sS "$BASE/todos/$first_id" -b "$COOKIE_JAR")
[[ $(echo "$resp" | jq -r .title) == "First" ]]

# Update todo partial
resp=$(curl -sS -X PUT "$BASE/todos/$first_id" -H 'Content-Type: application/json' -d '{"completed":true}' -b "$COOKIE_JAR")
[[ $(echo "$resp" | jq -r .completed) == "true" ]]

# Create second todo
resp=$(curl -sS -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Second"}' -b "$COOKIE_JAR")
second_id=$(echo "$resp" | jq -r .id)

# List todos (ordered)
resp=$(curl -sS "$BASE/todos" -b "$COOKIE_JAR")
first_list_id=$(echo "$resp" | jq -r '.[0].id')
[[ "$first_list_id" == "$first_id" ]]

# Logout
code=$(curl -s -o >(cat >/dev/null) -w "%{http_code}" -X POST "$BASE/logout" -b "$COOKIE_JAR")
[[ "$code" == "200" ]] || { echo "Expected 200 logout"; exit 1; }

# Access after logout
code=$(curl -s -o >(cat >/dev/null) -w "%{http_code}" "$BASE/me" -b "$COOKIE_JAR")
[[ "$code" == "401" ]] || { echo "Expected 401 after logout"; exit 1; }

# Login again with new password
resp=$(curl -sS -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword123"}' -c "$COOKIE_JAR")
[[ $(echo "$resp" | jq -r .username) == "user_1" ]]

# Delete todo
code=$(curl -s -o >(cat >/dev/null) -w "%{http_code}" -X DELETE "$BASE/todos/$first_id" -b "$COOKIE_JAR")
[[ "$code" == "204" ]] || { echo "Expected 204 delete"; exit 1; }

# Get deleted
code=$(curl -s -o >(cat >/dev/null) -w "%{http_code}" "$BASE/todos/$first_id" -b "$COOKIE_JAR")
[[ "$code" == "404" ]] || { echo "Expected 404 for deleted"; exit 1; }

kill $SRV_PID
wait $SRV_PID 2>/dev/null || true

echo "All tests passed"