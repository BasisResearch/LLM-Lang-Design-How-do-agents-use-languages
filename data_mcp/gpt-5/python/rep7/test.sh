#!/usr/bin/env bash
set -euo pipefail

# Start server on a free-ish port
PORT=8123
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
LOG_FILE=$(mktemp)

cleanup() {
  rm -f "$COOKIE_JAR"
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -f "$LOG_FILE" ]]; then
    echo "--- Server log ---"
    cat "$LOG_FILE" || true
    echo "-------------------"
    rm -f "$LOG_FILE"
  fi
}
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" >"$LOG_FILE" 2>&1 &
SERVER_PID=$!

# Wait for server to be ready
ready=0
for i in {1..100}; do
  if curl -sS -o /dev/null "$BASE/me"; then
    ready=1
    break
  fi
  sleep 0.1
done
if [[ $ready -ne 1 ]]; then
  echo "Server failed to start" >&2
  exit 1
fi
sleep 0.2

# 1) Register
echo "Registering user..."
REG=$(curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' \
  -d '{"username": "alice_1", "password": "password123"}')
echo "$REG" | grep -E '"id"\s*:' >/dev/null

# 2) Duplicate register should 409
DUP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/register" -H 'Content-Type: application/json' \
  -d '{"username": "alice_1", "password": "password123"}')
[[ "$DUP_CODE" == "409" ]]

# 3) Login
LOGIN_HEADERS=$(curl -sS -D - -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' \
  -d '{"username": "alice_1", "password": "password123"}' -o /dev/null | tr -d '\r')
echo "$LOGIN_HEADERS" | grep -i '^Set-Cookie: session_id=' >/dev/null

# 4) /me
ME=$(curl -sS -b "$COOKIE_JAR" "$BASE/me")
echo "$ME" | grep -E '"username"\s*:\s*"alice_1"' >/dev/null

# 5) Change password
CHPWD=$(curl -sS -b "$COOKIE_JAR" -X PUT "$BASE/password" -H 'Content-Type: application/json' \
  -d '{"old_password": "password123", "new_password": "newpassword456"}')
echo "$CHPWD" | grep -E '^\{\}$' >/dev/null

# 6) Logout
LOGOUT=$(curl -sS -b "$COOKIE_JAR" -X POST "$BASE/logout")
echo "$LOGOUT" | grep -E '^\{\}$' >/dev/null

# 7) Auth required after logout
AFTER_CODE=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$BASE/me")
[[ "$AFTER_CODE" == "401" ]]

# 8) Login again with new password
LOGIN2_HEADERS=$(curl -sS -D - -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' \
  -d '{"username": "alice_1", "password": "newpassword456"}' -o /dev/null | tr -d '\r')
echo "$LOGIN2_HEADERS" | grep -i '^Set-Cookie: session_id=' >/dev/null

# 9) Create todos
T1=$(curl -sS -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' \
  -d '{"title": "Task 1", "description": "Desc 1"}')
T2=$(curl -sS -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' \
  -d '{"title": "Task 2"}')
echo "$T1" | grep -E '"title"\s*:\s*"Task 1"' >/dev/null
echo "$T2" | grep -E '"title"\s*:\s*"Task 2"' >/dev/null

# 10) List todos
L=$(curl -sS -b "$COOKIE_JAR" "$BASE/todos")
echo "$L" | grep 'Task 1' >/dev/null

echo "$L" | grep 'Task 2' >/dev/null

# 11) Get todo id 1
G1=$(curl -sS -b "$COOKIE_JAR" "$BASE/todos/1")
echo "$G1" | grep -E '"id"\s*:\s*1' >/dev/null

# 12) Update todo 1
U1=$(curl -sS -b "$COOKIE_JAR" -X PUT "$BASE/todos/1" -H 'Content-Type: application/json' \
  -d '{"completed": true, "title": "Task 1 updated"}')
echo "$U1" | grep -E '"completed"\s*:\s*true' >/dev/null

echo "$U1" | grep -E '"title"\s*:\s*"Task 1 updated"' >/dev/null

# 13) Delete todo 2
D2_CODE=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X DELETE "$BASE/todos/2")
[[ "$D2_CODE" == "204" ]]

# 14) Ensure 404 on deleted
G2_CODE=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' "$BASE/todos/2")
[[ "$G2_CODE" == "404" ]]

# 15) Multi-user isolation test
# Register Bob
curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' \
  -d '{"username": "bob_1", "password": "password123"}' >/dev/null
# Login Bob
curl -sS -D - -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' \
  -d '{"username": "bob_1", "password": "password123"}' -o /dev/null >/dev/null
# Bob cannot access Alice todo 1
BOB_G1_CODE=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' "$BASE/todos/1")
[[ "$BOB_G1_CODE" == "404" ]]

# 16) Content-Type checks (GET JSON)
CT=$(curl -sS -D - -o /dev/null -b "$COOKIE_JAR" "$BASE/todos" | tr -d '\r')
echo "$CT" | awk 'BEGIN{found=0} tolower($0) ~ /^content-type:/ { if (index(tolower($0), "application/json")>0) found=1 } END{ exit(found?0:1) }'

# 17) Delete Content-Length and no body
# First create a new todo to delete
T3=$(curl -sS -b "$COOKIE_JAR" -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title": "Temp"}')
# Find its id using a simple regex extract
T3_ID=$(echo "$T3" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
DC=$(curl -sS -D - -o /dev/null -b "$COOKIE_JAR" -X DELETE "$BASE/todos/$T3_ID" | tr -d '\r')
echo "$DC" | awk 'BEGIN{cl=0} tolower($0) ~ /^content-length: 0$/ {cl=1} END{ exit(cl?0:1) }'

echo "All tests passed."