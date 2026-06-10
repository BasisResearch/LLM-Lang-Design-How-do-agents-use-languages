#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-$(shuf -i 40000-49999 -n 1)}
ROOT="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
BOB_COOKIE=$(mktemp)
LOGIN_HDRS=""
LOGIN2_HDRS=""
PID=""
CURL="curl --connect-timeout 2 --max-time 5 -sS"
cleanup() {
  rm -f "$COOKIE_JAR" "$BOB_COOKIE" reg.json login.json t1.json t2.json pw1.json pw2.json bobreg.json boblogin.json bobtodo.json upd.json login2.json ${LOGIN_HDRS:-} ${LOGIN2_HDRS:-} 2>/dev/null || true
  if [[ -n "${PID:-}" ]]; then kill "$PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

# Prepare JSON files to avoid quoting issues
printf '{"username":"alice_1","password":"password123"}' > reg.json
printf '{"username":"alice_1","password":"password123"}' > login.json
printf '{"old_password":"wrong","new_password":"newpassword"}' > pw1.json
printf '{"old_password":"password123","new_password":"newpassword"}' > pw2.json
printf '{"title":"Task 1","description":"Desc 1"}' > t1.json
printf '{"title":"Task 2"}' > t2.json
printf '{"completed":true}' > upd.json
printf '{"username":"bob_2","password":"password123"}' > bobreg.json
printf '{"username":"bob_2","password":"password123"}' > boblogin.json
printf '{"title":"Bob Task"}' > bobtodo.json

./run.sh --port "$PORT" &
PID=$!

# Wait for server
for i in {1..50}; do
  code=$($CURL -o /dev/null -w '%{http_code}' "$ROOT/does-not-exist") || code=0
  if [[ "$code" == "404" ]]; then break; fi
  sleep 0.1
  if [[ $i -eq 50 ]]; then echo "Server failed to start" >&2; exit 1; fi
done

# Register
REG_CODE=$($CURL -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$ROOT/register" --data-binary @reg.json)
[[ "$REG_CODE" == "201" ]]

# Duplicate username
DUP=$($CURL -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$ROOT/register" --data-binary @reg.json)
[[ "$DUP" == "409" ]]

# Login
LOGIN_HDRS=$(mktemp)
$CURL -D "$LOGIN_HDRS" -c "$COOKIE_JAR" -H 'Content-Type: application/json' -X POST "$ROOT/login" --data-binary @login.json > /dev/null
grep -i '^Set-Cookie: session_id=' "$LOGIN_HDRS" >/dev/null

# Get me
ME=$($CURL -b "$COOKIE_JAR" "$ROOT/me")
[[ "$ME" == *"alice_1"* ]]

# Change password - wrong old
BADPW_CODE=$($CURL -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT "$ROOT/password" --data-binary @pw1.json)
[[ "$BADPW_CODE" == "401" ]]

# Change password - success
OKPW_CODE=$($CURL -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT "$ROOT/password" --data-binary @pw2.json)
[[ "$OKPW_CODE" == "200" ]]

# Logout
LOGOUT_CODE=$($CURL -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X POST "$ROOT/logout")
[[ "$LOGOUT_CODE" == "200" ]]

# Access after logout should fail
AFTER_LOGOUT=$($CURL -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$ROOT/me")
[[ "$AFTER_LOGOUT" == "401" ]]

# Login again with new password
printf '{"username":"alice_1","password":"newpassword"}' > login2.json
LOGIN2_HDRS=$(mktemp)
$CURL -D "$LOGIN2_HDRS" -c "$COOKIE_JAR" -H 'Content-Type: application/json' -X POST "$ROOT/login" --data-binary @login2.json > /dev/null
grep -i '^Set-Cookie: session_id=' "$LOGIN2_HDRS" >/dev/null

# Create todos
T1=$($CURL -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X POST "$ROOT/todos" --data-binary @t1.json)
T1_ID=$(echo "$T1" | sed -n 's/.*"id":[ ]*\([0-9][0-9]*\).*/\1/p')
T2=$($CURL -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X POST "$ROOT/todos" --data-binary @t2.json)
T2_ID=$(echo "$T2" | sed -n 's/.*"id":[ ]*\([0-9][0-9]*\).*/\1/p')
[[ -n "$T1_ID" && -n "$T2_ID" ]]

# List todos
LIST=$($CURL -b "$COOKIE_JAR" "$ROOT/todos")
COUNT=$(echo "$LIST" | grep -o '"id"' | wc -l | tr -d ' ')
[[ "$COUNT" == "2" ]]

# Get todo by id
GET1=$($CURL -b "$COOKIE_JAR" "$ROOT/todos/$T1_ID")
[[ "$GET1" == *"Task 1"* ]]

# Update todo partially
UPD=$($CURL -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT "$ROOT/todos/$T2_ID" --data-binary @upd.json)
[[ "$UPD" == *"completed":true* ]]

# Delete todo
DEL_CODE=$($CURL -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X DELETE "$ROOT/todos/$T1_ID")
[[ "$DEL_CODE" == "204" ]]

# Deleted should be 404
NF_CODE=$($CURL -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$ROOT/todos/$T1_ID")
[[ "$NF_CODE" == "404" ]]

# Other user's access returns 404
$CURL -H 'Content-Type: application/json' -X POST "$ROOT/register" --data-binary @bobreg.json > /dev/null
$CURL -D- -c "$BOB_COOKIE" -H 'Content-Type: application/json' -X POST "$ROOT/login" --data-binary @boblogin.json > /dev/null
BOB_TODO=$($CURL -b "$BOB_COOKIE" -H 'Content-Type: application/json' -X POST "$ROOT/todos" --data-binary @bobtodo.json)
BOB_ID=$(echo "$BOB_TODO" | sed -n 's/.*"id":[ ]*\([0-9][0-9]*\).*/\1/p')
NF_CODE2=$($CURL -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$ROOT/todos/$BOB_ID")
[[ "$NF_CODE2" == "404" ]]

kill "$PID"
wait "$PID" || true

echo "All tests passed"