#!/usr/bin/env bash
set -euo pipefail

PORT=18080

./run.sh --port "$PORT" &
SERVER_PID=$!

cleanup() {
  kill $SERVER_PID || true
}
trap cleanup EXIT

wait_for_server() {
  for i in {1..120}; do
    if curl -sS "http://127.0.0.1:$PORT/" -o /dev/null; then
      return 0
    fi
    sleep 0.5
  done
  echo "Server did not start" >&2
  exit 1
}

wait_for_server || true

base="http://127.0.0.1:$PORT"

cookiejar=$(mktemp)

# Register
echo "Registering..."
curl -sS -D /tmp/headers.txt -o /tmp/body.txt -X POST "$base/register" \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice_1","password":"password123"}'

code=$(grep -m1 HTTP /tmp/headers.txt | awk '{print $2}')
if [[ "$code" != "201" ]]; then echo "Register failed: $code"; cat /tmp/body.txt; exit 1; fi

# Duplicate username check
curl -sS -D /tmp/headers2.txt -o /tmp/body2.txt -X POST "$base/register" \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice_1","password":"password123"}'
code=$(grep -m1 HTTP /tmp/headers2.txt | awk '{print $2}')
if [[ "$code" != "409" ]]; then echo "Duplicate username check failed: $code"; cat /tmp/body2.txt; exit 1; fi

# Login
echo "Logging in..."
curl -sS -D /tmp/login_headers.txt -o /tmp/login_body.txt -X POST "$base/login" \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice_1","password":"password123"}'
code=$(grep -m1 HTTP /tmp/login_headers.txt | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "Login failed: $code"; cat /tmp/login_body.txt; exit 1; fi

SESSION=$(grep -i '^set-cookie:' /tmp/login_headers.txt | sed -n 's/^[Ss]et-[Cc]ookie: session_id=\([^;]*\).*/\1/p' | tr -d '\r\n')
if [[ -z "$SESSION" ]]; then echo "No session cookie set"; exit 1; fi

# Auth failure example
code=$(curl -sS -o /dev/null -w '%{http_code}' "$base/me")
if [[ "$code" != "401" ]]; then echo "/me without auth did not 401: $code"; exit 1; fi

# /me with cookie
code=$(curl -sS -o /tmp/me_body.txt -w '%{http_code}' "$base/me" -H "Cookie: session_id=$SESSION")
if [[ "$code" != "200" ]]; then echo "/me with auth failed: $code"; cat /tmp/me_body.txt; exit 1; fi

# Create todo
echo "Creating todo..."
curl -sS -D /tmp/todo_headers.txt -o /tmp/todo_body.txt -X POST "$base/todos" \
  -H 'Content-Type: application/json' -H "Cookie: session_id=$SESSION" \
  -d '{"title":"First","description":"Test"}'
code=$(grep -m1 HTTP /tmp/todo_headers.txt | awk '{print $2}')
if [[ "$code" != "201" ]]; then echo "Create todo failed: $code"; cat /tmp/todo_body.txt; exit 1; fi

ID=$(grep -o '"id"\s*:\s*[0-9]\+' /tmp/todo_body.txt | head -n1 | sed 's/.*:\s*//')
if [[ -z "$ID" ]]; then echo "Failed to parse todo id"; cat /tmp/todo_body.txt; exit 1; fi

# List todos
code=$(curl -sS -o /tmp/list_body.txt -w '%{http_code}' "$base/todos" -H "Cookie: session_id=$SESSION")
if [[ "$code" != "200" ]]; then echo "List todos failed: $code"; cat /tmp/list_body.txt; exit 1; fi

# Get todo
code=$(curl -sS -o /tmp/get_body.txt -w '%{http_code}' "$base/todos/$ID" -H "Cookie: session_id=$SESSION")
if [[ "$code" != "200" ]]; then echo "Get todo failed: $code"; cat /tmp/get_body.txt; exit 1; fi

# Update todo
curl -sS -D /tmp/put_headers.txt -o /tmp/put_body.txt -X PUT "$base/todos/$ID" \
  -H 'Content-Type: application/json' -H "Cookie: session_id=$SESSION" \
  -d '{"completed":true,"title":"First Updated"}'
code=$(grep -m1 HTTP /tmp/put_headers.txt | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "Update todo failed: $code"; cat /tmp/put_body.txt; exit 1; fi

# Delete todo
code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$base/todos/$ID" -H "Cookie: session_id=$SESSION")
if [[ "$code" != "204" ]]; then echo "Delete todo failed: $code"; exit 1; fi

# Logout
code=$(curl -sS -o /tmp/logout_body.txt -w '%{http_code}' -X POST "$base/logout" -H "Cookie: session_id=$SESSION")
if [[ "$code" != "200" ]]; then echo "Logout failed: $code"; cat /tmp/logout_body.txt; exit 1; fi

# Ensure session invalidated
code=$(curl -sS -o /tmp/after_logout.txt -w '%{http_code}' "$base/me" -H "Cookie: session_id=$SESSION")
if [[ "$code" != "401" ]]; then echo "Session still valid after logout: $code"; cat /tmp/after_logout.txt; exit 1; fi

echo "All tests passed."
