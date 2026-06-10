#!/usr/bin/env bash
set -euo pipefail
PORT=4567
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
COOKIE_JAR2=$(mktemp)

cleanup() {
  rm -f "$COOKIE_JAR" "$COOKIE_JAR2" || true
}
trap cleanup EXIT

# Try to kill any previous server on this port
pkill -f "dist/server.js --port $PORT" 2>/dev/null || true

# Start server in background
./run.sh --port "$PORT" &
SERVER_PID=$!
# Wait for server to start listening
for i in $(seq 1 50); do
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/me" || true)
  if [[ -n "$CODE" && "$CODE" != "000" ]]; then
    break
  fi
  sleep 0.2
  if [[ $i -eq 50 ]]; then
    echo "Server failed to start"
    kill $SERVER_PID || true
    exit 1
  fi
done

fail() { echo "TEST FAILED: $1"; kill $SERVER_PID || true; exit 1; }
pass() { echo "PASS: $1"; }

# Helper: curl with JSON
curlj() { curl -sS -D /tmp/headers.$$ -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H 'Content-Type: application/json' "$@"; }
curla() { curl -sS -D /tmp/headers2.$$ -b "$COOKIE_JAR2" -c "$COOKIE_JAR2" -H 'Content-Type: application/json' "$@"; }

# 1. Register user
RESP=$(curlj -X POST "$BASE/register" -d '{"username":"alice","password":"password123"}') || fail "register alice curl"
[[ $(echo "$RESP" | jq -r .username) == "alice" ]] || fail "register alice response"
pass "register alice"

# 2. Duplicate register
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}') || true
[[ "$HTTP" == "409" ]] || fail "duplicate register status"
pass "duplicate register"

# 3. Login alice
RESP=$(curlj -X POST "$BASE/login" -d '{"username":"alice","password":"password123"}') || fail "login alice curl"
[[ $(echo "$RESP" | jq -r .username) == "alice" ]] || fail "login alice response"
pass "login alice"

# 4. /me
RESP=$(curlj "$BASE/me") || fail "/me curl"
[[ $(echo "$RESP" | jq -r .username) == "alice" ]] || fail "/me response"
pass "/me"

# 5. Change password wrong old
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword123"}') || true
[[ "$HTTP" == "401" ]] || fail "password wrong old"
pass "password wrong old"

# 6. Change password ok
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}') || fail "password change curl"
[[ "$HTTP" == "200" ]] || fail "password change status"
pass "password change ok"

# 7. Create todos
RESP=$(curlj -X POST "$BASE/todos" -d '{"title":"Task 1","description":"Desc1"}') || fail "create todo1"
ID1=$(echo "$RESP" | jq -r .id)
RESP=$(curlj -X POST "$BASE/todos" -d '{"title":"Task 2"}') || fail "create todo2"
ID2=$(echo "$RESP" | jq -r .id)
[[ -n "$ID1" && -n "$ID2" ]] || fail "todo ids"
pass "create todos"

# 8. List todos
RESP=$(curlj "$BASE/todos") || fail "list todos"
COUNT=$(echo "$RESP" | jq 'length')
[[ "$COUNT" == "2" ]] || fail "list count"
pass "list todos"

# 9. Get todo by id
RESP=$(curlj "$BASE/todos/$ID1") || fail "get todo1"
[[ $(echo "$RESP" | jq -r .title) == "Task 1" ]] || fail "get todo1 title"
pass "get todo by id"

# 10. Update todo partial
RESP=$(curlj -X PUT "$BASE/todos/$ID1" -d '{"completed":true}') || fail "update todo partial"
[[ $(echo "$RESP" | jq -r .completed) == "true" ]] || fail "update completed"
pass "update partial"

# 11. Delete todo
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X DELETE "$BASE/todos/$ID2") || fail "delete todo2 curl"
[[ "$HTTP" == "204" ]] || fail "delete status"
pass "delete todo"

# 12. Ensure other user cannot access
RESP=$(curla -X POST "$BASE/register" -d '{"username":"bob","password":"password123"}') || fail "register bob"
RESP=$(curla -X POST "$BASE/login" -d '{"username":"bob","password":"password123"}') || fail "login bob"
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR2" -c "$COOKIE_JAR2" "$BASE/todos/$ID1") || true
[[ "$HTTP" == "404" ]] || fail "bob get alice todo should 404"
pass "user isolation"

# 13. Logout invalidates session
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X POST "$BASE/logout") || fail "logout curl"
[[ "$HTTP" == "200" ]] || fail "logout status"
HTTP=$(curl -sS -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/me") || true
[[ "$HTTP" == "401" ]] || fail "after logout should 401"
pass "logout invalidates"

# 14. Content-Type checks (GET /me should be json)
# Need to login again as alice with new password
RESP=$(curlj -X POST "$BASE/login" -d '{"username":"alice","password":"newpassword123"}') || fail "relogin alice"
CT=$(curl -sS -D - -o /dev/null -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/me" | awk '/Content-Type/ {print $2}' | tr -d '\r')
[[ "$CT" == "application/json" ]] || fail "content-type json"
pass "content-type"

# 15. Ensure timestamps format end with Z and no ms
RESP=$(curlj -X POST "$BASE/todos" -d '{"title":"Check TS"}') || fail "create todo3"
CREATED=$(echo "$RESP" | jq -r .created_at)
[[ "$CREATED" =~ Z$ ]] || fail "timestamp ends with Z"
[[ ! "$CREATED" =~ \..*Z$ ]] || fail "timestamp has ms"
pass "timestamp format"

# Done
kill $SERVER_PID || true
wait $SERVER_PID 2>/dev/null || true
echo "ALL TESTS PASSED"
