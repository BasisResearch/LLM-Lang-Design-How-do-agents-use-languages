#!/usr/bin/env bash
set -euo pipefail
PORT=18123
ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
SERVER_PID_FILE="$ROOT_DIR/server.pid"
COOKIE1="$ROOT_DIR/cookie1.txt"
COOKIE2="$ROOT_DIR/cookie2.txt"
rm -f "$COOKIE1" "$COOKIE2"

# Kill any running todo_server on this port
if pgrep -x todo_server >/dev/null 2>&1; then
  pkill -x todo_server || true
  sleep 1
fi

# Start server
"$ROOT_DIR/run.sh" --port "$PORT" &
SERVER_PID=$!
echo $SERVER_PID > "$SERVER_PID_FILE"

cleanup() {
  if kill -0 "$SERVER_PID" 2>/dev/null; then kill "$SERVER_PID" || true; fi
}
trap cleanup EXIT

# Wait for server to be ready (up to 60s)
for i in {1..60}; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/me" || true)
  if [[ "$code" == "401" || "$code" == "200" ]]; then break; fi
  sleep 1
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "Server exited early"; exit 1; fi
  if [[ "$i" -eq 60 ]]; then echo "Server did not start"; exit 1; fi
done

base() { echo "http://127.0.0.1:$PORT"; }

# Helper to perform curl and capture status, headers, body
req() {
  local method=$1; shift
  local path=$1; shift
  local cookie=$1; shift
  local data=${1-}
  local url="$(base)$path"
  local tmpd=$(mktemp -d)
  local headers="$tmpd/headers.txt"
  local body="$tmpd/body.txt"
  local code
  if [[ -n "$data" ]]; then
    code=$(curl -s -S -o "$body" -D "$headers" -w "%{http_code}" -X "$method" -H 'Content-Type: application/json' -b "$cookie" -c "$cookie" --data "$data" "$url")
  else
    code=$(curl -s -S -o "$body" -D "$headers" -w "%{http_code}" -X "$method" -b "$cookie" -c "$cookie" "$url")
  fi
  echo "$code|$headers|$body"
}

must_header_json() {
  local headers=$1
  if ! grep -qi '^content-type: application/json' "$headers"; then
    echo "Missing or wrong Content-Type header:"; cat "$headers"; exit 1
  fi
}

must_status() { local got=$1 exp=$2; [[ "$got" == "$exp" ]] || { echo "Expected status $exp got $got"; exit 1; }; }

# 1) Register validations
out=$(req POST /register "$COOKIE1" '{"username":"ab","password":"password123"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 400; must_header_json "$headers"; grep -q 'Invalid username' "$body"

out=$(req POST /register "$COOKIE1" '{"username":"user_one","password":"short"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 400; must_header_json "$headers"; grep -q 'Password too short' "$body"

# 2) Successful register
out=$(req POST /register "$COOKIE1" '{"username":"user_one","password":"password123"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 201; must_header_json "$headers"; grep -q '"username":"user_one"' "$body"; grep -q '"id":1' "$body"

# 3) Duplicate username
out=$(req POST /register "$COOKIE1" '{"username":"user_one","password":"password123"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 409; must_header_json "$headers"; grep -q 'Username already exists' "$body"

# 4) Login invalid
out=$(req POST /login "$COOKIE1" '{"username":"user_one","password":"wrongpass"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 401; must_header_json "$headers"; grep -q 'Invalid credentials' "$body"

# 5) Login success
out=$(req POST /login "$COOKIE1" '{"username":"user_one","password":"password123"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"; grep -qi '^set-cookie: session_id=' "$headers"; grep -qi 'Path=/' "$headers"; grep -qi 'HttpOnly' "$headers"

# 6) GET /me
out=$(req GET /me "$COOKIE1")
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"; grep -q '"username":"user_one"' "$body"

# 7) Change password invalid old
out=$(req PUT /password "$COOKIE1" '{"old_password":"nope","new_password":"newpassword123"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 401; must_header_json "$headers"; grep -q 'Invalid credentials' "$body"

# 8) Change password success
out=$(req PUT /password "$COOKIE1" '{"old_password":"password123","new_password":"newpassword123"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"; grep -q '{}' "$body"

# 9) Logout
out=$(req POST /logout "$COOKIE1")
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"

# 10) Access after logout must be 401
out=$(req GET /me "$COOKIE1")
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 401; must_header_json "$headers"; grep -q 'Authentication required' "$body"

# 11) Login with new password
out=$(req POST /login "$COOKIE1" '{"username":"user_one","password":"newpassword123"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"

# 12) Todos: list empty
out=$(req GET /todos "$COOKIE1")
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"; grep -q '^\[\]$' "$body"

# 13) Create todo without title -> 400
out=$(req POST /todos "$COOKIE1" '{"description":"desc only"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 400; must_header_json "$headers"; grep -q 'Title is required' "$body"

# 14) Create todo success
out=$(req POST /todos "$COOKIE1" '{"title":"Task 1","description":"First"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 201; must_header_json "$headers"; grep -q '"id":1' "$body"; grep -q '"completed":false' "$body"

# Capture timestamps for comparison
created_at=$(sed -n 's/.*"created_at":"\([^"]\+\)".*/\1/p' "$body")
updated_at=$(sed -n 's/.*"updated_at":"\([^"]\+\)".*/\1/p' "$body")

# 15) List has one
out=$(req GET /todos "$COOKIE1")
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"; grep -q '"id":1' "$body"

# 16) Get todo by id
out=$(req GET /todos/1 "$COOKIE1")
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"; grep -q '"id":1' "$body"

# 17) Update todo (partial)
out=$(req PUT /todos/1 "$COOKIE1" '{"completed":true,"description":"Updated"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"; grep -q '"completed":true' "$body"; grep -q '"description":"Updated"' "$body"
new_updated=$(sed -n 's/.*"updated_at":"\([^"]\+\)".*/\1/p' "$body")
if [[ "$new_updated" == "$updated_at" ]]; then echo "updated_at did not change"; exit 1; fi

# 18) Delete todo
out=$(req DELETE /todos/1 "$COOKIE1")
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 204
# body should be empty
if [[ -s "$body" ]]; then echo "DELETE returned body"; cat "$body"; exit 1; fi

# 19) Get deleted -> 404
out=$(req GET /todos/1 "$COOKIE1")
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 404; must_header_json "$headers"

# 20) Create second user and ensure cross-user 404
out=$(req POST /register "$COOKIE2" '{"username":"user_two","password":"passwordABC"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 201; must_header_json "$headers"

out=$(req POST /login "$COOKIE2" '{"username":"user_two","password":"passwordABC"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 200; must_header_json "$headers"

# Create todo for user_two id should be 2 (since first deleted), but we will capture it
out=$(req POST /todos "$COOKIE2" '{"title":"Other Task"}')
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body2=${out##*|}
must_status "$code" 201; must_header_json "$headers"
other_id=$(sed -n 's/.*"id":\([0-9]\+\).*/\1/p' "$body2")

# Access with user_one should be 404
out=$(req GET /todos/$other_id "$COOKIE1")
code=${out%%|*}; rest=${out#*|}; headers=${rest%%|*}; body=${out##*|}
must_status "$code" 404; must_header_json "$headers"; grep -q 'Todo not found' "$body"

echo "All tests passed"
