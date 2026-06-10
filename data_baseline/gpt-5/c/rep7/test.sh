#!/usr/bin/env bash
set -euo pipefail
PORT=8124
ROOT=http://127.0.0.1:$PORT
COOKIE_JAR=$(mktemp)

cleanup(){ rm -f "$COOKIE_JAR"; if [[ -f /tmp/server.pid ]]; then kill "$(cat /tmp/server.pid)" 2>/dev/null || true; rm -f /tmp/server.pid; fi }
trap cleanup EXIT

# Build and run
chmod +x run.sh
./run.sh --port $PORT >/tmp/server_test.log 2>&1 & echo $! >/tmp/server.pid
sleep 1

# Helper to curl with cookies
curl_json(){ curl -sS -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"; }

# Register
reg=$(curl_json -X POST "$ROOT/register" --data '{"username":"user_1","password":"password1"}')
[[ $(echo "$reg" | jq -r .username) == "user_1" ]]

# Login
login=$(curl_json -X POST "$ROOT/login" --data '{"username":"user_1","password":"password1"}')
[[ $(echo "$login" | jq -r .username) == "user_1" ]]

# Me
me=$(curl_json -X GET "$ROOT/me")
[[ $(echo "$me" | jq -r .username) == "user_1" ]]

# Create todos
one=$(curl_json -X POST "$ROOT/todos" --data '{"title":"t1","description":"d1"}')
T1=$(echo "$one" | jq -r .id)

two=$(curl_json -X POST "$ROOT/todos" --data '{"title":"t2"}')
T2=$(echo "$two" | jq -r .id)

# List
lst=$(curl_json -X GET "$ROOT/todos")
[[ $(echo "$lst" | jq length) -ge 2 ]]

# Get specific
get1=$(curl_json -X GET "$ROOT/todos/$T1")
[[ $(echo "$get1" | jq -r .title) == "t1" ]]

# Update partial
upd=$(curl_json -X PUT "$ROOT/todos/$T2" --data '{"completed": true}')
[[ $(echo "$upd" | jq -r .completed) == "true" ]]

# Password change
ok=$(curl_json -X PUT "$ROOT/password" --data '{"old_password":"password1","new_password":"password2"}')

# Logout
logout=$(curl_json -X POST "$ROOT/logout")

# Access after logout should be 401
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$ROOT/me")
[[ "$code" == "401" ]]

# Login with new password
login2=$(curl_json -X POST "$ROOT/login" --data '{"username":"user_1","password":"password2"}')

# Delete
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X DELETE "$ROOT/todos/$T1")
[[ "$code" == "204" ]]

# Unauthorized access to other user's todo returns 404
reg2=$(curl -sS -H 'Content-Type: application/json' -X POST "$ROOT/register" --data '{"username":"user_2","password":"password1"}')
login_u2=$(curl -sS -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X POST "$ROOT/login" --data '{"username":"user_2","password":"password1"}')
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$ROOT/todos/$T2")
[[ "$code" == "404" ]]

echo "All tests passed"