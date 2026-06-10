#!/usr/bin/env bash
set -euo pipefail

# Pick a random high port and ensure no conflict
pick_port() {
  for attempt in {1..10}; do
    p=$(shuf -i 20000-49000 -n 1)
    if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p$"; then
      echo "$p"
      return 0
    fi
  done
  echo 3456
}

PORT=${PORT:-$(pick_port)}
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; if kill -0 ${SERVER_PID:-0} 2>/dev/null; then kill $SERVER_PID; fi; }
trap cleanup EXIT

./run.sh --port "$PORT" &
SERVER_PID=$!

# wait for server or fail
for i in {1..50}; do
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server process exited unexpectedly" >&2
    exit 1
  fi
  if curl -sS -o /dev/null "$BASE/me"; then
    break
  fi
  sleep 0.1
done

# Helper to extract id from JSON like {"id":123,...}
extract_id() {
  grep -o '"id"\s*:\s*[0-9]\+' | head -n1 | sed 's/[^0-9]//g'
}

# Register user1
reg_resp=$(curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user1","password":"password123"}')
echo "$reg_resp"

# Duplicate username should 409
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user1","password":"password123"}')
if [[ "$status" != "409" ]]; then echo "Expected 409 for duplicate username, got $status"; exit 1; fi

# Login user1
login_resp=$(curl -sS -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user1","password":"password123"}')
echo "$login_resp"

# Get /me
me_resp=$(curl -sS -b "$COOKIE_JAR" "$BASE/me")
echo "$me_resp"

# Create todo 1
create1=$(curl -sS -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Desc 1"}')
echo "$create1"
id1=$(echo "$create1" | extract_id)

# Create todo 2 (no description)
create2=$(curl -sS -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 2"}')
echo "$create2"
id2=$(echo "$create2" | extract_id)

# List todos
list=$(curl -sS -b "$COOKIE_JAR" "$BASE/todos")
echo "$list"

# Get todo 1
get1=$(curl -sS -b "$COOKIE_JAR" "$BASE/todos/$id1")
echo "$get1"

# Update todo 1 completed true
upd1=$(curl -sS -b "$COOKIE_JAR" -X PUT "$BASE/todos/$id1" -H 'Content-Type: application/json' -d '{"completed":true}')
echo "$upd1"

# Delete todo 2
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X DELETE "$BASE/todos/$id2")
if [[ "$status" != "204" ]]; then echo "Expected 204, got $status"; exit 1; fi

# Change password
pwd_resp=$(curl -sS -b "$COOKIE_JAR" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword456"}')
echo "$pwd_resp"

# Logout
logout_resp=$(curl -sS -b "$COOKIE_JAR" -X POST "$BASE/logout")
echo "$logout_resp"

# Subsequent /me should 401
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" "$BASE/me")
if [[ "$status" != "401" ]]; then echo "Expected 401 after logout, got $status"; exit 1; fi

# Login with new password
relogin=$(curl -sS -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user1","password":"newpassword456"}')
echo "$relogin"

# Test 404 for other user's todo
# Register user2 and login
reg2=$(curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user2","password":"password123"}')
echo "$reg2"

login2=$(curl -sS -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user2","password":"password123"}')
echo "$login2"

status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" "$BASE/todos/$id1")
if [[ "$status" != "404" ]]; then echo "Expected 404 for other user's todo, got $status"; exit 1; fi

echo "All tests passed"