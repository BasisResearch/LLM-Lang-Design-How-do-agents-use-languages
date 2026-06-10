#!/bin/bash
set -euo pipefail
PORT=${PORT:-8123}
ROOT=$(pwd)

cleanup() {
  if [[ -f server.pid ]]; then
    PID=$(cat server.pid || true)
    if [[ -n "${PID:-}" ]]; then
      kill "$PID" 2>/dev/null || true
      wait "$PID" 2>/dev/null || true
    fi
    rm -f server.pid
  fi
  rm -f h.txt b.txt c1.txt c2.txt
}
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" >/dev/null 2>&1 & echo $! > server.pid

# Wait for server to be ready
for i in {1..50}; do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/me || true)
  if [[ "$code" != "000" ]]; then
    break
  fi
  sleep 0.1
done

base() { echo "http://127.0.0.1:$PORT$1"; }

req() {
  # args: METHOD PATH DATA COOKIEJAR EXPECT_CODE
  local method="$1"; shift
  local path="$1"; shift
  local data="$1"; shift
  local jar="$1"; shift
  local expect="$1"; shift
  rm -f h.txt b.txt
  local curl_args=( -s -D h.txt -o b.txt -X "$method" )
  if [[ -n "$data" ]]; then
    curl_args+=( -H 'Content-Type: application/json' --data "$data" )
  fi
  if [[ -n "$jar" ]]; then
    curl_args+=( -b "$jar" -c "$jar" )
  fi
  curl_args+=( "$(base "$path")" )
  curl "${curl_args[@]}" >/dev/null || true
  local status
  status=$(head -n1 h.txt | awk '{print $2}')
  if [[ "$status" != "$expect" ]]; then
    echo "FAIL $method $path expected $expect got $status" >&2
    echo "Response headers:" >&2; cat h.txt >&2
    echo "Body:" >&2; cat b.txt >&2
    exit 1
  fi
  if [[ "$status" != "204" ]]; then
    ct=$(grep -i '^Content-Type:' h.txt | tr -d '\r' | awk '{print tolower($2)}')
    if [[ "$ct" != "application/json" ]]; then
      echo "FAIL Content-Type for $method $path expected application/json got '$ct'" >&2
      cat h.txt >&2
      exit 1
    fi
  else
    # ensure no body
    if [[ -s b.txt ]]; then
      echo "FAIL DELETE returned body for $path" >&2
      exit 1
    fi
  fi
}

# 1) Register user1
req POST /register '{"username":"user_one","password":"password123"}' '' 201

# 2) Duplicate register
req POST /register '{"username":"user_one","password":"password123"}' '' 409

# 3) Login user1
req POST /login '{"username":"user_one","password":"password123"}' c1.txt 200
if ! grep -qi '^Set-Cookie: session_id=' h.txt; then
  echo "FAIL: No Set-Cookie on login" >&2; exit 1; fi

# 4) GET /me
req GET /me '' c1.txt 200

# 5) Wrong old password
req PUT /password '{"old_password":"wrong","new_password":"newpassword123"}' c1.txt 401

# 6) Short new password
req PUT /password '{"old_password":"password123","new_password":"short"}' c1.txt 400

# 7) Correct password change
req PUT /password '{"old_password":"password123","new_password":"newpassword123"}' c1.txt 200

# 8) Logout
req POST /logout '' c1.txt 200

# 9) Using old session should be 401
req GET /me '' c1.txt 401

# 10) Login with new password
req POST /login '{"username":"user_one","password":"newpassword123"}' c1.txt 200

# 11) Create todos
# Missing title
req POST /todos '{"description":"desc"}' c1.txt 400
# Valid create
req POST /todos '{"title":"Task1","description":"First"}' c1.txt 201
T1=$(grep -o '"id":[0-9]\+' b.txt | head -n1 | cut -d: -f2)
if [[ -z "$T1" ]]; then echo "FAIL: No id in create todo" >&2; exit 1; fi

# List todos
req GET /todos '' c1.txt 200

# Get todo by id
req GET /todos/$T1 '' c1.txt 200

# Update todo
req PUT /todos/$T1 '{"completed":true,"description":"Updated"}' c1.txt 200

# 404 for non-existent
req GET /todos/99999 '' c1.txt 404

# Delete todo
req DELETE /todos/$T1 '' c1.txt 204

# Ensure gone
req GET /todos/$T1 '' c1.txt 404

# 12) Cross-user access returns 404
# Register and login user2
req POST /register '{"username":"user_two","password":"password456"}' '' 201
req POST /login '{"username":"user_two","password":"password456"}' c2.txt 200
# Create todo for user2
req POST /todos '{"title":"U2Task","description":"Second user"}' c2.txt 201
T2=$(grep -o '"id":[0-9]\+' b.txt | head -n1 | cut -d: -f2)
# Access with user1 should be 404
req GET /todos/$T2 '' c1.txt 404
req PUT /todos/$T2 '{"title":"Hack"}' c1.txt 404
req DELETE /todos/$T2 '' c1.txt 404

# Logout user2 and ensure 401
req POST /logout '' c2.txt 200
req GET /me '' c2.txt 401

echo "All tests passed."