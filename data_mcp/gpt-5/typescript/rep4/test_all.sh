#!/usr/bin/env bash
set -euo pipefail
PORT=33331
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

# Wait for health
for i in {1..200}; do
  if curl -sfS --max-time 2 "${BASE}/health" >/dev/null 2>&1; then break; fi
  sleep 0.05
done

# Helper function for curl with cookie jar and JSON
jcurl() {
  local method="$1"; shift
  local path="$1"; shift
  curl -sS -X "$method" "${BASE}${path}" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

# 1. Register success
RESP=$(jcurl POST /register -d '{"username":"user_one","password":"password123"}')
[[ $(echo "$RESP" | jq -r .id) == 1 ]] || { echo "Register failed: $RESP"; exit 1; }

# 1b. Register invalid username
RESP=$(jcurl POST /register -d '{"username":"ab","password":"password123"}' || true)
[[ $(echo "$RESP" | jq -r .error) == "Invalid username" ]] || { echo "Invalid username check failed: $RESP"; exit 1; }

# 1c. Register short password
RESP=$(jcurl POST /register -d '{"username":"user_x","password":"short"}' || true)
[[ $(echo "$RESP" | jq -r .error) == "Password too short" ]] || { echo "Short password check failed: $RESP"; exit 1; }

# 2. Duplicate register should 409
RESP=$(jcurl POST /register -d '{"username":"user_one","password":"password123"}' || true)
[[ $(echo "$RESP" | jq -r .error) == "Username already exists" ]] || { echo "Duplicate register error: $RESP"; exit 1; }

# 3. Login invalid
RESP=$(jcurl POST /login -d '{"username":"user_one","password":"wrongpass"}' || true)
[[ $(echo "$RESP" | jq -r .error) == "Invalid credentials" ]] || { echo "Login invalid check failed: $RESP"; exit 1; }

# 4. Login success
RESP=$(jcurl POST /login -d '{"username":"user_one","password":"password123"}')
[[ $(echo "$RESP" | jq -r .username) == user_one ]] || { echo "Login failed: $RESP"; exit 1; }

# 5. /me
RESP=$(jcurl GET /me)
[[ $(echo "$RESP" | jq -r .username) == user_one ]] || { echo "/me failed: $RESP"; exit 1; }

# 6. Create todo missing title -> 400
RESP=$(jcurl POST /todos -d '{}') || true
[[ $(echo "$RESP" | jq -r .error) == "Title is required" ]] || { echo "Missing title check failed: $RESP"; exit 1; }

# 7. Create todo success
RESP=$(jcurl POST /todos -d '{"title":"Task 1"}')
T1_ID=$(echo "$RESP" | jq -r .id)
[[ "$T1_ID" == "1" ]] || { echo "Todo create failed: $RESP"; exit 1; }
[[ $(echo "$RESP" | jq -r .description) == "" ]] || { echo "Default description failed: $RESP"; exit 1; }
[[ $(echo "$RESP" | jq -r .completed) == "false" ]] || { echo "Default completed failed: $RESP"; exit 1; }
C1=$(echo "$RESP" | jq -r .created_at)
U1=$(echo "$RESP" | jq -r .updated_at)
[[ "$C1" == "$U1" ]] || { echo "created/updated mismatch: $RESP"; exit 1; }

# 8. List todos -> 1 item ordered
RESP=$(jcurl GET /todos)
[[ $(echo "$RESP" | jq 'length') -eq 1 ]] || { echo "List count failed: $RESP"; exit 1; }
[[ $(echo "$RESP" | jq -r '.[0].id') -eq 1 ]] || { echo "List order failed: $RESP"; exit 1; }

# 9. Get todo by id
RESP=$(jcurl GET /todos/$T1_ID)
[[ $(echo "$RESP" | jq -r .title) == "Task 1" ]] || { echo "Get by id failed: $RESP"; exit 1; }

# 10. Update with empty title -> 400
RESP=$(jcurl PUT /todos/$T1_ID -d '{"title":""}') || true
[[ $(echo "$RESP" | jq -r .error) == "Title is required" ]] || { echo "Empty title update check failed: $RESP"; exit 1; }

# 11. Update invalid completed type -> 400
RESP=$(jcurl PUT /todos/$T1_ID -d '{"completed":"yes"}') || true
[[ $(echo "$RESP" | jq -r .error) == "Invalid request" ]] || { echo "Invalid completed type check failed: $RESP"; exit 1; }

# 12. Valid update completed true -> updated_at set (may be same second). Sleep 1 to ensure difference.
BEFORE=$(jcurl GET /todos/$T1_ID | jq -r .updated_at)
sleep 1
RESP=$(jcurl PUT /todos/$T1_ID -d '{"completed":true}')
AFTER=$(echo "$RESP" | jq -r .updated_at)
[[ "$AFTER" != "$BEFORE" ]] || { echo "updated_at did not change: $RESP"; exit 1; }
[[ $(echo "$RESP" | jq -r .completed) == "true" ]] || { echo "Completed not true: $RESP"; exit 1; }

# 13. Delete todo -> 204
STATUS=$(curl -sS -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -c "$COOKIE_JAR" -X DELETE "${BASE}/todos/${T1_ID}")
[[ "$STATUS" == "204" ]] || { echo "Delete status $STATUS"; exit 1; }

# 14. Get deleted -> 404
RESP=$(jcurl GET /todos/$T1_ID || true)
[[ $(echo "$RESP" | jq -r .error) == "Todo not found" ]] || { echo "Deleted GET check failed: $RESP"; exit 1; }

# 15. Create another todo and test logout
RESP=$(jcurl POST /todos -d '{"title":"Task 2"}')
T2_ID=$(echo "$RESP" | jq -r .id)

# 16. Logout
RESP=$(jcurl POST /logout)
[[ "$RESP" == '{}' ]] || { echo "Logout failed: $RESP"; exit 1; }

# 17. Access after logout -> 401
RESP=$(jcurl GET /me || true)
[[ $(echo "$RESP" | jq -r .error) == "Authentication required" ]] || { echo "Post-logout /me check failed: $RESP"; exit 1; }

# 18. Login again
RESP=$(jcurl POST /login -d '{"username":"user_one","password":"password123"}')
[[ $(echo "$RESP" | jq -r .username) == user_one ]] || { echo "Re-login failed: $RESP"; exit 1; }

# 19. Change password wrong old -> 401
RESP=$(jcurl PUT /password -d '{"old_password":"bad","new_password":"newpassword123"}' || true)
[[ $(echo "$RESP" | jq -r .error) == "Invalid credentials" ]] || { echo "Wrong old password check failed: $RESP"; exit 1; }

# 20. Change password too short -> 400
RESP=$(jcurl PUT /password -d '{"old_password":"password123","new_password":"short"}' || true)
[[ $(echo "$RESP" | jq -r .error) == "Password too short" ]] || { echo "Short new password check failed: $RESP"; exit 1; }

# 21. Change password success
RESP=$(jcurl PUT /password -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$RESP" == '{}' ]] || { echo "Password change failed: $RESP"; exit 1; }

# 22. Logout and try old password -> fail
RESP=$(jcurl POST /logout)
RESP=$(jcurl POST /login -d '{"username":"user_one","password":"password123"}' || true)
[[ $(echo "$RESP" | jq -r .error) == "Invalid credentials" ]] || { echo "Old password still works: $RESP"; exit 1; }

# 23. Login with new password -> success
RESP=$(jcurl POST /login -d '{"username":"user_one","password":"newpassword123"}')
[[ $(echo "$RESP" | jq -r .username) == user_one ]] || { echo "New password login failed: $RESP"; exit 1; }

# 24. Create second user and verify 404 for other's todo
RESP=$(jcurl POST /register -d '{"username":"user_two","password":"password123"}')
RESP=$(jcurl POST /login -d '{"username":"user_two","password":"password123"}')
RESP=$(jcurl GET /todos/$T2_ID || true)
[[ $(echo "$RESP" | jq -r .error) == "Todo not found" ]] || { echo "Cross-user GET failed: $RESP"; exit 1; }

# 25. Ensure Content-Type json for non-DELETE
HDRS=$(curl -sSI -b "$COOKIE_JAR" -c "$COOKIE_JAR" "${BASE}/me")
[[ $(echo "$HDRS" | grep -i '^Content-Type:' | tr -d '\r' | awk '{print tolower($0)}') == *"application/json"* ]] || { echo "Content-Type header missing: $HDRS"; exit 1; }

# Done
echo "All tests passed"
