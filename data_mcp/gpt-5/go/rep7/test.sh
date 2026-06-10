#!/usr/bin/env bash
set -euo pipefail
PORT=8095
ROOT_URL="http://127.0.0.1:${PORT}"

cleanup() {
  if [[ -n ${SERVER_PID-} ]]; then
    kill ${SERVER_PID} 2>/dev/null || true
    wait ${SERVER_PID} 2>/dev/null || true
  fi
}
trap cleanup EXIT

chmod +x ./run.sh
./run.sh --port ${PORT} >/tmp/server.log 2>&1 &
SERVER_PID=$!
# wait for server
for i in {1..50}; do
  if curl -sS -o /dev/null "${ROOT_URL}/me"; then break; fi
  sleep 0.1
done

echo "Server PID ${SERVER_PID}"

# helper to extract cookie
get_cookie() {
  awk -F': ' '/^Set-Cookie: /{print $2}' "$1" | tr -d '\r' | grep -o 'session_id=[^;]*'
}

# 1. Unauthorized check
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" "${ROOT_URL}/me")
[[ "$STATUS" == "401" ]] || { echo "Expected 401 for /me without auth, got $STATUS"; exit 1; }
cat /tmp/body | grep -q '"error"' || { echo "Unauthorized body missing error"; exit 1; }

# 2. Register
REQ='{"username":"alice_1","password":"password123"}'
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d "$REQ" "${ROOT_URL}/register")
[[ "$STATUS" == "201" ]] || { echo "Register expected 201 got $STATUS"; cat /tmp/body; exit 1; }
cat /tmp/body | grep -q '"username":"alice_1"' || { echo "Register response invalid"; exit 1; }

# 2b duplicate username
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d "$REQ" "${ROOT_URL}/register")
[[ "$STATUS" == "409" ]] || { echo "Duplicate register expected 409 got $STATUS"; cat /tmp/body; exit 1; }

# 3. Login wrong
REQ_BAD='{"username":"alice_1","password":"wrongpass"}'
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d "$REQ_BAD" "${ROOT_URL}/login")
[[ "$STATUS" == "401" ]] || { echo "Login wrong expected 401 got $STATUS"; cat /tmp/body; exit 1; }

# 4. Login ok
HEADERS=/tmp/headers
STATUS=$(curl -s -D "$HEADERS" -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' "${ROOT_URL}/login")
[[ "$STATUS" == "200" ]] || { echo "Login expected 200 got $STATUS"; cat /tmp/body; exit 1; }
COOKIE=$(get_cookie "$HEADERS")
[[ -n "$COOKIE" ]] || { echo "Missing Set-Cookie on login"; exit 1; }

# 5. /me
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H "Cookie: $COOKIE" "${ROOT_URL}/me")
[[ "$STATUS" == "200" ]] || { echo "/me expected 200 got $STATUS"; cat /tmp/body; exit 1; }

# 6. password change validations
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"bad","new_password":"newpassword"}' "${ROOT_URL}/password")
[[ "$STATUS" == "401" ]] || { echo "password old wrong expected 401 got $STATUS"; cat /tmp/body; exit 1; }
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"password123","new_password":"short"}' "${ROOT_URL}/password")
[[ "$STATUS" == "400" ]] || { echo "password short expected 400 got $STATUS"; cat /tmp/body; exit 1; }
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"password123","new_password":"newpassword"}' "${ROOT_URL}/password")
[[ "$STATUS" == "200" ]] || { echo "password change expected 200 got $STATUS"; cat /tmp/body; exit 1; }

# 7. logout invalidates session
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -X POST -H "Cookie: $COOKIE" "${ROOT_URL}/logout")
[[ "$STATUS" == "200" ]] || { echo "logout expected 200 got $STATUS"; cat /tmp/body; exit 1; }
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" "${ROOT_URL}/me")
[[ "$STATUS" == "401" ]] || { echo "after logout expected 401 got $STATUS"; exit 1; }

