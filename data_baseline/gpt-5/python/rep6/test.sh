#!/bin/sh
set -euo pipefail

# Find a free port
PORT=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(('127.0.0.1',0))
print(s.getsockname()[1])
s.close()
PY
)

./run.sh --port "$PORT" >/tmp/todo_server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

# Wait for server to accept connections
base="http://127.0.0.1:$PORT"
for i in $(seq 1 50); do
  if curl -s -o /dev/null "$base/healthz"; then
    break
  fi
  sleep 0.1
done

fail() { echo "TEST FAILED: $1"; echo "--- SERVER LOG ---"; tail -n +1 /tmp/todo_server.log || true; exit 1; }

# All responses must be JSON except DELETE which is empty

# Register
resp=$(curl -s -D - -o /tmp/body1.txt -X POST "$base/register" -H 'Content-Type: application/json' \
  --data '{"username":"user_one","password":"supersecret"}') || fail "register curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
ct=$(echo "$resp" | awk 'BEGIN{IGNORECASE=1} /^Content-Type:/{print $2}' | tr -d '\r')
[ "$status" = "201" ] || fail "register status $status"
[ "$ct" = "application/json" ] || fail "register content-type $ct"

# Login
resp=$(curl -s -D - -o /tmp/body2.txt -X POST "$base/login" -H 'Content-Type: application/json' \
  --data '{"username":"user_one","password":"supersecret"}') || fail "login curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
ct=$(echo "$resp" | awk 'BEGIN{IGNORECASE=1} /^Content-Type:/{print $2}' | tr -d '\r')
setcookie=$(echo "$resp" | awk 'BEGIN{IGNORECASE=1} /^Set-Cookie:/{print $2}' | tr -d '\r')
[ "$status" = "200" ] || fail "login status $status"
[ "$ct" = "application/json" ] || fail "login content-type $ct"
[ -n "$setcookie" ] || fail "login set-cookie missing"

cookie=$(echo "$resp" | awk 'BEGIN{IGNORECASE=1} /^Set-Cookie:/{print $2}' | tr -d '\r')

# /me
resp=$(curl -s -D - -o /tmp/body3.txt "$base/me" -H "Cookie: $cookie") || fail "/me curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
ct=$(echo "$resp" | awk 'BEGIN{IGNORECASE=1} /^Content-Type:/{print $2}' | tr -d '\r')
[ "$status" = "200" ] || fail "/me status $status"
[ "$ct" = "application/json" ] || fail "/me content-type $ct"

# Change password
resp=$(curl -s -D - -o /tmp/body4.txt -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $cookie" \
  --data '{"old_password":"supersecret","new_password":"evenmoresecret"}') || fail "password curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
[ "$status" = "200" ] || fail "password status $status"

# Create todo
resp=$(curl -s -D - -o /tmp/body5.txt -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $cookie" \
  --data '{"title":"First","description":"desc"}') || fail "create todo curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
[ "$status" = "201" ] || fail "create todo status $status"

todo_id=$(python3 - <<'PY'
import json,sys
print(json.load(open('/tmp/body5.txt'))['id'])
PY
)

# List todos
resp=$(curl -s -D - -o /tmp/body6.txt "$base/todos" -H "Cookie: $cookie") || fail "list todos curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
[ "$status" = "200" ] || fail "list todos status $status"

# Get todo
resp=$(curl -s -D - -o /tmp/body7.txt "$base/todos/$todo_id" -H "Cookie: $cookie") || fail "get todo curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
[ "$status" = "200" ] || fail "get todo status $status"

# Update todo
resp=$(curl -s -D - -o /tmp/body8.txt -X PUT "$base/todos/$todo_id" -H 'Content-Type: application/json' -H "Cookie: $cookie" \
  --data '{"completed":true}') || fail "update todo curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
[ "$status" = "200" ] || fail "update todo status $status"

# Delete todo
resp=$(curl -s -D - -o /tmp/body9.txt -X DELETE "$base/todos/$todo_id" -H "Cookie: $cookie") || fail "delete todo curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
[ "$status" = "204" ] || fail "delete todo status $status"

# Ensure deleted
resp=$(curl -s -D - -o /tmp/body10.txt "$base/todos/$todo_id" -H "Cookie: $cookie") || true
status=$(echo "$resp" | head -n1 | awk '{print $2}')
[ "$status" = "404" ] || fail "after delete get status $status"

# Logout
resp=$(curl -s -D - -o /tmp/body11.txt -X POST "$base/logout" -H "Cookie: $cookie") || fail "logout curl"
status=$(echo "$resp" | head -n1 | awk '{print $2}')
[ "$status" = "200" ] || fail "logout status $status"

# Access after logout should be 401
resp=$(curl -s -D - -o /tmp/body12.txt "$base/me" -H "Cookie: $cookie") || true
status=$(echo "$resp" | head -n1 | awk '{print $2}')
[ "$status" = "401" ] || fail "post-logout auth status $status"

echo "ALL TESTS PASSED"
