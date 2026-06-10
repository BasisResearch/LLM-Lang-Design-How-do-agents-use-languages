#!/usr/bin/env bash
set -euo pipefail
PORT=3456
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

./run.sh --port "$PORT" &
PID=$!

wait_for_server() {
  for i in {1..50}; do
    if curl -sS "$BASE/me" -b "$COOKIE_JAR" -o /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# wait a moment
sleep 0.3

# 1. Register user
RESP=$(curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "REGISTER: $RESP" | sed 's/.*/&/'
if ! echo "$RESP" | grep -q '"id"'; then echo "Register failed"; kill $PID; exit 1; fi

# 2. Login and capture cookie
RESP=$(curl -sS -i -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' -c "$COOKIE_JAR")
echo "$RESP" | sed -n '1,10p'
if ! echo "$RESP" | grep -q "Set-Cookie: session_id="; then echo "Login failed: no cookie"; kill $PID; exit 1; fi

# 3. GET /me
RESP=$(curl -sS "$BASE/me" -b "$COOKIE_JAR")
echo "ME: $RESP"

# 4. Change password
RESP=$(curl -sS -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword456"}' -b "$COOKIE_JAR")
echo "PASSWORD: $RESP"

# 5. Create todos
RESP=$(curl -sS -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"First","description":"desc"}' -b "$COOKIE_JAR")
echo "CREATE1: $RESP"
ID1=$(echo "$RESP" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
RESP=$(curl -sS -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Second"}' -b "$COOKIE_JAR")
echo "CREATE2: $RESP"
ID2=$(echo "$RESP" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')

# 6. List todos
RESP=$(curl -sS "$BASE/todos" -b "$COOKIE_JAR")
echo "LIST: $RESP"

# 7. Get specific todo
RESP=$(curl -sS "$BASE/todos/$ID1" -b "$COOKIE_JAR")
echo "GET1: $RESP"

# 8. Update todo partially
RESP=$(curl -sS -X PUT "$BASE/todos/$ID1" -H 'Content-Type: application/json' -d '{"completed":true}' -b "$COOKIE_JAR")
echo "UPDATE1: $RESP"

# 9. Delete todo
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$BASE/todos/$ID2" -b "$COOKIE_JAR")
echo "DELETE2 status: $HTTP_CODE"
if [[ "$HTTP_CODE" != "204" ]]; then echo "Delete failed"; kill $PID; exit 1; fi

# 10. Logout
RESP=$(curl -sS -X POST "$BASE/logout" -b "$COOKIE_JAR")
echo "LOGOUT: $RESP"

# 11. Check that session invalidated
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/me" -b "$COOKIE_JAR")
echo "ME after logout status: $HTTP_CODE"
if [[ "$HTTP_CODE" != "401" ]]; then echo "Logout did not invalidate session"; kill $PID; exit 1; fi

# 12. Login with new password to verify change
RESP=$(curl -sS -i -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword456"}' -c "$COOKIE_JAR")
echo "$RESP" | sed -n '1,10p'
if ! echo "$RESP" | grep -q "Set-Cookie: session_id="; then echo "Re-Login failed: no cookie"; kill $PID; exit 1; fi

# 13. Negative tests
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/todos/99999" -b "$COOKIE_JAR")
echo "GET missing todo status: $HTTP_CODE"

# Cleanup
kill $PID
wait $PID 2>/dev/null || true

echo "All tests completed"