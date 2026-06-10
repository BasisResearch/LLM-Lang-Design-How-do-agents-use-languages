#!/usr/bin/env bash
set -exuo pipefail
PORT=8123
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
# wait for server
for i in {1..50}; do
  if curl -s "http://127.0.0.1:$PORT/unknown" -o /dev/null; then break; fi
  sleep 0.1
done
BASE="http://127.0.0.1:$PORT"
CJ=./cookies.txt
rm -f "$CJ"

# Random username to avoid clashes across runs
USER="alice_$(date +%s%N)"
PASS1="password123"
PASS2="newpassword123"

# Unauthorized access should be 401
code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/me")
[[ "$code" == "401" ]]

# Register
resp=$(curl -s -D - -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$USER\",\"password\":\"$PASS1\"}" "$BASE/register")
[[ "$resp" == *'Content-Type: application/json'* ]]
[[ "$resp" == *'"id":'* ]]

# Duplicate register -> 409
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$USER\",\"password\":\"$PASS1\"}" "$BASE/register")
[[ "$code" == "409" ]]

# Bad login -> 401
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$USER\",\"password\":\"wrong\"}" "$BASE/login")
[[ "$code" == "401" ]]

# Good login -> 200 and Set-Cookie session_id
headers=$(mktemp)
resp=$(curl -s -D "$headers" -c "$CJ" -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$USER\",\"password\":\"$PASS1\"}" "$BASE/login")
grep -i '^Set-Cookie: session_id=' "$headers" >/dev/null

# Me -> 200
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" "$BASE/me")
[[ "$code" == "200" ]]

# Change password wrong old -> 401
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword123"}' "$BASE/password")
[[ "$code" == "401" ]]

# Change password too short -> 400
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' "$BASE/password")
[[ "$code" == "400" ]]

# Change password success -> 200
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d "{\"old_password\":\"$PASS1\",\"new_password\":\"$PASS2\"}" "$BASE/password")
[[ "$code" == "200" ]]

# Logout -> 200, invalidate session
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" -X POST "$BASE/logout")
[[ "$code" == "200" ]]

# Access with old cookie -> 401
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" "$BASE/me")
[[ "$code" == "401" ]]

# Login with old password fails, new succeeds
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$USER\",\"password\":\"$PASS1\"}" "$BASE/login")
[[ "$code" == "401" ]]

resp=$(curl -s -c "$CJ" -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$USER\",\"password\":\"$PASS2\"}" "$BASE/login")
[[ "$resp" == *'"id":'* ]]

# Todos list empty -> [] and Content-Type json
resp=$(curl -s -D - -b "$CJ" "$BASE/todos")
[[ "$resp" == *'Content-Type: application/json'* ]]
body=$(printf '%s' "$resp" | awk 'BEGIN{p=0} /^\r$/{p=1;next} p{print}')
[[ "$body" == "[]" ]]

# Create todo missing title -> 400
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"description":"test"}' "$BASE/todos")
[[ "$code" == "400" ]]

# Create todo -> 201
resp=$(curl -s -b "$CJ" -X POST -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"First"}' "$BASE/todos")
[[ "$resp" == *'"id":'* ]]
id=$(echo "$resp" | tr -d '\n' | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]\+' | head -1 | sed 's/.*://;s/[[:space:]]//g')
[[ -n "$id" ]]

# Get todo -> 200
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" "$BASE/todos/$id")
[[ "$code" == "200" ]]

# Update partial: completed true
resp=$(curl -s -b "$CJ" -X PUT -H 'Content-Type: application/json' -d '{"completed":true}' "$BASE/todos/$id")
[[ "$resp" == *'"completed": true'* ]]

# Update with empty title -> 400
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"title":""}' "$BASE/todos/$id")
[[ "$code" == "400" ]]

# Delete -> 204 and no body and no Content-Type
out=$(mktemp)
headers2=$(mktemp)
code=$(curl -s -D "$headers2" -b "$CJ" -o "$out" -w "%{http_code}" -X DELETE "$BASE/todos/$id")
[[ "$code" == "204" ]]
[[ ! -s "$out" ]]
if grep -iq '^Content-Type:' "$headers2"; then echo 'DELETE should not include Content-Type'; exit 1; fi

# Get deleted -> 404
code=$(curl -s -b "$CJ" -o /dev/null -w "%{http_code}" "$BASE/todos/$id")
[[ "$code" == "404" ]]

echo "All tests passed"