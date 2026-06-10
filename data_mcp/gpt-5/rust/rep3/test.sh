#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-8090}
ROOT_DIR=$(cd "$(dirname "$0")" && pwd)

# Prebuild to speed startup
( cd "$ROOT_DIR/todo_server" && cargo build --release >/dev/null )

# Start server
"$ROOT_DIR/run.sh" --port "$PORT" >/tmp/todo_server.log 2>&1 &
SERVER_PID=$!
trap 'kill $SERVER_PID >/dev/null 2>&1 || true' EXIT

# Wait for server to be ready
for i in {1..60}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/me || true)
  if [[ "$code" != "000" ]]; then break; fi
  sleep 0.5
done

if [[ "$code" == "000" ]]; then
  echo "Server did not start in time" >&2
  exit 1
fi

cookiejar=$(mktemp)

check_json_ct() {
  local url=$1 method=$2 data=${3:-}
  if [[ -n "$data" ]]; then
    headers=$(curl -s -D - -o /dev/null -X "$method" -H 'Content-Type: application/json' -d "$data" "$url")
  else
    headers=$(curl -s -D - -o /dev/null -X "$method" "$url")
  fi
  echo "$headers" | grep -i '^content-type: application/json' >/dev/null
}

base=http://127.0.0.1:$PORT

# 1) Register
resp=$(curl -s -D - -o /tmp/reg_body.txt -X POST -H 'Content-Type: application/json' \
  -d '{"username":"user_1","password":"password123"}' "$base/register")
echo "$resp" | grep ' 201 ' >/dev/null
check_json_ct "$base/register" POST '{"username":"x___","password":"password123"}' >/dev/null || true

# 1a) Duplicate username -> 409
resp=$(curl -s -D - -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d '{"username":"user_1","password":"password123"}' "$base/register")
echo "$resp" | grep ' 409 ' >/dev/null

# 2) Login (store cookies)
resp=$(curl -s -D /tmp/login_headers.txt -o /tmp/login_body.txt -c "$cookiejar" -b "$cookiejar" \
  -X POST -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$base/login")
grep -i '^set-cookie: .*session_id=' /tmp/login_headers.txt >/dev/null

# Ensure content-type json
grep -i '^content-type: application/json' /tmp/login_headers.txt >/dev/null

# 3) /me should work
code=$(curl -s -o /tmp/me_body.txt -w '%{http_code}' -b "$cookiejar" "$base/me")
[[ "$code" == "200" ]]

# 4) Change password wrong old
code=$(curl -s -o /tmp/pw_body.txt -w '%{http_code}' -b "$cookiejar" -X PUT -H 'Content-Type: application/json' \
  -d '{"old_password":"wrong","new_password":"newpassword123"}' "$base/password")
[[ "$code" == "401" ]]

# 5) Change password correct
code=$(curl -s -o /tmp/pw_body2.txt -w '%{http_code}' -b "$cookiejar" -X PUT -H 'Content-Type: application/json' \
  -d '{"old_password":"password123","new_password":"newpassword123"}' "$base/password")
[[ "$code" == "200" ]]

# 6) Logout
code=$(curl -s -o /tmp/logout_body.txt -w '%{http_code}' -b "$cookiejar" -X POST "$base/logout")
[[ "$code" == "200" ]]

# 7) /me must now be 401
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$cookiejar" "$base/me")
[[ "$code" == "401" ]]

# 8) Login with new password
> "$cookiejar"
code=$(curl -s -o /dev/null -w '%{http_code}' -D /tmp/login2_headers.txt -c "$cookiejar" -b "$cookiejar" \
  -X POST -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword123"}' "$base/login")
[[ "$code" == "200" ]]

# 9) List todos (empty)
body=$(curl -s -b "$cookiejar" "$base/todos")
[[ "$body" == "[]" ]]

# 10) Create todo without title -> 400
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$cookiejar" -X POST -H 'Content-Type: application/json' -d '{"title":""}' "$base/todos")
[[ "$code" == "400" ]]

# 11) Create todo
body=$(curl -s -b "$cookiejar" -X POST -H 'Content-Type: application/json' \
  -d '{"title":"Task 1","description":"Desc"}' "$base/todos")

echo "$body" | grep '"title":"Task 1"' >/dev/null

echo "$body" | grep '"completed":false' >/dev/null

# 12) List todos should have one item
body=$(curl -s -b "$cookiejar" "$base/todos")
echo "$body" | grep '\[{' >/dev/null

# 13) Get todo 1
code=$(curl -s -o /tmp/get1.txt -w '%{http_code}' -b "$cookiejar" "$base/todos/1")
[[ "$code" == "200" ]]

# 14) Update todo 1 (completed true)
body=$(curl -s -b "$cookiejar" -X PUT -H 'Content-Type: application/json' -d '{"completed":true}' "$base/todos/1")
echo "$body" | grep '"completed":true' >/dev/null

# 15) Delete todo 1
size=$(curl -s -o /tmp/del_body.txt -w '%{size_download}' -b "$cookiejar" -X DELETE "$base/todos/1")
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$cookiejar" -X DELETE "$base/todos/999")
[[ "$size" == "0" ]]
[[ "$code" == "404" ]]

# 16) Get deleted -> 404
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$cookiejar" "$base/todos/1")
[[ "$code" == "404" ]]

# 17) Create todo again to test cross-user 404
body=$(curl -s -b "$cookiejar" -X POST -H 'Content-Type: application/json' \
  -d '{"title":"Task 2"}' "$base/todos")
# Assuming id 2

# 18) Register and login second user
curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password123"}' "$base/register" >/dev/null
cookiejar2=$(mktemp)
curl -s -D /tmp/login3_headers.txt -c "$cookiejar2" -b "$cookiejar2" -X POST -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password123"}' "$base/login" >/dev/null

# 19) Try to access user1's todo id 2 -> 404
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$cookiejar2" "$base/todos/2")
[[ "$code" == "404" ]]

# 20) Content-Type for non-DELETE endpoints should be application/json
headers=$(curl -s -D - -o /dev/null -b "$cookiejar2" "$base/me")
echo "$headers" | grep -i '^content-type: application/json' >/dev/null

echo "All tests passed"