#!/usr/bin/env bash
set -euo pipefail
PORT=$(shuf -i 20000-65000 -n 1)
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)

cleanup() {
  rm -f "$COOKIE_JAR"
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Build and run directly to avoid any install delays
npx tsc -p tsconfig.json
node dist/server.js --port "$PORT" &
SERVER_PID=$!

# Wait for server
for i in {1..100}; do
  if curl -sS -o /dev/null "$BASE/"; then
    break
  fi
  sleep 0.1
  if [[ $i -eq 100 ]]; then
    echo "Server did not start" >&2
    exit 1
  fi
done

# 1. Register
REG=$(curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
echo "$REG" | jq . >/dev/null
[[ $(echo "$REG" | jq -r .username) == "user_one" ]]

# 1b. Duplicate register should be 409
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
[[ "$CODE" == "409" ]]

# 2. Login
LOGIN=$(curl -sS -D headers.txt -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
echo "$LOGIN" | jq . >/dev/null
# Ensure Set-Cookie present
if ! grep -i '^Set-Cookie: ' headers.txt >/dev/null; then echo "Missing Set-Cookie" >&2; exit 1; fi
rm -f headers.txt

# 3. Me
ME=$(curl -sS "$BASE/me" -b "$COOKIE_JAR")
echo "$ME" | jq . >/dev/null

# 4. Create todo
T1=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task A","description":"Desc"}' "$BASE/todos" )
T1_ID=$(echo "$T1" | jq -r .id)
[[ "$T1_ID" =~ ^[0-9]+$ ]]

# 5. List todos
LIST=$(curl -sS -b "$COOKIE_JAR" "$BASE/todos")
COUNT=$(echo "$LIST" | jq 'length')
[[ "$COUNT" -ge 1 ]]

# 6. Get todo by id
G1=$(curl -sS -b "$COOKIE_JAR" "$BASE/todos/$T1_ID")
[[ $(echo "$G1" | jq -r .title) == "Task A" ]]

# 7. Update todo partial
U1=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT -d '{"completed":true}' "$BASE/todos/$T1_ID")
[[ $(echo "$U1" | jq -r .completed) == "true" ]]

# 8. Change password
P1=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT -d '{"old_password":"password123","new_password":"newpass123"}' "$BASE/password")
[[ "$P1" == "{}" ]]

# 9. Logout
L1=$(curl -sS -b "$COOKIE_JAR" -X POST "$BASE/logout")
[[ "$L1" == "{}" ]]

# 10. Ensure old session invalid
CODE=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "$BASE/me")
[[ "$CODE" == "401" ]]

# 11. Re-login with new password
LOGIN2=$(curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpass123"}')
[[ $(echo "$LOGIN2" | jq -r .username) == "user_one" ]]

# 12. Delete todo
CODE=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' -X DELETE "$BASE/todos/$T1_ID")
[[ "$CODE" == "204" ]]

# 13. Get deleted should 404
CODE=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w '%{http_code}' "$BASE/todos/$T1_ID")
[[ "$CODE" == "404" ]]

echo "All tests passed"
