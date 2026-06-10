#!/usr/bin/env bash
set -euo pipefail
PORT=4567
./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID || true' EXIT

wait_for() {
  for i in {1..60}; do
    if curl -s "http://localhost:$PORT/me" -H 'Content-Type: application/json' -o /dev/null; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

wait_for || { echo 'Server did not start'; exit 1; }

base="http://localhost:$PORT"

json() { jq -c .; }

# Register
reg=$(curl -s -i -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$reg" | grep -q "201" || { echo register failed; echo "$reg"; exit 1; }

# Login
login=$(curl -s -i -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$login" | grep -q "200" || { echo login failed; echo "$login"; exit 1; }
session=$(echo "$login" | awk -F 'Set-Cookie: ' '/Set-Cookie:/{print $2}' | tr -d '\r' | head -n1 | cut -d';' -f1)
[ -n "$session" ] || { echo no session cookie; echo "$login"; exit 1; }

# Me (with cookie)
me=$(curl -s -i "$base/me" -H 'Content-Type: application/json' -H "Cookie: $session")
echo "$me" | grep -q "200" || { echo me failed; echo "$me"; exit 1; }

# Change password
pwdchg=$(curl -s -i -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $session" -d '{"old_password":"password123","new_password":"password456"}')
echo "$pwdchg" | grep -q "200" || { echo password change failed; echo "$pwdchg"; exit 1; }

# Logout
logout=$(curl -s -i -X POST "$base/logout" -H 'Content-Type: application/json' -H "Cookie: $session")
echo "$logout" | grep -q "200" || { echo logout failed; echo "$logout"; exit 1; }

# Check that session invalidated
me2=$(curl -s -i "$base/me" -H 'Content-Type: application/json' -H "Cookie: $session")
echo "$me2" | grep -q "401" || { echo session not invalidated; echo "$me2"; exit 1; }

# Login again with new password
login2=$(curl -s -i -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password456"}')
echo "$login2" | grep -q "200" || { echo login2 failed; echo "$login2"; exit 1; }
session2=$(echo "$login2" | awk -F 'Set-Cookie: ' '/Set-Cookie:/{print $2}' | tr -d '\r' | head -n1 | cut -d';' -f1)

# Create todos
c1=$(curl -s -i -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $session2" -d '{"title":"Task 1","description":"Desc 1"}')
echo "$c1" | grep -q "201" || { echo create1 failed; echo "$c1"; exit 1; }

c2=$(curl -s -i -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $session2" -d '{"title":"Task 2"}')
echo "$c2" | grep -q "201" || { echo create2 failed; echo "$c2"; exit 1; }

# List todos
list=$(curl -s -i "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $session2")
echo "$list" | grep -q "200" || { echo list failed; echo "$list"; exit 1; }

# Get todo 1
get1=$(curl -s -i "$base/todos/1" -H 'Content-Type: application/json' -H "Cookie: $session2")
echo "$get1" | grep -q "200" || { echo get1 failed; echo "$get1"; exit 1; }

# Update todo 1
upd=$(curl -s -i -X PUT "$base/todos/1" -H 'Content-Type: application/json' -H "Cookie: $session2" -d '{"completed":true,"title":"Task 1 updated"}')
echo "$upd" | grep -q "200" || { echo update failed; echo "$upd"; exit 1; }

echo "$upd" | grep -qi '"completed":true' || { echo completed not true; echo "$upd"; exit 1; }

# Delete todo 2
del=$(curl -s -i -X DELETE "$base/todos/2" -H 'Content-Type: application/json' -H "Cookie: $session2")
echo "$del" | grep -q "204" || { echo delete failed; echo "$del"; exit 1; }

# GET deleted should be 404
get2=$(curl -s -i "$base/todos/2" -H 'Content-Type: application/json' -H "Cookie: $session2")
echo "$get2" | grep -q "404" || { echo deleted not 404; echo "$get2"; exit 1; }

echo 'All tests passed.'