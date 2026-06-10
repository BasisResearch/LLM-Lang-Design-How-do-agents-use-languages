#!/usr/bin/env bash
set -euo pipefail
PORT=$((15000 + RANDOM % 10000))
COOKIE_JAR=./cookies.txt
COOKIE_JAR2=./cookies2.txt
rm -f "$COOKIE_JAR" "$COOKIE_JAR2" server.log headers.tmp body.tmp

./run.sh --port "$PORT" >server.log 2>&1 &
PID=$!
cleanup(){
  kill $PID 2>/dev/null || true
}
trap cleanup EXIT

# wait for server
for i in {1..50}; do
  if curl -s "http://127.0.0.1:$PORT/" -o /dev/null; then break; fi
  sleep 0.1
done

base() { echo "http://127.0.0.1:$PORT$1"; }

check_status(){
  local expected=$1; shift
  local url=$1; shift
  local curl_args=("$@")
  local code
  code=$(curl -sS -o body.tmp -w "%{http_code}" -D headers.tmp "${curl_args[@]}" "$url")
  if [[ "$code" != "$expected" ]]; then
    echo "FAIL: $url expected $expected got $code" >&2
    echo "--- Response body ---" >&2
    cat body.tmp >&2
    echo "--- Headers ---" >&2
    cat headers.tmp >&2
    exit 1
  fi
  # content-type must be application/json for non-204
  if [[ "$expected" != "204" ]]; then
    if ! grep -iq '^Content-Type: application/json' headers.tmp; then
      echo "FAIL: Missing or wrong Content-Type for $url" >&2
      cat headers.tmp >&2
      exit 1
    fi
  fi
}

expect_body_contains(){
  local needle=$1
  if ! grep -q "$needle" body.tmp; then
    echo "FAIL: Body does not contain: $needle" >&2
    cat body.tmp >&2
    exit 1
  fi
}

# 1) Register validations
check_status 400 "$(base /register)" -H 'Content-Type: application/json' -d '{"username":"ab","password":"password123"}' -X POST
expect_body_contains 'Invalid username'
check_status 400 "$(base /register)" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"short"}' -X POST
expect_body_contains 'Password too short'
check_status 201 "$(base /register)" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' -X POST
expect_body_contains '"id"'
expect_body_contains '"username":"user_one"'
check_status 409 "$(base /register)" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"anotherpass"}' -X POST
expect_body_contains 'Username already exists'

# 2) Login
check_status 401 "$(base /login)" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"wrongpass"}' -X POST
expect_body_contains 'Invalid credentials'
# correct login, store cookie
curl -sS -o body.tmp -D headers.tmp -c "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' -X POST "$(base /login)" > /dev/null
if ! grep -qi '^Set-Cookie: session_id=' headers.tmp; then echo 'FAIL: missing Set-Cookie on login' >&2; exit 1; fi
if ! grep -q '"username":"user_one"' body.tmp; then echo 'FAIL: login body' >&2; exit 1; fi

# 3) /me
check_status 200 "$(base /me)" -b "$COOKIE_JAR" -X GET
expect_body_contains '"username":"user_one"'

# 4) password change
check_status 401 "$(base /password)" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"nope","new_password":"newpassword1"}' -X PUT
check_status 400 "$(base /password)" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' -X PUT
check_status 200 "$(base /password)" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword1"}' -X PUT

# old password should fail
check_status 401 "$(base /login)" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' -X POST
# login with new password for fresh cookie
curl -sS -o /dev/null -D headers.tmp -c "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpassword1"}' -X POST "$(base /login)"

# 5) todos
check_status 200 "$(base /todos)" -b "$COOKIE_JAR" -X GET
expect_body_contains '\[\]'
check_status 400 "$(base /todos)" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"description":"desc only"}' -X POST
expect_body_contains 'Title is required'
check_status 201 "$(base /todos)" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task 1"}' -X POST
expect_body_contains '"id"'
expect_body_contains '"title":"Task 1"'
expect_body_contains '"completed":false'

check_status 200 "$(base /todos)" -b "$COOKIE_JAR" -X GET
expect_body_contains '"title":"Task 1"'

# get by id
check_status 200 "$(base /todos/1)" -b "$COOKIE_JAR" -X GET
expect_body_contains '"id":1'

# update partial
check_status 200 "$(base /todos/1)" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"completed":true}' -X PUT
expect_body_contains '"completed":true'
# invalid title empty
check_status 400 "$(base /todos/1)" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":""}' -X PUT
expect_body_contains 'Title is required'

# second user cannot see first user's todo
check_status 201 "$(base /register)" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"passwordXYZ"}' -X POST
curl -sS -o /dev/null -c "$COOKIE_JAR2" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"passwordXYZ"}' -X POST "$(base /login)"
check_status 404 "$(base /todos/1)" -b "$COOKIE_JAR2" -X GET

# create todo for user2
check_status 201 "$(base /todos)" -b "$COOKIE_JAR2" -H 'Content-Type: application/json' -d '{"title":"U2 Task"}' -X POST
# user1 should get 404 for user2's todo (id could be 2)
check_status 404 "$(base /todos/2)" -b "$COOKIE_JAR" -X GET || true

# delete todo 1 for user1
check_status 204 "$(base /todos/1)" -b "$COOKIE_JAR" -X DELETE
# verify 404 after delete
check_status 404 "$(base /todos/1)" -b "$COOKIE_JAR" -X GET

# logout invalidates session
check_status 200 "$(base /logout)" -b "$COOKIE_JAR" -X POST
check_status 401 "$(base /me)" -b "$COOKIE_JAR" -X GET

echo "All tests passed"