# 8. login with new password
STATUS=$(curl -s -D "$HEADERS" -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"newpassword"}' "${ROOT_URL}/login")
[[ "$STATUS" == "200" ]] || { echo "re-login expected 200 got $STATUS"; cat /tmp/body; exit 1; }
COOKIE=$(get_cookie "$HEADERS")

# 9. todos list empty
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H "Cookie: $COOKIE" "${ROOT_URL}/todos")
[[ "$STATUS" == "200" ]] || { echo "todos list expected 200 got $STATUS"; cat /tmp/body; exit 1; }
[[ "$(cat /tmp/body)" == "[]
" || "$(cat /tmp/body)" == "[]" ]] || { echo "expected empty list"; cat /tmp/body; exit 1; }

# 10. create todo validations
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -X POST -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"description":"desc only"}' "${ROOT_URL}/todos")
[[ "$STATUS" == "400" ]] || { echo "create todo missing title expected 400 got $STATUS"; cat /tmp/body; exit 1; }

# 11. create todo ok
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -X POST -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":"Task1","description":"desc"}' "${ROOT_URL}/todos")
[[ "$STATUS" == "201" ]] || { echo "create todo expected 201 got $STATUS"; cat /tmp/body; exit 1; }
TODO_ID=$(sed -n 's/.*"id":\s*\([0-9]\+\).*/\1/p' /tmp/body)

# 12. list contains one
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H "Cookie: $COOKIE" "${ROOT_URL}/todos")
[[ "$STATUS" == "200" ]] || { echo "todos list expected 200 got $STATUS"; cat /tmp/body; exit 1; }

echo "$TODO_ID" | grep -qE '^[0-9]+$' || { echo "Invalid todo id"; exit 1; }

# 13. get todo by id
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H "Cookie: $COOKIE" "${ROOT_URL}/todos/${TODO_ID}")
[[ "$STATUS" == "200" ]] || { echo "get todo expected 200 got $STATUS"; cat /tmp/body; exit 1; }

# 14. update validations
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":""}' "${ROOT_URL}/todos/${TODO_ID}")
[[ "$STATUS" == "400" ]] || { echo "update empty title expected 400 got $STATUS"; cat /tmp/body; exit 1; }

# 15. update ok (completed true)
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"completed":true,"description":"updated"}' "${ROOT_URL}/todos/${TODO_ID}")
[[ "$STATUS" == "200" ]] || { echo "update todo expected 200 got $STATUS"; cat /tmp/body; exit 1; }
cat /tmp/body | grep -q '"completed":true' || { echo "completed not true"; cat /tmp/body; exit 1; }

# 16. second user cannot access first user's todo
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"bob_2","password":"password123"}' "${ROOT_URL}/register")
[[ "$STATUS" == "201" ]] || { echo "register bob expected 201 got $STATUS"; cat /tmp/body; exit 1; }
STATUS=$(curl -s -D "$HEADERS" -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"bob_2","password":"password123"}' "${ROOT_URL}/login")
[[ "$STATUS" == "200" ]] || { echo "login bob expected 200 got $STATUS"; cat /tmp/body; exit 1; }
COOKIE2=$(get_cookie "$HEADERS")
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H "Cookie: $COOKIE2" "${ROOT_URL}/todos/${TODO_ID}")
[[ "$STATUS" == "404" ]] || { echo "bob access alice todo expected 404 got $STATUS"; cat /tmp/body; exit 1; }

# 17. delete todo
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -X DELETE -H "Cookie: $COOKIE" "${ROOT_URL}/todos/${TODO_ID}")
[[ "$STATUS" == "204" ]] || { echo "delete expected 204 got $STATUS"; cat /tmp/body; exit 1; }

# 18. list empty again
STATUS=$(curl -s -o /tmp/body -w "%{http_code}" -H "Cookie: $COOKIE" "${ROOT_URL}/todos")
[[ "$STATUS" == "200" ]] || { echo "todos final list expected 200 got $STATUS"; cat /tmp/body; exit 1; }
[[ "$(cat /tmp/body)" == "[]
" || "$(cat /tmp/body)" == "[]" ]] || { echo "expected empty list after delete"; cat /tmp/body; exit 1; }

echo "All tests passed"
