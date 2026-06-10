#!/usr/bin/env bash
set -euo pipefail
PORT=$(( 40000 + (RANDOM % 20000) ))
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

# Build and start server directly to get correct PID
npx tsc -p tsconfig.json >/dev/null
node dist/server.js --port "$PORT" &
SERVER_PID=$!

# wait for server by polling /me for 401
for i in {1..100}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/me") || code=0
  if [[ "$code" == "401" ]]; then
    break
  fi
  sleep 0.1
  if [[ $i -eq 100 ]]; then echo "Server did not start"; exit 1; fi
done

# Helper: expect status code
expect_status() {
  local expected=$1; shift
  local out
  set +e
  out=$(curl -s -o /dev/stderr -w '%{http_code}' "$@")
  local code=$?
  set -e
  if [[ $code -ne 0 ]]; then echo "curl failed"; exit 1; fi
  if [[ "$out" != "$expected" ]]; then echo "Expected $expected got $out for $@"; exit 1; fi
}

# 1. Register
resp=$(curl -s -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$resp" | grep '"id"' >/dev/null

# 2. Duplicate username
expect_status 409 -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"anotherpass"}'

# 3. Login
resp=$(curl -s -D - -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$resp" | tr -d '\r' | grep -i '^set-cookie: session_id=' >/dev/null
# store cookie
curl -s -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' >/dev/null

# 4. /me
resp=$(curl -s "$BASE/me" -b "$COOKIE_JAR")
echo "$resp" | grep '"username":"user_1"' >/dev/null

# 5. Create todos
resp=$(curl -s -X POST "$BASE/todos" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -d '{"title":"Task 1","description":"Desc"}')
echo "$resp" | grep '"title":"Task 1"' >/dev/null
resp=$(curl -s -X POST "$BASE/todos" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -d '{"title":"Task 2"}')
echo "$resp" | grep '"title":"Task 2"' >/dev/null

# 6. List todos
resp=$(curl -s "$BASE/todos" -b "$COOKIE_JAR")
echo "$resp" | grep '"title":"Task 1"' >/dev/null

# 7. Get todo id 1
expect_status 200 "$BASE/todos/1" -b "$COOKIE_JAR"

# 8. Update todo 1
resp=$(curl -s -X PUT "$BASE/todos/1" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -d '{"completed":true,"title":"Task 1 updated"}')
echo "$resp" | grep '"completed":true' >/dev/null

# 9. Delete todo 2
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$BASE/todos/2" -b "$COOKIE_JAR")
if [[ "$code" != "204" ]]; then echo "Expected 204 for DELETE, got $code"; exit 1; fi

# 10. Change password
expect_status 200 -X PUT "$BASE/password" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -d '{"old_password":"password123","new_password":"newpassword456"}'

# 11. Logout
expect_status 200 -X POST "$BASE/logout" -b "$COOKIE_JAR"

# 12. Access after logout should be 401
expect_status 401 "$BASE/me" -b "$COOKIE_JAR"

# 13. Login with new password
curl -s -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword456"}' >/dev/null

# 14. Create and access different user to test 404 on foreign todo
curl -s -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password123"}' >/dev/null
curl -s -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password123"}' >/dev/null
# user2 should 404 on user1's todo id 1
expect_status 404 "$BASE/todos/1" -b "$COOKIE_JAR"

# 15. Invalid credentials on login
expect_status 401 -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"nope","password":"bad"}'

# 16. Title required on create
expect_status 400 -X POST "$BASE/todos" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -d '{"title":""}'

# 16b. Create a valid todo for user2 and capture id
resp=$(curl -s -X POST "$BASE/todos" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -d '{"title":"U2 Task"}')
echo "$resp" | grep '"title":"U2 Task"' >/dev/null
u2_id=$(echo "$resp" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
if [[ -z "$u2_id" ]]; then echo "Failed to parse todo id"; exit 1; fi

# 17. Title required on update if provided (for user2's own todo)
expect_status 400 -X PUT "$BASE/todos/$u2_id" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -d '{"title":""}'

# 18. Invalid updated field type for completed
expect_status 400 -X PUT "$BASE/todos/$u2_id" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -d '{"completed":"yes"}'

# 19. Ensure Content-Type on non-DELETE
ct=$(curl -s -D - "$BASE/me" -b "$COOKIE_JAR" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1}/^Content-Type:/{print $2}')
if [[ "$ct" != "application/json" ]]; then echo "Unexpected Content-Type: $ct"; exit 1; fi

# 20. DELETE nonexistent should return 404 with JSON body
status=$(curl -s -o /tmp/del_body.txt -w '%{http_code}' -X DELETE "$BASE/todos/999" -b "$COOKIE_JAR")
if [[ "$status" != "404" ]]; then echo "Expected 404 for missing DELETE, got $status"; exit 1; fi
ctype=$(curl -s -D - -o /dev/null -X DELETE "$BASE/todos/999" -b "$COOKIE_JAR" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1}/^Content-Type:/{print $2}')
if [[ "$ctype" != "application/json" ]]; then echo "Expected application/json content-type on error DELETE, got $ctype"; exit 1; fi

echo "All tests passed"
