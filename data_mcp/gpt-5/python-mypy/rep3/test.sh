#!/usr/bin/env bash
set -euo pipefail
PORT=8765
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup(){ kill $SERVER_PID 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5

base="http://127.0.0.1:$PORT"

check(){
  expected_code=$1
  shift
  status=$(curl -s -o /tmp/resp.json -w "%{http_code}" "$@")
  if [[ "$status" != "$expected_code" ]]; then
    echo "Request failed: $*" >&2
    echo "Expected $expected_code, got $status" >&2
    echo "Body:" >&2
    cat /tmp/resp.json >&2
    exit 1
  fi
}

# Register
check 201 -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' "$base/register" -X POST

# Duplicate username
check 409 -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' "$base/register" -X POST

# Login
cookies=$(mktemp)
status=$(curl -s -c "$cookies" -b "$cookies" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' -o /tmp/resp.json -w "%{http_code}" "$base/login" -X POST)
if [[ "$status" != "200" ]]; then
  echo "Login failed"; cat /tmp/resp.json; exit 1; fi

# /me
check 200 -b "$cookies" "$base/me"

# Change password (wrong old)
check 401 -b "$cookies" -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword"}' "$base/password" -X PUT

# Change password (short new)
check 400 -b "$cookies" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' "$base/password" -X PUT

# Change password success
check 200 -b "$cookies" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword"}' "$base/password" -X PUT

# Logout
check 200 -b "$cookies" "$base/logout" -X POST

# Auth required now
check 401 -b "$cookies" "$base/me"

# Login again with new password
status=$(curl -s -c "$cookies" -b "$cookies" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"newpassword"}' -o /tmp/resp.json -w "%{http_code}" "$base/login" -X POST)
if [[ "$status" != "200" ]]; then echo "Re-login failed"; cat /tmp/resp.json; exit 1; fi

# Create todo missing title
check 400 -b "$cookies" -H 'Content-Type: application/json' -d '{"description":"desc"}' "$base/todos" -X POST

# Create todo ok
check 201 -b "$cookies" -H 'Content-Type: application/json' -d '{"title":"First","description":"desc"}' "$base/todos" -X POST

# List todos
check 200 -b "$cookies" "$base/todos"

# Get todo 1
check 200 -b "$cookies" "$base/todos/1"

# Update todo 1
check 200 -b "$cookies" -H 'Content-Type: application/json' -d '{"completed":true}' "$base/todos/1" -X PUT

# Delete todo 1
status=$(curl -s -b "$cookies" -o /tmp/resp.json -w "%{http_code}" "$base/todos/1" -X DELETE)
if [[ "$status" != "204" ]]; then echo "Delete failed"; cat /tmp/resp.json; exit 1; fi

# Get after delete
check 404 -b "$cookies" "$base/todos/1"

echo "All tests passed"