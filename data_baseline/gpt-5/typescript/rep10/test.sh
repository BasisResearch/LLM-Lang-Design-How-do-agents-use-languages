#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-4567}
ROOT_DIR=$(pwd)

./run.sh --port "$PORT" >/tmp/test_server.log 2>&1 &
SRV_PID=$!
cleanup() {
  kill $SRV_PID >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for server to be ready
for i in {1..60}; do
  if curl -sS -o /dev/null -H 'Content-Type: application/json' "http://127.0.0.1:$PORT/me"; then
    break
  fi
  sleep 0.5
  if [[ $i -eq 60 ]]; then echo "Server did not start in time"; exit 1; fi
done

base() { echo "http://127.0.0.1:$PORT"; }

# Helpers
http() {
  local method=$1; shift
  local path=$1; shift
  local opts=("-sS" "-X" "$method" "$(base)$path" "-H" "Content-Type: application/json" "$@")
  curl "${opts[@]}"
}

http_capture() {
  local method=$1; shift
  local path=$1; shift
  local extra=("$@")
  rm -f /tmp/headers.txt /tmp/body.txt || true
  http "$method" "$path" "${extra[@]}" -D /tmp/headers.txt -o /tmp/body.txt -w "%{http_code}" > /tmp/code.txt
}

expect_code() {
  local expected=$1
  local code=$(cat /tmp/code.txt)
  if [[ "$code" != "$expected" ]]; then
    echo "Expected HTTP $expected but got $code"
    echo "Headers:"; cat /tmp/headers.txt || true
    echo "Body:"; cat /tmp/body.txt || true
    exit 1
  fi
}

expect_json_content_type() {
  if ! grep -i "^Content-Type: application/json" /tmp/headers.txt >/dev/null; then
    echo "Missing or wrong Content-Type"; cat /tmp/headers.txt; exit 1
  fi
}

# Begin tests
# 1. /me without auth
http_capture GET /me
expect_code 401
expect_json_content_type

# 2. register validations
http_capture POST /register --data '{"username":"ab","password":"password123"}'
expect_code 400
expect_json_content_type

http_capture POST /register --data '{"username":"good_user","password":"short"}'
expect_code 400

# 3. register ok
http_capture POST /register --data '{"username":"good_user","password":"password123"}'
expect_code 201

# 4. duplicate
http_capture POST /register --data '{"username":"good_user","password":"password123"}'
expect_code 409

# 5. login invalid
http_capture POST /login --data '{"username":"good_user","password":"wrong"}'
expect_code 401

# 6. login ok
COOKIE_JAR1=$(mktemp)
http_capture POST /login --data '{"username":"good_user","password":"password123"}' -c "$COOKIE_JAR1"
expect_code 200
expect_json_content_type
if ! grep -i "^Set-Cookie: session_id=" /tmp/headers.txt >/dev/null; then echo "Missing Set-Cookie"; cat /tmp/headers.txt; exit 1; fi

# 7. me ok
http_capture GET /me -b "$COOKIE_JAR1"
expect_code 200

# 8. password change invalid old
http_capture PUT /password -b "$COOKIE_JAR1" --data '{"old_password":"nope","new_password":"newpassword123"}'
expect_code 401

# 9. password change too short
http_capture PUT /password -b "$COOKIE_JAR1" --data '{"old_password":"password123","new_password":"short"}'
expect_code 400

# 10. password change ok
http_capture PUT /password -b "$COOKIE_JAR1" --data '{"old_password":"password123","new_password":"newpassword123"}'
expect_code 200

# 11. logout
http_capture POST /logout -b "$COOKIE_JAR1"
expect_code 200

# 12. subsequent auth should fail
http_capture GET /me -b "$COOKIE_JAR1"
expect_code 401

# 13. login again with new password
COOKIE_JAR1=$(mktemp)
http_capture POST /login --data '{"username":"good_user","password":"newpassword123"}' -c "$COOKIE_JAR1"
expect_code 200

# 14. create todo validations
http_capture POST /todos -b "$COOKIE_JAR1" --data '{"title":"","description":"test"}'
expect_code 400

# 15. create todo ok
http_capture POST /todos -b "$COOKIE_JAR1" --data '{"title":"Task 1","description":"First"}'
expect_code 201

# Extract todo id
TODO_ID=$(node -e 'const fs=require("fs"); const o=JSON.parse(fs.readFileSync("/tmp/body.txt","utf8")); console.log(o.id)')

# 16. list todos
http_capture GET /todos -b "$COOKIE_JAR1"
expect_code 200

# 17. get todo by id
http_capture GET /todos/$TODO_ID -b "$COOKIE_JAR1"
expect_code 200

# 18. update todo partial
http_capture PUT /todos/$TODO_ID -b "$COOKIE_JAR1" --data '{"completed": true, "title":"Task 1 updated"}'
expect_code 200

# 19. delete todo
http_capture DELETE /todos/$TODO_ID -b "$COOKIE_JAR1"
expect_code 204
if grep -i "^Content-Type:" /tmp/headers.txt >/dev/null; then echo "DELETE should not include Content-Type body"; cat /tmp/headers.txt; exit 1; fi
if [[ -s /tmp/body.txt ]]; then echo "DELETE should have no body"; cat /tmp/body.txt; exit 1; fi

# 20. get deleted -> 404
http_capture GET /todos/$TODO_ID -b "$COOKIE_JAR1"
expect_code 404

# 21. cross-user access returns 404
# Create user2 and todo
http_capture POST /register --data '{"username":"user2","password":"password123"}'
expect_code 201
COOKIE_JAR2=$(mktemp)
http_capture POST /login --data '{"username":"user2","password":"password123"}' -c "$COOKIE_JAR2"
expect_code 200
http_capture POST /todos -b "$COOKIE_JAR2" --data '{"title":"User2 Task","description":"X"}'
expect_code 201
TODO2_ID=$(node -e 'const fs=require("fs"); const o=JSON.parse(fs.readFileSync("/tmp/body.txt","utf8")); console.log(o.id)')
# Try to access as user1
http_capture GET /todos/$TODO2_ID -b "$COOKIE_JAR1"
expect_code 404

# All good
echo "All tests passed"
