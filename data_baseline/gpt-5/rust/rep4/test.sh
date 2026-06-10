#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-8082}
ROOT_DIR=$(pwd)
LOG=server.log
COOKIE1=cookie1.txt
COOKIE2=cookie2.txt
rm -f "$LOG" "$COOKIE1" "$COOKIE2"

# Start server
./run.sh --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!
sleep 1

echo "Server PID: $SERVER_PID"

base() { echo "http://127.0.0.1:$PORT"; }

expect_code() {
  local got=$1 exp=$2 msg=$3
  if [[ "$got" != "$exp" ]]; then
    echo "FAIL: $msg (expected $exp got $got)" >&2
    echo "Last body:" >&2
    test -f body.json && sed -n '1,200p' body.json >&2 || true
    kill $SERVER_PID || true
    exit 1
  fi
}

# Helper to curl with headers and body capture
call() {
  local method=$1 url=$2 data=${3-} cookiejar=${4-}
  if [[ -n ${data} ]]; then
    resp=$(curl -s -D headers.txt -o body.json -w "%{http_code}" -X "$method" -H 'Content-Type: application/json' ${cookiejar:+-b "$cookiejar" -c "$cookiejar"} --data "$data" "$url")
  else
    resp=$(curl -s -D headers.txt -o body.json -w "%{http_code}" -X "$method" ${cookiejar:+-b "$cookiejar" -c "$cookiejar"} "$url")
  fi
  echo -n "$resp"
}

# 1) Register
code=$(call POST "$(base)/register" '{"username":"alice_1","password":"supersecret"}')
expect_code "$code" 201 "register"

# Duplicate username
code=$(call POST "$(base)/register" '{"username":"alice_1","password":"anotherpass"}')
expect_code "$code" 409 "duplicate username"

# Invalid username
code=$(call POST "$(base)/register" '{"username":"a!","password":"supersecret"}')
expect_code "$code" 400 "invalid username"

# Short password
code=$(call POST "$(base)/register" '{"username":"bob_1","password":"short"}')
expect_code "$code" 400 "short password"

# 2) Login bad
code=$(call POST "$(base)/login" '{"username":"alice_1","password":"wrongpass"}' "$COOKIE1")
expect_code "$code" 401 "login bad"

# 3) Login good
code=$(call POST "$(base)/login" '{"username":"alice_1","password":"supersecret"}' "$COOKIE1")
expect_code "$code" 200 "login good"
# Check Set-Cookie present
grep -qi '^Set-Cookie: session_id=' headers.txt || { echo "FAIL: missing Set-Cookie"; kill $SERVER_PID; exit 1; }

# 4) /me
code=$(call GET "$(base)/me" '' "$COOKIE1")
expect_code "$code" 200 "/me with auth"

# 5) todos list empty
code=$(call GET "$(base)/todos" '' "$COOKIE1")
expect_code "$code" 200 "list todos"
if ! grep -q '^\[\]$' body.json; then echo "FAIL: expected empty array"; kill $SERVER_PID; exit 1; fi

# 6) create todo without title -> 400
code=$(call POST "$(base)/todos" '{"description":"desc only"}' "$COOKIE1")
expect_code "$code" 400 "create todo missing title"

# 7) create todo ok
code=$(call POST "$(base)/todos" '{"title":"Task 1","description":"Do it"}' "$COOKIE1")
expect_code "$code" 201 "create todo ok"
ID1=$(jq -r '.id' body.json 2>/dev/null || sed -n 's/.*"id":\s*\([0-9][0-9]*\).*/\1/p' body.json)

# 8) get todo
code=$(call GET "$(base)/todos/$ID1" '' "$COOKIE1")
expect_code "$code" 200 "get todo"

# 9) update todo partial
code=$(call PUT "$(base)/todos/$ID1" '{"completed":true}' "$COOKIE1")
expect_code "$code" 200 "update todo"

# 10) update with empty title -> 400
code=$(call PUT "$(base)/todos/$ID1" '{"title":""}' "$COOKIE1")
expect_code "$code" 400 "update empty title"

# 11) list todos non-empty
code=$(call GET "$(base)/todos" '' "$COOKIE1")
expect_code "$code" 200 "list todos non-empty"

# 12) unauthorized /me without cookie
code=$(call GET "$(base)/me")
expect_code "$code" 401 "/me without auth"

# 13) second user creates todo, first user's todo should be hidden
code=$(call POST "$(base)/register" '{"username":"charlie_1","password":"sufficient"}')
expect_code "$code" 201 "register charlie"
code=$(call POST "$(base)/login" '{"username":"charlie_1","password":"sufficient"}' "$COOKIE2")
expect_code "$code" 200 "login charlie"
code=$(call GET "$(base)/todos/$ID1" '' "$COOKIE2")
expect_code "$code" 404 "charlie cannot get alice todo"

# 14) logout
code=$(call POST "$(base)/logout" '' "$COOKIE1")
expect_code "$code" 200 "logout"
code=$(call GET "$(base)/me" '' "$COOKIE1")
expect_code "$code" 401 "me after logout"

# 15) password change
# Need to login again to change password
code=$(call POST "$(base)/login" '{"username":"alice_1","password":"supersecret"}' "$COOKIE1")
expect_code "$code" 200 "login again"
code=$(call PUT "$(base)/password" '{"old_password":"wrong","new_password":"newpassword"}' "$COOKIE1")
expect_code "$code" 401 "wrong old password"
code=$(call PUT "$(base)/password" '{"old_password":"supersecret","new_password":"short"}' "$COOKIE1")
expect_code "$code" 400 "new password too short"
code=$(call PUT "$(base)/password" '{"old_password":"supersecret","new_password":"newpassword"}' "$COOKIE1")
expect_code "$code" 200 "password changed"

# 16) verify old password fails, new works
code=$(call POST "$(base)/login" '{"username":"alice_1","password":"supersecret"}' "$COOKIE1")
expect_code "$code" 401 "old password should fail"
code=$(call POST "$(base)/login" '{"username":"alice_1","password":"newpassword"}' "$COOKIE1")
expect_code "$code" 200 "new password works"

# 17) delete todo
# re-login as alice to ensure cookie is valid
code=$(call POST "$(base)/login" '{"username":"alice_1","password":"newpassword"}' "$COOKIE1")
expect_code "$code" 200 "login before delete"
code=$(call DELETE "$(base)/todos/$ID1" '' "$COOKIE1")
expect_code "$code" 204 "delete todo"
# check no Content-Type for delete response (server may omit); ensure empty body
if [[ -s body.json ]]; then echo "FAIL: expected empty body on DELETE"; kill $SERVER_PID; exit 1; fi

# 18) get after delete -> 404
code=$(call GET "$(base)/todos/$ID1" '' "$COOKIE1")
expect_code "$code" 404 "get after delete"

# All good
kill $SERVER_PID || true
wait $SERVER_PID 2>/dev/null || true

echo "All tests passed"
