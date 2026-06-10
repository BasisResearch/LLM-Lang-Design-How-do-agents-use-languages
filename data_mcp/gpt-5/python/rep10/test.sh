#!/usr/bin/env bash
set -euo pipefail
PORT=18080
ROOT=http://127.0.0.1:$PORT
JAR1=$(mktemp)
JAR2=$(mktemp)
HEADERS=$(mktemp)
BODY=$(mktemp)
cleanup() {
  [[ -n ${SERVER_PID:-} ]] && kill $SERVER_PID >/dev/null 2>&1 || true
  rm -f "$JAR1" "$JAR2" "$HEADERS" "$BODY"
}
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" &
SERVER_PID=$!
# Wait for server to be ready
for i in {1..50}; do
  sleep 0.1
  code=$(curl -s -o /dev/null -w '%{http_code}' "$ROOT/me") || true
  if [[ "$code" != "000" ]]; then break; fi
done

# Helper: request method path data cookiejar
req() {
  local method=$1; shift
  local path=$1; shift
  local data=${1:-}; shift || true
  local jar=$1; shift || true
  if [[ -n "$data" ]]; then
    code=$(curl -s -S -X "$method" -H 'Content-Type: application/json' -b "$jar" -c "$jar" -d "$data" -D "$HEADERS" -o "$BODY" -w '%{http_code}' "$ROOT$path")
  else
    code=$(curl -s -S -X "$method" -H 'Content-Type: application/json' -b "$jar" -c "$jar" -D "$HEADERS" -o "$BODY" -w '%{http_code}' "$ROOT$path")
  fi
  echo "$code"
}

expect_code() {
  local got=$1; local exp=$2; local msg=$3
  if [[ "$got" != "$exp" ]]; then
    echo "Expected $exp but got $got: $msg" >&2
    echo "Response body:" >&2; cat "$BODY" >&2
    echo "Headers:" >&2; cat "$HEADERS" >&2
    exit 1
  fi
}

# 1) Register user1
code=$(req POST /register '{"username":"alice_1","password":"password123"}' "$JAR1")
expect_code "$code" 201 "register user1"
python3 - "$BODY" <<'PY'
import sys,json
b=open(sys.argv[1],'rb').read()
j=json.loads(b)
assert j['id']==1 and j['username']=='alice_1'
PY

# 2) Duplicate register
code=$(req POST /register '{"username":"alice_1","password":"password123"}' "$JAR1")
expect_code "$code" 409 "duplicate register"

# 3) Login wrong password
code=$(req POST /login '{"username":"alice_1","password":"wrongpass"}' "$JAR1")
expect_code "$code" 401 "login wrong password"

# 4) Login correct
code=$(req POST /login '{"username":"alice_1","password":"password123"}' "$JAR1")
expect_code "$code" 200 "login correct"
python3 - "$BODY" <<'PY'
import sys,json
j=json.load(open(sys.argv[1]))
assert j['id']==1 and j['username']=='alice_1'
PY

# 5) GET /me
code=$(req GET /me '' "$JAR1")
expect_code "$code" 200 "/me"

# 6) Change password wrong old
code=$(req PUT /password '{"old_password":"bad","new_password":"newpassword"}' "$JAR1")
expect_code "$code" 401 "password wrong old"
# 6b) Change password too short
code=$(req PUT /password '{"old_password":"password123","new_password":"short"}' "$JAR1")
expect_code "$code" 400 "password too short"
# 6c) Change password correct
code=$(req PUT /password '{"old_password":"password123","new_password":"newpassword"}' "$JAR1")
expect_code "$code" 200 "password change ok"

# 7) Logout
code=$(req POST /logout '' "$JAR1")
expect_code "$code" 200 "logout"
# After logout, /me should be 401
code=$(req GET /me '' "$JAR1")
expect_code "$code" 401 "/me after logout should 401"

# 8) Login with new password
code=$(req POST /login '{"username":"alice_1","password":"newpassword"}' "$JAR1")
expect_code "$code" 200 "login new password"

# 9) GET /todos (empty)
code=$(req GET /todos '' "$JAR1")
expect_code "$code" 200 "get todos"
python3 - "$BODY" <<'PY'
import sys,json
arr=json.load(open(sys.argv[1]))
assert isinstance(arr,list) and arr==[]
PY

# 10) POST /todos missing title
code=$(req POST /todos '{"description":"X"}' "$JAR1")
expect_code "$code" 400 "missing title"

# 11) Create todo
code=$(req POST /todos '{"title":"Task1","description":"Desc"}' "$JAR1")
expect_code "$code" 201 "create todo"
python3 - "$BODY" <<'PY'
import sys,json
j=json.load(open(sys.argv[1]))
assert j['id']==1 and j['title']=='Task1' and j['description']=='Desc' and j['completed'] is False
PY

# 12) GET /todos/1
code=$(req GET /todos/1 '' "$JAR1")
expect_code "$code" 200 "get todo 1"

# 13) PUT /todos/1 update
code=$(req PUT /todos/1 '{"completed": true, "title":"Task1 updated"}' "$JAR1")
expect_code "$code" 200 "update todo 1"
python3 - "$BODY" <<'PY'
import sys,json
j=json.load(open(sys.argv[1]))
assert j['title']=='Task1 updated' and j['completed'] is True
PY

# 14) GET /todos
code=$(req GET /todos '' "$JAR1")
expect_code "$code" 200 "list todos"

# 15) DELETE /todos/1
code=$(req DELETE /todos/1 '' "$JAR1")
expect_code "$code" 204 "delete todo 1"
# Ensure no body
if [[ -s "$BODY" ]]; then echo "Expected empty body for 204"; exit 1; fi

# 16) GET /todos/1 should 404
code=$(req GET /todos/1 '' "$JAR1")
expect_code "$code" 404 "get deleted todo should 404"

# 17) Cross-user visibility check
# Register user2 and create a todo
code=$(req POST /register '{"username":"bob_2","password":"bobpassword"}' "$JAR2")
expect_code "$code" 201 "register user2"
code=$(req POST /login '{"username":"bob_2","password":"bobpassword"}' "$JAR2")
expect_code "$code" 200 "login user2"
code=$(req POST /todos '{"title":"Bob Task","description":"bd"}' "$JAR2")
expect_code "$code" 201 "create user2 todo"
BOB_TODO_ID=$(python3 - "$BODY" <<'PY'
import sys,json
print(json.load(open(sys.argv[1]))['id'])
PY
)

# Try to access Bob's todo with Alice's session
code=$(req GET /todos/$BOB_TODO_ID '' "$JAR1")
expect_code "$code" 404 "cross-user get should 404"

# Try to update Bob's todo with Alice's session
code=$(req PUT /todos/$BOB_TODO_ID '{"title":"hacked"}' "$JAR1")
expect_code "$code" 404 "cross-user update should 404"

# Try to delete Bob's todo with Alice's session
code=$(req DELETE /todos/$BOB_TODO_ID '' "$JAR1")
expect_code "$code" 404 "cross-user delete should 404"

echo "All tests passed."
