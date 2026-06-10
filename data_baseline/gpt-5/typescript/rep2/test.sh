#!/usr/bin/env bash
set -euo pipefail
PORT=3456
SERVER_LOG=server_test.log
COOKIE_JAR=cookies.txt
rm -f "$SERVER_LOG" "$COOKIE_JAR"
./run.sh --port "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
cleanup() { kill $SERVER_PID || true; rm -f "$COOKIE_JAR"; }
trap cleanup EXIT
sleep 1
base="http://127.0.0.1:$PORT"
# Helper to check status code
req() {
  method="$1"; url="$2"; shift 2
  curl -sS -D /tmp/headers.txt -b "$COOKIE_JAR" -c "$COOKIE_JAR" -o /tmp/body.json -w "%{http_code}" \
    -H 'Content-Type: application/json' -X "$method" "$url" "$@"
}
expect() {
  got="$1"; want="$2"; msg="$3"; if [[ "$got" != "$want" ]]; then
    echo "Expected $want got $got: $msg"; echo "Body:"; cat /tmp/body.json; echo; exit 1; fi }
get_json_field() { node -e "const fs=require('fs'); const d=fs.readFileSync('/tmp/body.json','utf8'); const o=JSON.parse(d); console.log(o[process.argv[1]]??'');" "$1"; }

# Unique users
AUSER="alice_$RANDOM$RANDOM"
BUSER="bob_$RANDOM$RANDOM"
APASS="password123"
ANEWPASS="betterpass"
BPASS="password123"

# Register
code=$(req POST "$base/register" --data "{\"username\":\"$AUSER\",\"password\":\"$APASS\"}")
expect "$code" 201 "register alice"

# Duplicate register
code=$(req POST "$base/register" --data "{\"username\":\"$AUSER\",\"password\":\"$APASS\"}")
expect "$code" 409 "duplicate register"

# Login wrong
code=$(req POST "$base/login" --data "{\"username\":\"$AUSER\",\"password\":\"wrong\"}")
expect "$code" 401 "bad login"

# Login ok
code=$(req POST "$base/login" --data "{\"username\":\"$AUSER\",\"password\":\"$APASS\"}")
expect "$code" 200 "login ok"

# /me
code=$(req GET "$base/me")
expect "$code" 200 "/me"

# change password wrong old
code=$(req PUT "$base/password" --data '{"old_password":"bad","new_password":"newpassword"}')
expect "$code" 401 "password wrong old"
# change password short new
code=$(req PUT "$base/password" --data '{"old_password":"password123","new_password":"short"}')
expect "$code" 400 "password too short"
# change password ok
code=$(req PUT "$base/password" --data "{\"old_password\":\"$APASS\",\"new_password\":\"$ANEWPASS\"}")
expect "$code" 200 "password changed"

# create todo missing title
code=$(req POST "$base/todos" --data '{"description":"desc"}')
expect "$code" 400 "missing title"
# create todo ok
code=$(req POST "$base/todos" --data '{"title":"Task 1","description":"Do it"}')
expect "$code" 201 "create todo 1"
T1=$(get_json_field id)
code=$(req POST "$base/todos" --data '{"title":"Task 2"}')
expect "$code" 201 "create todo 2"
T2=$(get_json_field id)

# list
code=$(req GET "$base/todos")
expect "$code" 200 "list todos"

# get specific
code=$(req GET "$base/todos/$T1")
expect "$code" 200 "get todo 1"
# update empty title -> 400
code=$(req PUT "$base/todos/$T1" --data '{"title":""}')
expect "$code" 400 "empty title"
# update set completed and change title
code=$(req PUT "$base/todos/$T1" --data '{"title":"Task 1 updated","completed":true}')
expect "$code" 200 "update todo 1"

# register bob
code=$(req POST "$base/register" --data "{\"username\":\"$BUSER\",\"password\":\"$BPASS\"}")
expect "$code" 201 "register bob"
# login bob
code=$(req POST "$base/login" --data "{\"username\":\"$BUSER\",\"password\":\"$BPASS\"}")
expect "$code" 200 "login bob"
# bob tries to get alice todo 1 -> 404
code=$(req GET "$base/todos/$T1")
expect "$code" 404 "bob cannot see alice todo"
# bob creates todo
code=$(req POST "$base/todos" --data '{"title":"Bob Task"}')
expect "$code" 201 "bob create todo"
TB=$(get_json_field id)
# alice login again with new password
code=$(req POST "$base/login" --data "{\"username\":\"$AUSER\",\"password\":\"$ANEWPASS\"}")
expect "$code" 200 "alice relogin"
# delete alice todo 1
code=$(req DELETE "$base/todos/$T1")
expect "$code" 204 "delete todo 1"
# get deleted -> 404
code=$(req GET "$base/todos/$T1")
expect "$code" 404 "get deleted"
# logout
code=$(req POST "$base/logout")
expect "$code" 200 "logout ok"
# after logout, access should be 401
code=$(req GET "$base/me")
expect "$code" 401 "after logout should be 401"

echo "All tests passed"
