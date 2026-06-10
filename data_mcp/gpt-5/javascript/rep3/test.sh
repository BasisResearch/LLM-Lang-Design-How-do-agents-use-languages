#!/bin/sh
set -euo pipefail

# Find a free port between 40000-45000
PORT=40000
while :; do
  if curl -sS -m 0.2 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    PORT=$((PORT+1))
    if [ $PORT -gt 45000 ]; then PORT=40000; fi
  else
    break
  fi
done

echo "Using port $PORT"
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

base="http://127.0.0.1:$PORT"

# Wait for server to be ready
ready=0
for i in $(seq 1 100); do
  if kill -0 $SERVER_PID 2>/dev/null; then
    if curl -sS -m 0.2 -o /dev/null "$base/me" 2>/dev/null; then
      ready=1
      break
    fi
  else
    echo "Server process exited prematurely"
    exit 1
  fi
  sleep 0.1
done
if [ $ready -ne 1 ]; then
  echo "Server did not become ready in time"
  exit 1
fi

h=$(mktemp)
b=$(mktemp)

request() {
  method="$1"; shift
  url="$1"; shift
  if [ "$method" = "DELETE" ]; then
    code=$(curl -sS -D "$h" -o "$b" -w '%{http_code}' -X "$method" "$url" "$@")
  else
    code=$(curl -sS -D "$h" -o "$b" -w '%{http_code}' -H 'Content-Type: application/json' -X "$method" "$url" "$@")
  fi
  echo "$code"
}

assert_code() {
  expected="$1"; shift
  actual="$1"; shift
  if [ "$actual" != "$expected" ]; then
    echo "Expected $expected got $actual"
    echo "Response headers:"; cat "$h" || true
    echo "Response body:"; cat "$b" || true
    exit 1
  fi
}

echo "Register user"
code=$(request POST "$base/register" --data '{"username":"alice_1","password":"password123"}')
assert_code 201 "$code"

# Duplicate username
code=$(request POST "$base/register" --data '{"username":"alice_1","password":"password123"}')
assert_code 409 "$code"

# Login
code=$(request POST "$base/login" --data '{"username":"alice_1","password":"password123"}')
assert_code 200 "$code"
COOKIE=$(grep -i '^Set-Cookie:' "$h" | sed -E 's/Set-Cookie: ([^;]+);.*/\1/i' | tr -d '\r')

# /me unauthorized without cookie
code=$(request GET "$base/me")
assert_code 401 "$code"

# /me authorized
code=$(request GET "$base/me" -H "Cookie: $COOKIE")
assert_code 200 "$code"

# Change password wrong old
code=$(request PUT "$base/password" -H "Cookie: $COOKIE" --data '{"old_password":"wrong","new_password":"newpassword123"}')
assert_code 401 "$code"

# Change password success
code=$(request PUT "$base/password" -H "Cookie: $COOKIE" --data '{"old_password":"password123","new_password":"newpassword123"}')
assert_code 200 "$code"

# Create todo missing title
code=$(request POST "$base/todos" -H "Cookie: $COOKIE" --data '{"description":"desc"}')
assert_code 400 "$code"

# Create todos
code=$(request POST "$base/todos" -H "Cookie: $COOKIE" --data '{"title":"Task 1","description":"Desc 1"}')
assert_code 201 "$code"
code=$(request POST "$base/todos" -H "Cookie: $COOKIE" --data '{"title":"Task 2","description":""}')
assert_code 201 "$code"

# List todos
code=$(request GET "$base/todos" -H "Cookie: $COOKIE")
assert_code 200 "$code"

# Get todo 1
code=$(request GET "$base/todos/1" -H "Cookie: $COOKIE")
assert_code 200 "$code"

# Update todo 1
code=$(request PUT "$base/todos/1" -H "Cookie: $COOKIE" --data '{"completed":true}')
assert_code 200 "$code"

# Delete todo 2
code=$(request DELETE "$base/todos/2" -H "Cookie: $COOKIE")
assert_code 204 "$code"

# Get deleted todo 2
code=$(request GET "$base/todos/2" -H "Cookie: $COOKIE")
assert_code 404 "$code"

# Logout
code=$(request POST "$base/logout" -H "Cookie: $COOKIE")
assert_code 200 "$code"

# Ensure session invalidated
code=$(request GET "$base/me" -H "Cookie: $COOKIE")
assert_code 401 "$code"

echo "All tests passed"