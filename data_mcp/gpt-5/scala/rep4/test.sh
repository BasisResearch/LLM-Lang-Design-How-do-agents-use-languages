#!/usr/bin/env bash
set -euo pipefail

PORT=$(( 20000 + (RANDOM % 10000) ))

# kill any server already on PORT
pids=$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {print $7}' | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | sort -u || true)
if [[ -n "${pids:-}" ]]; then
  echo "Killing existing server(s) on port $PORT: $pids" >&2
  kill $pids 2>/dev/null || true
  sleep 1
fi

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

./run.sh --port "$PORT" >/tmp/server.log 2>&1 &
SERVER_PID=$!

echo "Waiting for server to start on port $PORT..."
for i in {1..60}; do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/me || true)
  if [[ "$code" == "401" ]]; then
    break
  fi
  sleep 1
done

base="http://127.0.0.1:$PORT"

request() {
  local method=$1
  local path=$2
  shift 2
  local extra=("$@")
  local headers=$(mktemp)
  local body=$(mktemp)
  local code
  code=$(curl -sS -X "$method" "$base$path" -D "$headers" -o "$body" -w "%{http_code}" "${extra[@]}" || true)
  echo "$headers" "$body" "$code"
}

assert_code() {
  local code=$1 expected=$2 msg=$3
  if [[ "$code" != "$expected" ]]; then
    echo "ASSERT CODE FAILED: expected $expected, got $code - $msg" >&2
    exit 1
  fi
}

assert_json_ct() {
  local headers_file=$1
  if ! grep -qi "^Content-Type: application/json" "$headers_file"; then
    echo "ASSERT HEADER FAILED: Content-Type application/json missing" >&2
    echo "Headers:"; cat "$headers_file" >&2
    exit 1
  fi
}

assert_body_contains() {
  local body_file=$1 substr=$2
  if ! grep -q "$substr" "$body_file"; then
    echo "ASSERT BODY FAILED: missing substring '$substr'" >&2
    echo "Body:"; cat "$body_file" >&2
    exit 1
  fi
}

# 1) Register
read H B C < <(request POST /register -H 'Content-Type: application/json' -d '{"username":"test_user","password":"password123"}')
assert_code "$C" 201 "register should return 201"
assert_json_ct "$H"
assert_body_contains "$B" '"username":"test_user"'

# 1b) Duplicate register
read H B C < <(request POST /register -H 'Content-Type: application/json' -d '{"username":"test_user","password":"password123"}')
assert_code "$C" 409 "duplicate register should return 409"
assert_json_ct "$H"

# 2) Invalid login
read H B C < <(request POST /login -H 'Content-Type: application/json' -d '{"username":"test_user","password":"wrong"}')
assert_code "$C" 401 "invalid login should be 401"
assert_json_ct "$H"

# 3) Valid login with cookie jar
COOKIE1=$(mktemp)
read H B C < <(request POST /login -H 'Content-Type: application/json' -d '{"username":"test_user","password":"password123"}' -c "$COOKIE1")
assert_code "$C" 200 "valid login should be 200"
assert_json_ct "$H"
if ! grep -qi '^Set-Cookie: session_id=' "$H"; then
  echo "Missing Set-Cookie session_id" >&2
  exit 1
fi

# 4) GET /me
read H B C < <(request GET /me -b "$COOKIE1")
assert_code "$C" 200 "/me should be 200"
assert_json_ct "$H"
assert_body_contains "$B" '"username":"test_user"'

# 5) Password change wrong old
read H B C < <(request PUT /password -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword123"}' -b "$COOKIE1")
assert_code "$C" 401 "password change with wrong old should be 401"
assert_json_ct "$H"

# 6) Password change correct
read H B C < <(request PUT /password -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}' -b "$COOKIE1")
assert_code "$C" 200 "password change should be 200"
assert_json_ct "$H"

# 7) Todos unauthenticated should be 401
read H B C < <(request GET /todos)
assert_code "$C" 401 "unauth todos should be 401"
assert_json_ct "$H"

# 8) Create todo with missing title
read H B C < <(request POST /todos -H 'Content-Type: application/json' -d '{"description":"x"}' -b "$COOKIE1")
assert_code "$C" 400 "missing title should be 400"
assert_json_ct "$H"

# 9) Create two todos
read H1 B1 C1 < <(request POST /todos -H 'Content-Type: application/json' -d '{"title":"First","description":"A"}' -b "$COOKIE1")
assert_code "$C1" 201 "create todo 1"
assert_json_ct "$H1"
read H2 B2 C2 < <(request POST /todos -H 'Content-Type: application/json' -d '{"title":"Second"}' -b "$COOKIE1")
assert_code "$C2" 201 "create todo 2"
assert_json_ct "$H2"

# 10) List todos
read H B C < <(request GET /todos -b "$COOKIE1")
assert_code "$C" 200 "list todos"
assert_json_ct "$H"
assert_body_contains "$B" '"title":"First"'
assert_body_contains "$B" '"title":"Second"'

# 11) Get todo by id 1
read H B C < <(request GET /todos/1 -b "$COOKIE1")
assert_code "$C" 200 "get todo 1"
assert_json_ct "$H"

# 12) Update todo 1 completed true
read H B C < <(request PUT /todos/1 -H 'Content-Type: application/json' -d '{"completed":true}' -b "$COOKIE1")
assert_code "$C" 200 "update todo 1"
assert_json_ct "$H"
assert_body_contains "$B" '"completed":true'

# 13) Update todo with empty title should 400
read H B C < <(request PUT /todos/1 -H 'Content-Type: application/json' -d '{"title":""}' -b "$COOKIE1")
assert_code "$C" 400 "empty title should 400"
assert_json_ct "$H"

# 14) Delete todo 2
read H B C < <(request DELETE /todos/2 -b "$COOKIE1")
if [[ "$C" != "204" ]]; then
  echo "DELETE should return 204, got $C" >&2
  exit 1
fi
# Body must be empty for 204
if [[ -s "$B" ]]; then
  echo "DELETE should have no body" >&2
  exit 1
fi

# 15) Get deleted todo 2 -> 404
read H B C < <(request GET /todos/2 -b "$COOKIE1")
assert_code "$C" 404 "deleted todo should 404"
assert_json_ct "$H"

# 16) Logout
read H B C < <(request POST /logout -b "$COOKIE1")
assert_code "$C" 200 "logout"
assert_json_ct "$H"

# 17) Access after logout -> 401
read H B C < <(request GET /me -b "$COOKIE1")
assert_code "$C" 401 "after logout should 401"
assert_json_ct "$H"

# 18) Login with new password
COOKIE2=$(mktemp)
read H B C < <(request POST /login -H 'Content-Type: application/json' -d '{"username":"test_user","password":"newpassword123"}' -c "$COOKIE2")
assert_code "$C" 200 "login with new pw"
assert_json_ct "$H"

# 19) Create second user and test 404 for others' todos
read H B C < <(request POST /register -H 'Content-Type: application/json' -d '{"username":"other_user","password":"password123"}')
assert_code "$C" 201 "register other"
COOKIE3=$(mktemp)
read H B C < <(request POST /login -H 'Content-Type: application/json' -d '{"username":"other_user","password":"password123"}' -c "$COOKIE3")
assert_code "$C" 200 "login other"
read H B C < <(request GET /todos/1 -b "$COOKIE3")
assert_code "$C" 404 "should not access others todo"
assert_json_ct "$H"

echo "All tests passed."