#!/usr/bin/env bash
set -euo pipefail
PORT=18080
if [[ $# -ge 2 && $1 == "--port" ]]; then
  PORT=$2
fi
ROOT=$(pwd)
COOKIE_JAR=$(mktemp)
COOKIE_JAR2=$(mktemp)
cleanup() {
  rm -f "$COOKIE_JAR" "$COOKIE_JAR2"
  if [[ -n ${SERVER_PID:-} ]]; then kill $SERVER_PID || true; fi
}
trap cleanup EXIT

./run.sh --port "$PORT" &
SERVER_PID=$!
# wait for server
for i in {1..50}; do
  if curl -s "http://127.0.0.1:$PORT/doesnotexist" >/dev/null; then break; fi
  sleep 0.1
  if ! kill -0 $SERVER_PID 2>/dev/null; then echo "server exited"; exit 1; fi
  done

base="http://127.0.0.1:$PORT"

req() {
  local method=$1; shift
  local path=$1; shift
  local data=${1:-}
  if [[ -n "$data" ]]; then
    resp=$(curl -s -w "\n%{http_code}" -X "$method" -H 'Content-Type: application/json' -d "$data" -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$base$path")
  else
    resp=$(curl -s -w "\n%{http_code}" -X "$method" -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$base$path")
  fi
  body=$(echo "$resp" | head -n -1)
  code=$(echo "$resp" | tail -n1)
  echo "$code" "$body"
}

req2() {
  local method=$1; shift
  local path=$1; shift
  local data=${1:-}
  if [[ -n "$data" ]]; then
    resp=$(curl -s -w "\n%{http_code}" -X "$method" -H 'Content-Type: application/json' -d "$data" -c "$COOKIE_JAR2" -b "$COOKIE_JAR2" "$base$path")
  else
    resp=$(curl -s -w "\n%{http_code}" -X "$method" -c "$COOKIE_JAR2" -b "$COOKIE_JAR2" "$base$path")
  fi
  body=$(echo "$resp" | head -n -1)
  code=$(echo "$resp" | tail -n1)
  echo "$code" "$body"
}

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; echo "Response: $2"; exit 1; }

# Register
read code body < <(req POST /register '{"username":"alice_1","password":"password123"}')
[[ "$code" == 201 ]] || fail "register" "$code $body"; pass "register"

# Duplicate register
read code body < <(req POST /register '{"username":"alice_1","password":"password123"}')
[[ "$code" == 409 ]] || fail "duplicate register" "$code $body"; pass "duplicate register"

# Login wrong
read code body < <(req POST /login '{"username":"alice_1","password":"wrongpass"}')
[[ "$code" == 401 ]] || fail "login wrong" "$code $body"; pass "login wrong"

# Login correct
read code body < <(req POST /login '{"username":"alice_1","password":"password123"}')
[[ "$code" == 200 ]] || fail "login" "$code $body"; pass "login"

# Me
read code body < <(req GET /me)
[[ "$code" == 200 ]] || fail "me" "$code $body"; pass "me"

# Change password wrong old
read code body < <(req PUT /password '{"old_password":"bad","new_password":"newpassword123"}')
[[ "$code" == 401 ]] || fail "password wrong old" "$code $body"; pass "password wrong old"

# Change password too short
read code body < <(req PUT /password '{"old_password":"password123","new_password":"short"}')
[[ "$code" == 400 ]] || fail "password too short" "$code $body"; pass "password too short"

# Change password ok
read code body < <(req PUT /password '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == 200 ]] || fail "password change" "$code $body"; pass "password change"

# Logout
read code body < <(req POST /logout)
[[ "$code" == 200 ]] || fail "logout" "$code $body"; pass "logout"

# Me after logout should 401
read code body < <(req GET /me)
[[ "$code" == 401 ]] || fail "me after logout" "$code $body"; pass "me after logout"

# Login with old password should fail
read code body < <(req POST /login '{"username":"alice_1","password":"password123"}')
[[ "$code" == 401 ]] || fail "login with old pw" "$code $body"; pass "login with old pw"

# Login with new password
read code body < <(req POST /login '{"username":"alice_1","password":"newpassword123"}')
[[ "$code" == 200 ]] || fail "login new pw" "$code $body"; pass "login new pw"

# List todos empty
read code body < <(req GET /todos)
[[ "$code" == 200 && "$body" == "[]" ]] || fail "list empty" "$code $body"; pass "list empty"

# Create todo missing title
read code body < <(req POST /todos '{"description":"desc"}')
[[ "$code" == 400 ]] || fail "create missing title" "$code $body"; pass "create missing title"

# Create todo ok
read code body < <(req POST /todos '{"title":"Task1","description":"First"}')
[[ "$code" == 201 ]] || fail "create todo" "$code $body"; pass "create todo"
# Extract id via regex (assumes id is first field)
TID=$(echo "$body" | sed -n 's/.*"id":[ ]*\([0-9][0-9]*\).*/\1/p')
[[ -n "$TID" ]] || fail "extract todo id" "$body"

# Get todo by id
read code body < <(req GET "/todos/$TID")
[[ "$code" == 200 ]] || fail "get todo" "$code $body"; pass "get todo"

# Update todo empty title should 400
read code body < <(req PUT "/todos/$TID" '{"title":""}')
[[ "$code" == 400 ]] || fail "update empty title" "$code $body"; pass "update empty title"

# Partial update description
read code body < <(req PUT "/todos/$TID" '{"description":"Updated"}')
[[ "$code" == 200 ]] || fail "partial update" "$code $body"; pass "partial update"

# Complete todo
read code body < <(req PUT "/todos/$TID" '{"completed":true}')
[[ "$code" == 200 ]] || fail "complete todo" "$code $body"; pass "complete todo"

# Create second user and try to access first user's todo -> 404
read code body < <(req2 POST /register '{"username":"bob_2","password":"password123"}')
[[ "$code" == 201 ]] || fail "register bob" "$code $body"; pass "register bob"
read code body < <(req2 POST /login '{"username":"bob_2","password":"password123"}')
[[ "$code" == 200 ]] || fail "login bob" "$code $body"; pass "login bob"
read code body < <(req2 GET "/todos/$TID")
[[ "$code" == 404 ]] || fail "bob cannot see alice todo" "$code $body"; pass "bob cannot see alice todo"

# Delete todo
read code body < <(req DELETE "/todos/$TID")
[[ "$code" == 204 ]] || fail "delete todo" "$code $body"; pass "delete todo"

# Get deleted todo -> 404
read code body < <(req GET "/todos/$TID")
[[ "$code" == 404 ]] || fail "get deleted todo" "$code $body"; pass "get deleted todo"

# List todos -> []
read code body < <(req GET /todos)
[[ "$code" == 200 && "$body" == "[]" ]] || fail "list after delete" "$code $body"; pass "list after delete"

echo "All tests passed"
