#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-3456}
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
cleanup(){ rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

# Start server in background
./run.sh --port "$PORT" &
SERVER_PID=$!
sleep 0.5

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; kill $SERVER_PID || true; exit 1; }

# Helper to curl with cookie jar
curlj() { curl -sS -D /tmp/headers.$$ -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"; }

# 1) Register user
RESP=$(curlj -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}') || fail "register curl failed"
[[ $(echo "$RESP" | jq -r .username) == "user_one" ]] || fail "register response bad: $RESP"; pass "register"

# 1.1) Register duplicate should 409
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
[[ "$CODE" == "409" ]] || fail "register duplicate status $CODE"; pass "register duplicate 409"

# 2) Login
RESP=$(curlj -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}') || fail "login curl failed"
[[ $(echo "$RESP" | jq -r .username) == "user_one" ]] || fail "login response bad: $RESP"; pass "login"

# 3) /me
RESP=$(curlj "$BASE/me") || fail "/me failed"
[[ $(echo "$RESP" | jq -r .username) == "user_one" ]] || fail "/me response bad: $RESP"; pass "/me"

# 4) Create todo
RESP=$(curlj -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Desc"}') || fail "create todo failed"
ID1=$(echo "$RESP" | jq -r .id)
[[ "$ID1" =~ ^[0-9]+$ ]] || fail "todo id invalid: $RESP"; pass "create todo"

# 5) List todos
RESP=$(curlj "$BASE/todos") || fail "list todos failed"
COUNT=$(echo "$RESP" | jq 'length')
[[ "$COUNT" -ge 1 ]] || fail "list todos empty: $RESP"; pass "list todos"

# 6) Get todo by id
RESP=$(curlj "$BASE/todos/$ID1") || fail "get todo failed"
[[ $(echo "$RESP" | jq -r .title) == "Task 1" ]] || fail "get todo wrong: $RESP"; pass "get todo"

# 7) Update todo (partial)
RESP=$(curlj -X PUT "$BASE/todos/$ID1" -H 'Content-Type: application/json' -d '{"completed":true}') || fail "update todo failed"
[[ $(echo "$RESP" | jq -r .completed) == "true" ]] || fail "update todo wrong: $RESP"; pass "update todo"

# 8) Delete todo
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X DELETE "$BASE/todos/$ID1")
[[ "$CODE" == "204" ]] || fail "delete todo status $CODE"; pass "delete todo"

# 9) Logout
RESP=$(curlj -X POST "$BASE/logout") || fail "logout failed"
[[ "$RESP" == "{}" ]] || fail "logout response bad: $RESP"; pass "logout"

# 10) Verify unauthorized after logout
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/me")
[[ "$CODE" == "401" ]] || fail "expected 401 after logout, got $CODE"; pass "post-logout unauthorized"

# 11) Password change flow: login again, change password, login with new
RESP=$(curlj -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}') || fail "relogin failed"
RESP=$(curlj -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpass123"}') || fail "password change failed"
[[ "$RESP" == "{}" ]] || fail "password change response bad: $RESP"; pass "password change"

# 12) Logout and login with new password
RESP=$(curlj -X POST "$BASE/logout") || fail "logout2 failed"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
[[ "$CODE" == "401" ]] || fail "old password should fail"
RESP=$(curlj -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpass123"}') || fail "login with new password failed"; pass "login with new password"

# 13) Ensure Content-Type application/json on non-DELETE
CT=$(curl -s -D - -o /dev/null -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/me" | awk -F': ' '/Content-Type/ {print $2}' | tr -d '\r')
[[ "$CT" == "application/json" ]] || fail "Content-Type not application/json: $CT"; pass "content-type"

# 14) 404 for other users' todos
# Create another user and todo
CJ2=$(mktemp)
trap 'rm -f "$COOKIE_JAR" "$CJ2"; kill $SERVER_PID 2>/dev/null || true' EXIT
curl -s -b "$CJ2" -c "$CJ2" -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password456"}' >/dev/null
curl -s -b "$CJ2" -c "$CJ2" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password456"}' >/dev/null
RESP=$(curl -s -b "$CJ2" -c "$CJ2" -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Other Task"}')
OID=$(echo "$RESP" | jq -r .id)
CODE=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$BASE/todos/$OID")
[[ "$CODE" == "404" ]] || fail "expected 404 for other user's todo, got $CODE"; pass "404 on other user's todo"

# All tests passed
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true

echo "All tests passed."