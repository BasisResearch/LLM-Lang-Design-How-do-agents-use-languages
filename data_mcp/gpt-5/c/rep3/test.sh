#!/usr/bin/env bash
set -euo pipefail
PORT=${1:-18080}
BASE="http://127.0.0.1:$PORT"

# Ensure tools
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y jq
  else
    echo "jq is required" >&2; exit 1
  fi
fi

# Start server
./run.sh --port "$PORT" >server_test.log 2>&1 &
SPID=$!
echo "Server PID $SPID on $BASE"
trap 'kill $SPID 2>/dev/null || true; rm -f "$COOKIE_FILE" server_test.log' EXIT

# Wait for server
for i in $(seq 1 50); do
  if curl -sS "$BASE/me" >/dev/null; then break; fi
  sleep 0.1
done

echo "Testing server on $BASE"

# Helper to extract cookie
COOKIE_FILE=$(mktemp)

# Unique username
UNAME="user_$(date +%s)_$RANDOM"
PASS="password123"

# 1. Register
REG=$(curl -s -S -X POST "$BASE/register" -H 'Content-Type: application/json' -d "{\"username\":\"$UNAME\",\"password\":\"$PASS\"}")
[[ $(echo "$REG" | jq -r .username) == "$UNAME" ]] || { echo "Register failed: $REG"; exit 1; }

# 1b. Register duplicate -> 409
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/register" -H 'Content-Type: application/json' -d "{\"username\":\"$UNAME\",\"password\":\"$PASS\"}")
[[ "$CODE" == "409" ]] || { echo "Expected 409, got $CODE"; exit 1; }

# 2. Login
LOGIN=$(curl -s -D "$COOKIE_FILE" -X POST "$BASE/login" -H 'Content-Type: application/json' -d "{\"username\":\"$UNAME\",\"password\":\"$PASS\"}")
SID=$(grep -i '^Set-Cookie:' "$COOKIE_FILE" | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | head -n1)
[[ -n "$SID" ]] || { echo "No session cookie set"; exit 1; }

# 3. /me
ME=$(curl -s -b "session_id=$SID" "$BASE/me")
[[ $(echo "$ME" | jq -r .username) == "$UNAME" ]] || { echo "/me failed: $ME"; exit 1; }

# 4. Create todo missing title -> 400
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "session_id=$SID" -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"description":"test"}')
[[ "$CODE" == "400" ]] || { echo "Expected 400, got $CODE"; exit 1; }

# 5. Create todo
TODO=$(curl -s -b "session_id=$SID" -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"desc"}')
TID=$(echo "$TODO" | jq -r .id)
[[ "$TID" != "null" ]] || { echo "Todo create failed: $TODO"; exit 1; }

# 6. List todos
LIST=$(curl -s -b "session_id=$SID" "$BASE/todos")
[[ $(echo "$LIST" | jq 'length') -ge 1 ]] || { echo "List failed: $LIST"; exit 1; }

# 7. Get todo
GET1=$(curl -s -b "session_id=$SID" "$BASE/todos/$TID")
[[ $(echo "$GET1" | jq -r .title) == "Task 1" ]] || { echo "Get failed: $GET1"; exit 1; }

# 8. Update todo partial
UPD=$(curl -s -b "session_id=$SID" -X PUT "$BASE/todos/$TID" -H 'Content-Type: application/json' -d '{"completed":true}')
[[ $(echo "$UPD" | jq -r .completed) == "true" ]] || { echo "Update failed: $UPD"; exit 1; }

# 9. Delete todo
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "session_id=$SID" -X DELETE "$BASE/todos/$TID")
[[ "$CODE" == "204" ]] || { echo "Expected 204, got $CODE"; exit 1; }

# 10. Verify 404 after delete
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "session_id=$SID" "$BASE/todos/$TID")
[[ "$CODE" == "404" ]] || { echo "Expected 404, got $CODE"; exit 1; }

# 11. Change password (bad old)
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "session_id=$SID" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword1"}')
[[ "$CODE" == "401" ]] || { echo "Expected 401, got $CODE"; exit 1; }

# 12. Change password (too short)
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "session_id=$SID" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}')
[[ "$CODE" == "400" ]] || { echo "Expected 400, got $CODE"; exit 1; }

# 13. Change password success
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "session_id=$SID" -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword1"}')
[[ "$CODE" == "200" ]] || { echo "Expected 200, got $CODE"; exit 1; }

# 14. Logout
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "session_id=$SID" -X POST "$BASE/logout")
[[ "$CODE" == "200" ]] || { echo "Expected 200, got $CODE"; exit 1; }

# 15. Access after logout -> 401
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "session_id=$SID" "$BASE/me")
[[ "$CODE" == "401" ]] || { echo "Expected 401, got $CODE"; exit 1; }

echo "All tests passed"
