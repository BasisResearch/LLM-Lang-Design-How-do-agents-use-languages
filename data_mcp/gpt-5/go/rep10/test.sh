#!/usr/bin/env bash
set -euo pipefail

PORT=$((19000 + RANDOM % 1000))
COOKIE1="cookies1.txt"
COOKIE2="cookies2.txt"
rm -f "$COOKIE1" "$COOKIE2"

# Build and run server directly to capture correct PID
go build -o server .
./server --port "$PORT" >srv.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID on port $PORT"
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
  rm -f "$COOKIE1" "$COOKIE2" out.json headers.txt body.json srv.log
}
trap cleanup EXIT

# Wait for server
for i in {1..50}; do
  code=$(curl -s "http://127.0.0.1:$PORT/me" -o /dev/null -w "%{http_code}" || true)
  if [[ "$code" =~ ^(401|405|404)$ ]]; then
    break
  fi
  sleep 0.1
  if [[ $i -eq 50 ]]; then
    echo "Server did not start in time" >&2
    echo "----- server log -----" >&2
    cat srv.log >&2 || true
    exit 1
  fi
done

request() {
  local method=$1
  local path=$2
  local data=${3:-}
  local cookiejar=${4:-}
  if [[ -n "$data" ]]; then
    echo -n "$data" > body.json
    data_opt=(--data @body.json)
  else
    data_opt=()
  fi
  if [[ -n "$cookiejar" ]]; then
    cookie_opts=(-b "$cookiejar" -c "$cookiejar")
  else
    cookie_opts=()
  fi
  http_code=$(curl -sS -X "$method" "http://127.0.0.1:$PORT$path" -H 'Content-Type: application/json' "${data_opt[@]}" -o out.json -w "%{http_code}" -D headers.txt "${cookie_opts[@]}")
  echo "$http_code"
}

expect_code() {
  local got=$1
  local want=$2
  local msg=$3
  if [[ "$got" != "$want" ]]; then
    echo "FAIL ($msg): expected $want got $got" >&2
    echo "Response body:" >&2
    cat out.json >&2 || true
    echo "----- server log -----" >&2
    cat srv.log >&2 || true
    exit 1
  fi
}

extract_id() {
  # prints first numeric id value from out.json
  grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]\+' out.json | head -n1 | sed 's/[^0-9]*//g'
}

# 1) Register
code=$(request POST /register '{"username":"user_1","password":"password123"}')
expect_code "$code" 201 "register"
uid=$(extract_id)
[[ -n "$uid" ]] || { echo "No user id"; exit 1; }

# 2) Register duplicate
code=$(request POST /register '{"username":"user_1","password":"password123"}')
expect_code "$code" 409 "register duplicate"

# 3) Login invalid
code=$(request POST /login '{"username":"user_1","password":"wrong"}')
expect_code "$code" 401 "login invalid"

# 4) Login valid
code=$(request POST /login '{"username":"user_1","password":"password123"}' "$COOKIE1")
expect_code "$code" 200 "login valid"

# 5) GET /me
code=$(request GET /me '' "$COOKIE1")
expect_code "$code" 200 "/me"

# 6) Change password wrong old
code=$(request PUT /password '{"old_password":"bad","new_password":"newpass123"}' "$COOKIE1")
expect_code "$code" 401 "/password wrong old"

# 7) Change password OK
code=$(request PUT /password '{"old_password":"password123","new_password":"newpass123"}' "$COOKIE1")
expect_code "$code" 200 "/password ok"

# 8) Login with old password should fail
code=$(request POST /login '{"username":"user_1","password":"password123"}' )
expect_code "$code" 401 "login old password"

# 9) Login with new password
code=$(request POST /login '{"username":"user_1","password":"newpass123"}' "$COOKIE1")
expect_code "$code" 200 "login new password"

# 10) GET /todos initially empty
code=$(request GET /todos '' "$COOKIE1")
expect_code "$code" 200 "/todos list empty"
if ! grep -q '^\[\s*\]$' out.json; then
  echo "Expected empty array for todos" >&2
  cat out.json >&2
  exit 1
fi

# 11) Create todo 1
code=$(request POST /todos '{"title":"Task 1","description":"Desc 1"}' "$COOKIE1")
expect_code "$code" 201 "create todo 1"
todo1=$(extract_id)

# 12) Create todo 2
code=$(request POST /todos '{"title":"Task 2"}' "$COOKIE1")
expect_code "$code" 201 "create todo 2"
todo2=$(extract_id)

# 13) List todos should have 2 ordered by id
code=$(request GET /todos '' "$COOKIE1")
expect_code "$code" 200 "/todos list 2"
ids=$(grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]\+' out.json | sed 's/[^0-9]//g' | tr '\n' ' ')
first_id=$(echo "$ids" | awk '{print $1}')
second_id=$(echo "$ids" | awk '{print $2}')
if [[ "$first_id" != "$todo1" || "$second_id" != "$todo2" ]]; then
  echo "Todos not ordered by id or missing" >&2
  echo "Expected: $todo1 then $todo2, got: $first_id then $second_id" >&2
  cat out.json >&2
  exit 1
fi

# 14) Get todo1
code=$(request GET /todos/$todo1 '' "$COOKIE1")
expect_code "$code" 200 "get todo1"

# 15) Update todo1
code=$(request PUT /todos/$todo1 '{"completed":true,"title":"Task 1 updated"}' "$COOKIE1")
expect_code "$code" 200 "update todo1"
if ! grep -q '"completed"[[:space:]]*:[[:space:]]*true' out.json; then
  echo "Expected completed true" >&2
  cat out.json >&2
  exit 1
fi

# 16) Other user cannot see todo1
code=$(request POST /register '{"username":"user_2","password":"passwordABC"}')
expect_code "$code" 201 "register user2"
code=$(request POST /login '{"username":"user_2","password":"passwordABC"}' "$COOKIE2")
expect_code "$code" 200 "login user2"
code=$(request GET /todos/$todo1 '' "$COOKIE2")
expect_code "$code" 404 "user2 cannot see user1 todo"

# 17) Delete todo1 by user1
code=$(request DELETE /todos/$todo1 '' "$COOKIE1")
expect_code "$code" 204 "delete todo1"
# verify gone
code=$(request GET /todos/$todo1 '' "$COOKIE1")
expect_code "$code" 404 "todo1 gone"

# 18) Logout and verify session invalidated
code=$(request POST /logout '' "$COOKIE1")
expect_code "$code" 200 "logout"
code=$(request GET /me '' "$COOKIE1")
expect_code "$code" 401 "me after logout"

# 19) Unauthorized access should be 401
code=$(request GET /todos)
expect_code "$code" 401 "todos unauthorized"

echo "All tests passed"
exit 0
