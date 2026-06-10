#!/bin/bash
set -euo pipefail
PORT=8099
BASE=http://127.0.0.1:$PORT
COOKIE_JAR=$(mktemp)
SERVER_LOG=$(mktemp)

cleanup() {
  kill $SERVER_PID >/dev/null 2>&1 || true
  rm -f "$COOKIE_JAR" "$SERVER_LOG"
}
trap cleanup EXIT

./run.sh --port $PORT >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Wait for server to be ready
for i in {1..50}; do
  if curl -sS "$BASE/unknown" -o /dev/null; then
    break
  fi
  sleep 0.1
done

# 1) Register
REG=$(curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
[[ $(echo "$REG" | jq -r '.username') == "user_one" ]]

# 2) Duplicate register -> 409
DUP=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
[[ "$DUP" == "409" ]]

# 3) Login and capture cookie
LOGIN=$(curl -sS -i -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' -c "$COOKIE_JAR")
HTTP_CODE=$(echo "$LOGIN" | awk 'END{print $2}')
[[ "$HTTP_CODE" == "200" ]]

# 4) /me should work
ME=$(curl -sS "$BASE/me" -b "$COOKIE_JAR")
[[ $(echo "$ME" | jq -r '.username') == "user_one" ]]

# 5) Create todos
T1=$(curl -sS -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Desc 1"}' -b "$COOKIE_JAR")
ID1=$(echo "$T1" | jq -r '.id')
T2=$(curl -sS -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 2"}' -b "$COOKIE_JAR")
ID2=$(echo "$T2" | jq -r '.id')

# 6) List todos returns 2
LIST=$(curl -sS "$BASE/todos" -b "$COOKIE_JAR")
[[ $(echo "$LIST" | jq 'length') -eq 2 ]]

# 7) Get todo by id
GT=$(curl -sS "$BASE/todos/$ID1" -b "$COOKIE_JAR")
[[ $(echo "$GT" | jq -r '.title') == "Task 1" ]]

# 8) Update todo partially
UT=$(curl -sS -X PUT "$BASE/todos/$ID1" -H 'Content-Type: application/json' -d '{"completed":true,"description":"New D"}' -b "$COOKIE_JAR")
[[ $(echo "$UT" | jq -r '.completed') == "true" ]]

# 9) Delete other todo
DC=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$BASE/todos/$ID2" -b "$COOKIE_JAR")
[[ "$DC" == "204" ]]

# 10) Logout
OUT=$(curl -sS -X POST "$BASE/logout" -b "$COOKIE_JAR")

# 11) Access after logout should be 401
AFTER=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE/me" -b "$COOKIE_JAR")
[[ "$AFTER" == "401" ]]

echo "All tests passed."
