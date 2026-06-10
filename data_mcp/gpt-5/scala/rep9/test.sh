#!/usr/bin/env bash
set -euo pipefail
PORT=$(( (RANDOM % 10000) + 20000 ))
SERVER_LOG=server.log
COOKIE1=cookies1.txt
COOKIE2=cookies2.txt
rm -f "$SERVER_LOG" "$COOKIE1" "$COOKIE2" headers.tmp body.tmp server.pid

# Start server on random port
(setsid ./run.sh --port "$PORT" >"$SERVER_LOG" 2>&1 & echo $! > server.pid) || true
sleep 1
# Wait for readiness (up to 60s)
for i in {1..120}; do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/me"; then
    break
  fi
  sleep 0.5
done

fail() { echo "TEST FAILED: $1"; echo "--- Server log ---"; tail -n +1 "$SERVER_LOG" || true; kill $(cat server.pid) 2>/dev/null || true; exit 1; }

check_status() {
  local expected=$1; shift
  local file=$1; shift
  local actual
  actual=$(awk 'toupper($0) ~ /^HTTP\// {print $2; exit}' "$file")
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected HTTP $expected, got $actual"; return 1; fi
}

check_json_ct() {
  local file=$1
  if ! awk 'BEGIN{IGNORECASE=1} /^Content-Type:/ {print tolower($0)}' "$file" | grep -q 'application/json'; then
    echo "Missing or wrong Content-Type"; return 1; fi
}

curl_json() {
  local method=$1; shift
  local path=$1; shift
  local cookiejar=$1; shift
  local data=${1-}
  if [[ -z "${data}" ]]; then
    curl -sS -D headers.tmp -b "$cookiejar" -c "$cookiejar" -X "$method" "http://127.0.0.1:$PORT$path" -H 'Content-Type: application/json' -o body.tmp || return 1
  else
    curl -sS -D headers.tmp -b "$cookiejar" -c "$cookiejar" -X "$method" "http://127.0.0.1:$PORT$path" -H 'Content-Type: application/json' --data "$data" -o body.tmp || return 1
  fi
}

# 1. Register invalid username
curl_json POST /register "$COOKIE1" '{"username":"ab","password":"12345678"}' || fail "curl register invalid"
check_status 400 headers.tmp || fail "register invalid status"
check_json_ct headers.tmp || fail "register invalid ct"

echo "Register valid user1"
curl_json POST /register "$COOKIE1" '{"username":"user_one","password":"password123"}' || fail "register user1"
check_status 201 headers.tmp || fail "register user1 status"
check_json_ct headers.tmp || fail "register user1 ct"

# duplicate
curl_json POST /register "$COOKIE1" '{"username":"user_one","password":"anotherpass"}' || fail "register duplicate"
check_status 409 headers.tmp || fail "register duplicate status"

# login wrong
curl_json POST /login "$COOKIE1" '{"username":"user_one","password":"wrongpass"}' || fail "login wrong"
check_status 401 headers.tmp || fail "login wrong status"
check_json_ct headers.tmp || fail "login wrong ct"

# login correct
curl_json POST /login "$COOKIE1" '{"username":"user_one","password":"password123"}' || fail "login user1"
check_status 200 headers.tmp || fail "login user1 status"
if ! grep -qi '^Set-Cookie: .*session_id=' headers.tmp; then fail "missing session cookie"; fi

# me
curl_json GET /me "$COOKIE1" || fail "me user1"
check_status 200 headers.tmp || fail "me user1 status"
check_json_ct headers.tmp || fail "me user1 ct"

# password wrong old
curl_json PUT /password "$COOKIE1" '{"old_password":"nope","new_password":"newpassword123"}' || fail "pwd wrong old"
check_status 401 headers.tmp || fail "pwd wrong old status"

# password too short
curl_json PUT /password "$COOKIE1" '{"old_password":"password123","new_password":"short"}' || fail "pwd short"
check_status 400 headers.tmp || fail "pwd short status"

