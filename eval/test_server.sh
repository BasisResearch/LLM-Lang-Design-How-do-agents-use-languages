#!/usr/bin/env bash
set -euo pipefail
# Source toolchains
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"
[ -f "$HOME/.elan/env" ] && source "$HOME/.elan/env"


# ── Usage ────────────────────────────────────────────────────────────────────
# ./test_server.sh "python reference/server.py"
# The command will be invoked with --port PORT appended automatically.
# ─────────────────────────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
  echo "Usage: $0 <server-command>" >&2
  exit 1
fi

SERVER_CMD="$1"

# ── Setup ────────────────────────────────────────────────────────────────────
PORT=$(( (RANDOM % 10000) + 20000 ))
TMPDIR_TEST=$(mktemp -d)
COOKIE_A="$TMPDIR_TEST/cookieA"
COOKIE_B="$TMPDIR_TEST/cookieB"
COOKIE_EMPTY="$TMPDIR_TEST/cookieEmpty"
SERVER_PID=""
PASSED=0
FAILED=0
TEST_NUM=0

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

# ── Start server ─────────────────────────────────────────────────────────────
$SERVER_CMD --port "$PORT" > "$TMPDIR_TEST/server.log" 2>&1 &
SERVER_PID=$!

# Wait for readiness
for i in $(seq 1 20); do
  if curl -sf "http://localhost:$PORT/me" -o /dev/null 2>/dev/null; then
    break
  fi
  # Accept 401 as "server is up"
  if curl -sf -o /dev/null -w "%{http_code}" "http://localhost:$PORT/me" 2>/dev/null | grep -q "401"; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Server process died. Log:" >&2
    cat "$TMPDIR_TEST/server.log" >&2
    exit 1
  fi
  sleep 0.5
done

# Final check
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "http://localhost:$PORT/me" 2>/dev/null || true)
if [ "$HTTP_CODE" != "401" ]; then
  echo "Server not ready on port $PORT after 10s. Last HTTP code: $HTTP_CODE" >&2
  cat "$TMPDIR_TEST/server.log" >&2
  exit 1
fi

BASE="http://localhost:$PORT"

# ── Test helpers ─────────────────────────────────────────────────────────────
assert_status() {
  local description="$1" expected="$2" actual="$3"
  TEST_NUM=$((TEST_NUM + 1))
  if [ "$actual" = "$expected" ]; then
    echo "ok $TEST_NUM - $description"
    PASSED=$((PASSED + 1))
  else
    echo "not ok $TEST_NUM - $description (expected $expected, got $actual)"
    FAILED=$((FAILED + 1))
  fi
}

assert_json_field() {
  local description="$1" body="$2" field="$3" expected="$4"
  TEST_NUM=$((TEST_NUM + 1))
  actual=$(echo "$body" | jq -r "$field" 2>/dev/null || echo "__JQ_ERROR__")
  if [ "$actual" = "$expected" ]; then
    echo "ok $TEST_NUM - $description"
    PASSED=$((PASSED + 1))
  else
    echo "not ok $TEST_NUM - $description (expected '$expected', got '$actual')"
    FAILED=$((FAILED + 1))
  fi
}

# curl wrapper: returns "STATUS\nBODY"
do_req() {
  local method="$1" path="$2" cookie_file="$3"
  shift 3
  # remaining args are extra curl flags (e.g. -d '...')
  local resp
  resp=$(curl -s -w "\n%{http_code}" -X "$method" \
    -H "Content-Type: application/json" \
    -b "$cookie_file" -c "$cookie_file" \
    "$@" \
    "$BASE$path" 2>/dev/null)
  echo "$resp"
}

get_status() { echo "$1" | tail -1; }
get_body()   { echo "$1" | sed '$d'; }

# ── TAP header ───────────────────────────────────────────────────────────────
echo "TAP version 13"

# ═══════════════════════════════════════════════════════════════════════════════
# REGISTRATION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# 1. Register user A
RESP=$(do_req POST /register "$COOKIE_EMPTY" -d '{"username":"alice","password":"password123"}')
assert_status "Register user alice" "201" "$(get_status "$RESP")"
assert_json_field "Register returns username" "$(get_body "$RESP")" ".username" "alice"
assert_json_field "Register returns id" "$(get_body "$RESP")" ".id" "1"

