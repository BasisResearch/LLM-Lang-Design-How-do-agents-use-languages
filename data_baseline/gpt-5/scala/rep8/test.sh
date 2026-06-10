#!/usr/bin/env bash
set -euo pipefail

PORT=8099
COOKIE_JAR=$(mktemp)
SERVER_LOG=$(mktemp)

./run.sh --port "$PORT" >"$SERVER_LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -f "$COOKIE_JAR" "$SERVER_LOG"' EXIT

# Wait for server to start
for i in {1..100}; do
  if curl -s "http://127.0.0.1:$PORT/me" -H 'Accept: application/json' -b "$COOKIE_JAR" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

base() { curl -sS -D >(cat >&2) -H 'Content-Type: application/json' -H 'Accept: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"; }
base_nojson() { curl -sS -D >(cat >&2) -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"; }

# 1. Register
REG=$(base -X POST "http://127.0.0.1:$PORT/register" --data '{"username":"alice_1","password":"password123"}')
[[ $(echo "$REG" | jq -r .username) == "alice_1" ]]

# 1b. Duplicate register should be 409
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H 'Accept: application/json' "http://127.0.0.1:$PORT/register" --data '{"username":"alice_1","password":"password123"}')
[[ "$HTTP_CODE" == "409" ]]

# 2. Login
LOGIN=$(base -X POST "http://127.0.0.1:$PORT/login" --data '{"username":"alice_1","password":"password123"}')
[[ $(echo "$LOGIN" | jq -r .id) -gt 0 ]]

# 3. Me
ME=$(base "http://127.0.0.1:$PORT/me")
[[ $(echo "$ME" | jq -r .username) == "alice_1" ]]

# 4. Create todo
TODO1=$(base -X POST "http://127.0.0.1:$PORT/todos" --data '{"title":"Test Todo","description":"desc"}')
ID1=$(echo "$TODO1" | jq -r .id)
[[ -n "$ID1" && "$ID1" != "null" ]]

# 5. List todos
LIST=$(base "http://127.0.0.1:$PORT/todos")
[[ $(echo "$LIST" | jq 'length') -ge 1 ]]

# 6. Get todo
GOT=$(base "http://127.0.0.1:$PORT/todos/$ID1")
[[ $(echo "$GOT" | jq -r .title) == "Test Todo" ]]

# 7. Update todo partial
UPD=$(base -X PUT "http://127.0.0.1:$PORT/todos/$ID1" --data '{"completed":true}')
[[ $(echo "$UPD" | jq -r .completed) == "true" ]]

# 8. Delete todo
RESP_HEADERS=$(mktemp)
base_nojson -X DELETE "http://127.0.0.1:$PORT/todos/$ID1" -o /dev/null -D "$RESP_HEADERS"
CODE=$(head -n1 "$RESP_HEADERS" | awk '{print $2}')
[[ "$CODE" == "204" ]]

# 9. Change password
PC=$(base -X PUT "http://127.0.0.1:$PORT/password" --data '{"old_password":"password123","new_password":"newpass123"}')
[[ $(echo "$PC" | jq -r 'type') == "object" ]]

# 10. Logout
LOGOUT=$(base -X POST "http://127.0.0.1:$PORT/logout" --data '')
[[ $(echo "$LOGOUT" | jq -r 'type') == "object" ]]

# 11. Access after logout should 401
set +e
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" "http://127.0.0.1:$PORT/me")
set -e
[[ "$HTTP_CODE" == "401" ]]

# 12. Old password should fail
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H 'Accept: application/json' "http://127.0.0.1:$PORT/login" --data '{"username":"alice_1","password":"password123"}')
[[ "$HTTP_CODE" == "401" ]]

# 13. New password should login
LOGIN2=$(base -X POST "http://127.0.0.1:$PORT/login" --data '{"username":"alice_1","password":"newpass123"}')
[[ $(echo "$LOGIN2" | jq -r .username) == "alice_1" ]]

echo "All tests passed"