# password change ok
curl_json PUT /password "$COOKIE1" '{"old_password":"password123","new_password":"newpassword123"}' || fail "pwd change ok"
check_status 200 headers.tmp || fail "pwd change ok status"

# logout
curl_json POST /logout "$COOKIE1" || fail "logout"
check_status 200 headers.tmp || fail "logout status"

# after logout me should 401
curl_json GET /me "$COOKIE1" || fail "me after logout"
check_status 401 headers.tmp || fail "me after logout status"

# login with new password
curl_json POST /login "$COOKIE1" '{"username":"user_one","password":"newpassword123"}' || fail "login new pwd"
check_status 200 headers.tmp || fail "login new pwd status"

# todos list empty
curl_json GET /todos "$COOKIE1" || fail "todos empty"
check_status 200 headers.tmp || fail "todos empty status"
check_json_ct headers.tmp || fail "todos empty ct"
if ! grep -q '^\[\]' body.tmp; then echo "Expected empty list"; fi

# create todo missing title
curl_json POST /todos "$COOKIE1" '{"description":"desc only"}' || fail "todo missing title"
check_status 400 headers.tmp || fail "todo missing title status"

# create todo ok
curl_json POST /todos "$COOKIE1" '{"title":"Task A","description":"first"}' || fail "todo create"
check_status 201 headers.tmp || fail "todo create status"
check_json_ct headers.tmp || fail "todo create ct"
TODO_ID=$(sed -n 's/.*"id"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p' body.tmp | head -n1)
if [[ -z "$TODO_ID" ]]; then fail "failed to parse todo id"; fi

# list todos
curl_json GET /todos "$COOKIE1" || fail "todos list"
check_status 200 headers.tmp || fail "todos list status"

# get todo by id
curl_json GET "/todos/$TODO_ID" "$COOKIE1" || fail "todo get by id"
check_status 200 headers.tmp || fail "todo get status"

# update with empty title
curl_json PUT "/todos/$TODO_ID" "$COOKIE1" '{"title":""}' || fail "todo empty title"
check_status 400 headers.tmp || fail "todo empty title status"

# partial update completed + description (check updated_at changed)
curl_json GET "/todos/$TODO_ID" "$COOKIE1" || fail "todo get for ts"
CREATED_AT=$(sed -n 's/.*"created_at"[ ]*:[ ]*"\([^"]\+\)".*/\1/p' body.tmp | head -n1)

curl_json PUT "/todos/$TODO_ID" "$COOKIE1" '{"completed":true, "description":"updated"}' || fail "todo update"
check_status 200 headers.tmp || fail "todo update status"
UPDATED_AT=$(sed -n 's/.*"updated_at"[ ]*:[ ]*"\([^"]\+\)".*/\1/p' body.tmp | head -n1)
if [[ "$UPDATED_AT" == "$CREATED_AT" ]]; then fail "updated_at did not change"; fi

# create second user and try to access first user's todo
curl_json POST /register "$COOKIE2" '{"username":"user_two","password":"passwordABC"}' || fail "register user2"
check_status 201 headers.tmp || fail "register user2 status"

curl_json POST /login "$COOKIE2" '{"username":"user_two","password":"passwordABC"}' || fail "login user2"
check_status 200 headers.tmp || fail "login user2 status"

curl_json GET "/todos/$TODO_ID" "$COOKIE2" || fail "user2 get other todo"
check_status 404 headers.tmp || fail "user2 get other todo status"

# delete todo
curl_json DELETE "/todos/$TODO_ID" "$COOKIE1" || fail "todo delete"
check_status 204 headers.tmp || fail "todo delete status"
if [[ -s body.tmp ]]; then fail "DELETE should have empty body"; fi

# get after delete -> 404
curl_json GET "/todos/$TODO_ID" "$COOKIE1" || fail "todo get after delete"
check_status 404 headers.tmp || fail "todo get after delete status"

# cleanup
kill $(cat server.pid) 2>/dev/null || true
rm -f headers.tmp body.tmp server.pid "$COOKIE1" "$COOKIE2"
echo "All tests passed on port $PORT"