# 2. Duplicate registration
RESP=$(do_req POST /register "$COOKIE_EMPTY" -d '{"username":"alice","password":"password123"}')
assert_status "Duplicate registration returns 409" "409" "$(get_status "$RESP")"

# 3. Short password
RESP=$(do_req POST /register "$COOKIE_EMPTY" -d '{"username":"shortpw","password":"short"}')
assert_status "Short password returns 400" "400" "$(get_status "$RESP")"

# 4. Invalid username (too short)
RESP=$(do_req POST /register "$COOKIE_EMPTY" -d '{"username":"ab","password":"password123"}')
assert_status "Short username returns 400" "400" "$(get_status "$RESP")"

# 5. Invalid username (special chars)
RESP=$(do_req POST /register "$COOKIE_EMPTY" -d '{"username":"bad user!","password":"password123"}')
assert_status "Invalid username chars returns 400" "400" "$(get_status "$RESP")"

# 6. Missing fields
RESP=$(do_req POST /register "$COOKIE_EMPTY" -d '{}')
assert_status "Missing fields returns 400" "400" "$(get_status "$RESP")"

# ═══════════════════════════════════════════════════════════════════════════════
# LOGIN TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# 7. Login success
RESP=$(do_req POST /login "$COOKIE_A" -d '{"username":"alice","password":"password123"}')
assert_status "Login alice succeeds" "200" "$(get_status "$RESP")"
assert_json_field "Login returns username" "$(get_body "$RESP")" ".username" "alice"

# 8. Login wrong password
RESP=$(do_req POST /login "$COOKIE_EMPTY" -d '{"username":"alice","password":"wrongpassword"}')
assert_status "Wrong password returns 401" "401" "$(get_status "$RESP")"

# 9. Login unknown user
RESP=$(do_req POST /login "$COOKIE_EMPTY" -d '{"username":"unknown","password":"password123"}')
assert_status "Unknown user returns 401" "401" "$(get_status "$RESP")"

# ═══════════════════════════════════════════════════════════════════════════════
# AUTH ENFORCEMENT TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# 10. GET /me without auth
RESP=$(do_req GET /me "$COOKIE_EMPTY")
assert_status "GET /me without auth returns 401" "401" "$(get_status "$RESP")"

# 11. GET /todos without auth
RESP=$(do_req GET /todos "$COOKIE_EMPTY")
assert_status "GET /todos without auth returns 401" "401" "$(get_status "$RESP")"

# 12. POST /todos without auth
RESP=$(do_req POST /todos "$COOKIE_EMPTY" -d '{"title":"test"}')
assert_status "POST /todos without auth returns 401" "401" "$(get_status "$RESP")"

# 13. POST /logout without auth
RESP=$(do_req POST /logout "$COOKIE_EMPTY")
assert_status "POST /logout without auth returns 401" "401" "$(get_status "$RESP")"

# 14. PUT /password without auth
RESP=$(do_req PUT /password "$COOKIE_EMPTY" -d '{"old_password":"x","new_password":"y"}')
assert_status "PUT /password without auth returns 401" "401" "$(get_status "$RESP")"

# ═══════════════════════════════════════════════════════════════════════════════
# GET /me TEST
# ═══════════════════════════════════════════════════════════════════════════════

# 15. GET /me with auth
RESP=$(do_req GET /me "$COOKIE_A")
assert_status "GET /me returns 200" "200" "$(get_status "$RESP")"
assert_json_field "GET /me returns username" "$(get_body "$RESP")" ".username" "alice"

# ═══════════════════════════════════════════════════════════════════════════════
# TODO CRUD TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# 16. Create todo
RESP=$(do_req POST /todos "$COOKIE_A" -d '{"title":"Buy milk","description":"From the store"}')
assert_status "Create todo returns 201" "201" "$(get_status "$RESP")"
assert_json_field "Todo has title" "$(get_body "$RESP")" ".title" "Buy milk"
assert_json_field "Todo has description" "$(get_body "$RESP")" ".description" "From the store"
assert_json_field "Todo completed is false" "$(get_body "$RESP")" ".completed" "false"
TODO_ID=$(echo "$(get_body "$RESP")" | jq -r '.id')

