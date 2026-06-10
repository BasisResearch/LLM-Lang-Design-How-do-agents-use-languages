#!/usr/bin/env bash
set -euo pipefail
PORT=18080
./run.sh --port "$PORT" &
SERVER_PID=$!

function cleanup(){
  kill $SERVER_PID || true
}
trap cleanup EXIT

base="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)

wait_for_server(){
  echo "Waiting for server on $base ..." >&2
  for i in {1..120}; do
    if curl -sS -m 1 "$base/me" >/dev/null 2>&1; then
      echo "Server is up" >&2
      return 0
    fi
    sleep 1
  done
  echo "Server did not start in time" >&2
  return 1
}

wait_for_server

# Helper to curl with JSON
curlj(){
  curl -sS -D >(grep -i '^set-cookie' >&2) -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json' "$@"
}

# Register
echo Register
resp=$(curlj -X POST "$base/register" -d '{"username":"user_1","password":"password123"}')
echo "$resp"

# Login
echo Login
resp=$(curlj -X POST "$base/login" -d '{"username":"user_1","password":"password123"}')
echo "$resp"

# Me
echo Me
resp=$(curlj "$base/me")
echo "$resp"

# Change password
echo Change password
resp=$(curlj -X PUT "$base/password" -d '{"old_password":"password123","new_password":"newpassword123"}')
echo "$resp"

# Create todo
echo Create todo
resp=$(curlj -X POST "$base/todos" -d '{"title":"Buy milk","description":"2%"}')
echo "$resp"
id=$(echo "$resp" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')

# List todos
echo List todos
resp=$(curlj "$base/todos")
echo "$resp"

# Get todo by id
echo Get todo
resp=$(curlj "$base/todos/$id")
echo "$resp"

# Update todo
echo Update todo
resp=$(curlj -X PUT "$base/todos/$id" -d '{"completed":true}')
echo "$resp"

# Delete todo
echo Delete todo
code=$(curl -sS -o /dev/null -w "%{http_code}\n" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X DELETE "$base/todos/$id")
echo "$code"

# Logout
echo Logout
resp=$(curlj -X POST "$base/logout")
echo "$resp"

# Access after logout (should be 401)
echo After logout should 401
code=$(curl -sS -o /dev/null -w "%{http_code}\n" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$base/me")
echo "$code"
