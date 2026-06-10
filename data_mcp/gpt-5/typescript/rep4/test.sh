#!/usr/bin/env bash
set -euo pipefail
PORT=33333
BASE="http://127.0.0.1:${PORT}"
COOKIE_JAR=$(mktemp)
SERVER_LOG=$(mktemp)

cleanup_all() {
  rm -f "$COOKIE_JAR" "$SERVER_LOG" || true
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup_all EXIT

# Build and start server
npm run build --silent
node dist/index.js --port "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# wait for log line
for i in {1..200}; do
  if grep -q "Server listening on 0.0.0.0:${PORT}" "$SERVER_LOG"; then
    break
  fi
  sleep 0.05
done

# Helper function for curl with cookie jar and JSON
jcurl() {
  local method="$1"; shift
  local path="$1"; shift
  curl -sS -X "$method" "${BASE}${path}" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

# 1. Register
RESP=$(jcurl POST /register -d '{"username":"user_one","password":"password123"}')
TEST_ID=$(echo "$RESP" | jq -r '.id')
if [[ "$TEST_ID" != "1" ]]; then echo "Register failed: $RESP"; echo "LOG:"; cat "$SERVER_LOG"; exit 1; fi

# 2. Duplicate register should 409
RESP=$(jcurl POST /register -d '{"username":"user_one","password":"password123"}' || true)
ERR=$(echo "$RESP" | jq -r '.error')
if [[ "$ERR" != "Username already exists" ]]; then echo "Duplicate register error: $RESP"; exit 1; fi

# 3. Login
RESP=$(jcurl POST /login -d '{"username":"user_one","password":"password123"}')
if [[ $(echo "$RESP" | jq -r '.username') != "user_one" ]]; then echo "Login failed: $RESP"; exit 1; fi

# 4. /me
RESP=$(jcurl GET /me)
if [[ $(echo "$RESP" | jq -r '.username') != "user_one" ]]; then echo "/me failed: $RESP"; exit 1; fi

# 5. Change password with wrong old should 401
RESP=$(jcurl PUT /password -d '{"old_password":"wrong","new_password":"newpassword123"}' || true)
if [[ $(echo "$RESP" | jq -r '.error') != "Invalid credentials" ]]; then echo "Wrong old password check failed: $RESP"; exit 1; fi

# 6. Change password success
RESP=$(jcurl PUT /password -d '{"old_password":"password123","new_password":"newpassword123"}')
if [[ "$RESP" != "{}" ]]; then echo "Password change failed: $RESP"; exit 1; fi

# 7. Create todos
RESP=$(jcurl POST /todos -d '{"title":"Task 1","description":"Desc 1"}')
ID1=$(echo "$RESP" | jq -r '.id')
RESP=$(jcurl POST /todos -d '{"title":"Task 2"}')
ID2=$(echo "$RESP" | jq -r '.id')

# 8. List todos
RESP=$(jcurl GET /todos)
COUNT=$(echo "$RESP" | jq 'length')
if [[ "$COUNT" -ne 2 ]]; then echo "List count failed: $RESP"; exit 1; fi

# 9. Get todo by id
RESP=$(jcurl GET /todos/$ID1)
if [[ $(echo "$RESP" | jq -r '.title') != "Task 1" ]]; then echo "Get todo failed: $RESP"; exit 1; fi

# 10. Update todo partially
RESP=$(jcurl PUT /todos/$ID1 -d '{"completed":true}')
if [[ $(echo "$RESP" | jq -r '.completed') != "true" ]]; then echo "Update failed: $RESP"; exit 1; fi

# 11. Delete second todo
RESP=$(jcurl -i DELETE /todos/$ID2)
STATUS=$(echo "$RESP" | head -n1 | awk '{print $2}')
if [[ "$STATUS" != "204" ]]; then echo "Delete failed: $RESP"; exit 1; fi

# 12. Logout
RESP=$(jcurl POST /logout)
if [[ "$RESP" != "{}" ]]; then echo "Logout failed: $RESP"; exit 1; fi

# 13. Access after logout should 401
RESP=$(jcurl GET /me || true)
if [[ $(echo "$RESP" | jq -r '.error') != "Authentication required" ]]; then echo "Post-logout auth check failed: $RESP"; exit 1; fi

# 14. Login with new password
RESP=$(jcurl POST /login -d '{"username":"user_one","password":"newpassword123"}')
if [[ $(echo "$RESP" | jq -r '.username') != "user_one" ]]; then echo "Re-login failed: $RESP"; exit 1; fi

# 15. Ensure listing shows one remaining todo
RESP=$(jcurl GET /todos)
COUNT=$(echo "$RESP" | jq 'length')
if [[ "$COUNT" -ne 1 ]]; then echo "List after delete failed: $RESP"; exit 1; fi

# 16. Ensure timestamps format ends with Z and no milliseconds
TS_CREATED=$(echo "$RESP" | jq -r '.[0].created_at')
TS_UPDATED=$(echo "$RESP" | jq -r '.[0].updated_at')
if [[ ! "$TS_CREATED" =~ Z$ ]]; then echo "created_at format: $TS_CREATED"; exit 1; fi
if [[ "$TS_CREATED" =~ \.[0-9]{3}Z$ ]]; then echo "created_at has ms: $TS_CREATED"; exit 1; fi
if [[ ! "$TS_UPDATED" =~ Z$ ]]; then echo "updated_at format: $TS_UPDATED"; exit 1; fi

# 17. Cross-user access should 404
RESP=$(jcurl POST /register -d '{"username":"user_two","password":"password123"}')
RESP=$(jcurl POST /login -d '{"username":"user_two","password":"password123"}')
RESP=$(jcurl GET /todos/$ID1 || true)
if [[ $(echo "$RESP" | jq -r '.error') != "Todo not found" ]]; then echo "Cross-user GET failed: $RESP"; exit 1; fi

# Done
echo "All tests passed"