# 17. Create todo without title
RESP=$(do_req POST /todos "$COOKIE_A" -d '{"description":"no title"}')
assert_status "Create todo without title returns 400" "400" "$(get_status "$RESP")"

# 18. Create todo with empty title
RESP=$(do_req POST /todos "$COOKIE_A" -d '{"title":""}')
assert_status "Create todo with empty title returns 400" "400" "$(get_status "$RESP")"

# 19. Create second todo (for list test)
RESP=$(do_req POST /todos "$COOKIE_A" -d '{"title":"Walk dog"}')
assert_status "Create second todo returns 201" "201" "$(get_status "$RESP")"
TODO_ID_2=$(echo "$(get_body "$RESP")" | jq -r '.id')

# 20. List todos
RESP=$(do_req GET /todos "$COOKIE_A")
assert_status "List todos returns 200" "200" "$(get_status "$RESP")"
BODY=$(get_body "$RESP")
COUNT=$(echo "$BODY" | jq 'length')
assert_json_field "List returns 2 todos" "$BODY" "length" "2"

# 21. Get single todo
RESP=$(do_req GET "/todos/$TODO_ID" "$COOKIE_A")
assert_status "Get todo returns 200" "200" "$(get_status "$RESP")"
assert_json_field "Get todo returns correct title" "$(get_body "$RESP")" ".title" "Buy milk"

# 22. Update todo title
RESP=$(do_req PUT "/todos/$TODO_ID" "$COOKIE_A" -d '{"title":"Buy oat milk"}')
assert_status "Update todo title returns 200" "200" "$(get_status "$RESP")"
assert_json_field "Updated title is correct" "$(get_body "$RESP")" ".title" "Buy oat milk"
assert_json_field "Description unchanged" "$(get_body "$RESP")" ".description" "From the store"

# 23. Mark todo as completed
RESP=$(do_req PUT "/todos/$TODO_ID" "$COOKIE_A" -d '{"completed":true}')
assert_status "Complete todo returns 200" "200" "$(get_status "$RESP")"
assert_json_field "Todo is completed" "$(get_body "$RESP")" ".completed" "true"

# 24. Delete todo
RESP=$(do_req DELETE "/todos/$TODO_ID_2" "$COOKIE_A")
assert_status "Delete todo returns 204" "204" "$(get_status "$RESP")"

# 25. Get deleted todo
RESP=$(do_req GET "/todos/$TODO_ID_2" "$COOKIE_A")
assert_status "Get deleted todo returns 404" "404" "$(get_status "$RESP")"

# 26. List todos after delete
RESP=$(do_req GET /todos "$COOKIE_A")
assert_json_field "List returns 1 todo after delete" "$(get_body "$RESP")" "length" "1"

