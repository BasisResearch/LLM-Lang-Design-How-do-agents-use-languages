#!/usr/bin/env bash
set -euo pipefail
PORT=18123
ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT_DIR"
# Prebuild to avoid long wait on first run
( cd todo_server && cargo build --release )

./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for server
for i in {1..60}; do
  if curl -s -m 1 "http://127.0.0.1:$PORT/me" -D /dev/null -o /dev/null; then
    break
  fi
  sleep 0.2
done

fail() { echo "TEST FAILED: $*" >&2; exit 1; }

aassert_status() {
  local expected="$1"; shift
  local resp="$1"; shift
  local status
  status=$(printf '%s' "$resp" | tr -d '\r' | head -n1 | awk '{print $2}')
  [[ "$status" == "$expected" ]] || fail "Expected status $expected got $status. Response: $resp"
}

aassert_header_contains() {
  local resp="$1"; shift
  local header_name="$1"; shift
  local pattern="$1"; shift
  printf '%s' "$resp" | tr -d '\r' | awk -v hn="$header_name" 'BEGIN{IGNORECASE=1} $0 ~ "^"hn":" {print}' | grep -qE "$pattern" || fail "Header $header_name missing pattern $pattern"
}

aassert_json_key() {
  local resp="$1"; shift
  local key="$1"; shift
  local jq_filter=".$key"
  local body
  body=$(printf '%s' "$resp" | sed -n '/^\r\{0,1\}$/,$p' | tail -n +2)
  echo "$body" | jq -e "$jq_filter | . != null" >/dev/null || fail "JSON key $key missing in body $body"
}

COOKIEJAR=$(mktemp)

# 1. Invalid register (username)
R=$(curl -s -i -m 5 -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' -d '{"username":"ab","password":"password123"}')
aassert_status 400 "$R"
aassert_header_contains "$R" 'Content-Type' 'application/json'

# 2. Invalid register (password)
R=$(curl -s -i -m 5 -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"short"}')
aassert_status 400 "$R"

# 3. Register ok
R=$(curl -s -i -m 5 -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
aassert_status 201 "$R"
aassert_header_contains "$R" 'Content-Type' 'application/json'

# 4. Duplicate register
R=$(curl -s -i -m 5 -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
aassert_status 409 "$R"

# 5. Login invalid
R=$(curl -s -i -m 5 -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"wrongpass"}')
aassert_status 401 "$R"

# 6. Login valid
R=$(curl -s -i -c "$COOKIEJAR" -m 5 -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
aassert_status 200 "$R"
aassert_header_contains "$R" 'Set-Cookie' 'session_id='

# 7. /me
R=$(curl -s -i -b "$COOKIEJAR" -m 5 "http://127.0.0.1:$PORT/me")
aassert_status 200 "$R"

# 8. change password wrong old
R=$(curl -s -i -b "$COOKIEJAR" -m 5 -X PUT "http://127.0.0.1:$PORT/password" -H 'Content-Type: application/json' -d '{"old_password":"nope","new_password":"newpassword1"}')
aassert_status 401 "$R"

# 9. change password ok
R=$(curl -s -i -b "$COOKIEJAR" -m 5 -X PUT "http://127.0.0.1:$PORT/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword1"}')
aassert_status 200 "$R"

# 10. logout
R=$(curl -s -i -b "$COOKIEJAR" -m 5 -X POST "http://127.0.0.1:$PORT/logout")
aassert_status 200 "$R"

# 11. me after logout -> 401
R=$(curl -s -i -b "$COOKIEJAR" -m 5 "http://127.0.0.1:$PORT/me")
aassert_status 401 "$R"

# 12. login with new password
R=$(curl -s -i -c "$COOKIEJAR" -m 5 -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword1"}')
aassert_status 200 "$R"

# 13. create todo missing title
R=$(curl -s -i -b "$COOKIEJAR" -m 5 -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' -d '{"description":"desc"}')
aassert_status 400 "$R"

# 14. create todo 1
R1=$(curl -s -i -b "$COOKIEJAR" -m 5 -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' -d '{"title":"A","description":"first"}')
aassert_status 201 "$R1"

# 15. create todo 2
R2=$(curl -s -i -b "$COOKIEJAR" -m 5 -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' -d '{"title":"B"}')
aassert_status 201 "$R2"

# 16. list todos -> 2 items
R=$(curl -s -i -b "$COOKIEJAR" -m 5 "http://127.0.0.1:$PORT/todos")
aassert_status 200 "$R"
BODY=$(printf '%s' "$R" | tr -d '\r' | awk 'f{print} /^$/{f=1}')
COUNT=$(echo "$BODY" | jq 'length')
[[ "$COUNT" -eq 2 ]] || fail "Expected 2 todos, got $COUNT: $BODY"

# 17. get todo 1
R=$(curl -s -i -b "$COOKIEJAR" -m 5 "http://127.0.0.1:$PORT/todos/1")
aassert_status 200 "$R"

# 18. update todo 1 completed true
R=$(curl -s -i -b "$COOKIEJAR" -m 5 -X PUT "http://127.0.0.1:$PORT/todos/1" -H 'Content-Type: application/json' -d '{"completed":true}')
aassert_status 200 "$R"

# 19. update todo 2 title empty -> 400
R=$(curl -s -i -b "$COOKIEJAR" -m 5 -X PUT "http://127.0.0.1:$PORT/todos/2" -H 'Content-Type: application/json' -d '{"title":""}')
aassert_status 400 "$R"

# 20. delete todo 1 -> 204
R=$(curl -s -i -b "$COOKIEJAR" -m 5 -X DELETE "http://127.0.0.1:$PORT/todos/1")
aassert_status 204 "$R"

# 21. get deleted -> 404
R=$(curl -s -i -b "$COOKIEJAR" -m 5 "http://127.0.0.1:$PORT/todos/1")
aassert_status 404 "$R"

# 22. 404 for other user access
# create second user and todo
R=$(curl -s -i -m 5 -X POST "http://127.0.0.1:$PORT/register" -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password456"}')
aassert_status 201 "$R"
CJ2=$(mktemp)
R=$(curl -s -i -c "$CJ2" -m 5 -X POST "http://127.0.0.1:$PORT/login" -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password456"}')
aassert_status 200 "$R"
R=$(curl -s -i -b "$CJ2" -m 5 -X POST "http://127.0.0.1:$PORT/todos" -H 'Content-Type: application/json' -d '{"title":"X"}')
aassert_status 201 "$R"
# user_1 tries to access user_2's todo id=1 (for their own space it might be 2 now, but other user has id 1 as first)
R=$(curl -s -i -b "$COOKIEJAR" -m 5 "http://127.0.0.1:$PORT/todos/1")
aassert_status 404 "$R"

echo "All tests passed."