# 27. Todo has timestamps
RESP=$(do_req GET "/todos/$TODO_ID" "$COOKIE_A")
BODY=$(get_body "$RESP")
CREATED=$(echo "$BODY" | jq -r '.created_at')
UPDATED=$(echo "$BODY" | jq -r '.updated_at')
TEST_NUM=$((TEST_NUM + 1))
if [[ "$CREATED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
  echo "ok $TEST_NUM - created_at is ISO 8601 UTC"
  PASSED=$((PASSED + 1))
else
  echo "not ok $TEST_NUM - created_at is ISO 8601 UTC (got '$CREATED')"
  FAILED=$((FAILED + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
# USER ISOLATION TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# Register and login user B
do_req POST /register "$COOKIE_EMPTY" -d '{"username":"bob","password":"password456"}' > /dev/null
RESP=$(do_req POST /login "$COOKIE_B" -d '{"username":"bob","password":"password456"}')
assert_status "Login bob succeeds" "200" "$(get_status "$RESP")"

# 28. User B cannot see user A's todo
RESP=$(do_req GET "/todos/$TODO_ID" "$COOKIE_B")
assert_status "Bob cannot get Alice's todo (404)" "404" "$(get_status "$RESP")"

# 29. User B cannot update user A's todo
RESP=$(do_req PUT "/todos/$TODO_ID" "$COOKIE_B" -d '{"title":"hacked"}')
assert_status "Bob cannot update Alice's todo (404)" "404" "$(get_status "$RESP")"

# 30. User B cannot delete user A's todo
RESP=$(do_req DELETE "/todos/$TODO_ID" "$COOKIE_B")
assert_status "Bob cannot delete Alice's todo (404)" "404" "$(get_status "$RESP")"

# 31. User B's todo list is empty
RESP=$(do_req GET /todos "$COOKIE_B")
assert_json_field "Bob's todo list is empty" "$(get_body "$RESP")" "length" "0"

# 32. User B creates own todo
RESP=$(do_req POST /todos "$COOKIE_B" -d '{"title":"Bob task"}')
assert_status "Bob creates todo" "201" "$(get_status "$RESP")"
BOB_TODO_ID=$(echo "$(get_body "$RESP")" | jq -r '.id')

# 33. User A cannot see user B's todo (per-user IDs are valid, so accept 404 or own data)
RESP=$(do_req GET "/todos/$BOB_TODO_ID" "$COOKIE_A")
STATUS_46=$(get_status "$RESP")
TEST_NUM=$((TEST_NUM + 1))
if [ "$STATUS_46" = "404" ]; then
  echo "ok $TEST_NUM - Alice cannot see Bob's todo (404)"
  PASSED=$((PASSED + 1))
elif [ "$STATUS_46" = "200" ]; then
  TITLE_46=$(echo "$(get_body "$RESP")" | jq -r ".title" 2>/dev/null)
  if [ "$TITLE_46" != "Bob task" ]; then
    echo "ok $TEST_NUM - Alice cannot see Bob's todo (per-user IDs, got own data)"
    PASSED=$((PASSED + 1))
  else
    echo "not ok $TEST_NUM - Alice can see Bob's todo data (isolation failure)"
    FAILED=$((FAILED + 1))
  fi
else
  echo "not ok $TEST_NUM - Alice cannot see Bob's todo (expected 404 or 200-own, got $STATUS_46)"
  FAILED=$((FAILED + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
# PASSWORD CHANGE TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# 34. Wrong old password
RESP=$(do_req PUT /password "$COOKIE_A" -d '{"old_password":"wrongold","new_password":"newpass1234"}')
assert_status "Wrong old password returns 401" "401" "$(get_status "$RESP")"

# 35. New password too short
RESP=$(do_req PUT /password "$COOKIE_A" -d '{"old_password":"password123","new_password":"short"}')
assert_status "New password too short returns 400" "400" "$(get_status "$RESP")"

# 36. Successful password change
RESP=$(do_req PUT /password "$COOKIE_A" -d '{"old_password":"password123","new_password":"newpassword123"}')
assert_status "Password change succeeds" "200" "$(get_status "$RESP")"

# 37. Login with new password
COOKIE_A2="$TMPDIR_TEST/cookieA2"
RESP=$(do_req POST /login "$COOKIE_A2" -d '{"username":"alice","password":"newpassword123"}')
assert_status "Login with new password succeeds" "200" "$(get_status "$RESP")"

# 38. Old password no longer works
RESP=$(do_req POST /login "$COOKIE_EMPTY" -d '{"username":"alice","password":"password123"}')
assert_status "Old password no longer works" "401" "$(get_status "$RESP")"

# ═══════════════════════════════════════════════════════════════════════════════
# LOGOUT TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# 39. Logout
RESP=$(do_req POST /logout "$COOKIE_A")
assert_status "Logout returns 200" "200" "$(get_status "$RESP")"

# 40. Session invalidated after logout
RESP=$(do_req GET /me "$COOKIE_A")
assert_status "Session invalid after logout" "401" "$(get_status "$RESP")"

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "1..$TEST_NUM"
echo "# Passed: $PASSED / $TEST_NUM"
if [ "$FAILED" -gt 0 ]; then
  echo "# Failed: $FAILED"
  exit 1
else
  echo "# All tests passed!"
  exit 0
fi
