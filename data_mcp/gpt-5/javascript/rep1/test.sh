#!/usr/bin/env bash
set -euo pipefail
PORT=3456
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID >/dev/null 2>&1 || true
}
trap cleanup EXIT

# wait for server
for i in {1..50}; do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/me"; then
    break
  fi
  sleep 0.1
done

request() {
  local method="$1" url="$2" data="${3-}" extra_header="${4-}"
  local headers_file body_file
  headers_file=$(mktemp)
  body_file=$(mktemp)
  if [[ -n "$data" ]]; then
    http_code=$(curl -s -o "$body_file" -D "$headers_file" -w "%{http_code}" -X "$method" -H 'Content-Type: application/json' ${extra_header:+-H "$extra_header"} --data "$data" "$url")
  else
    http_code=$(curl -s -o "$body_file" -D "$headers_file" -w "%{http_code}" -X "$method" ${extra_header:+-H "$extra_header"} "$url")
  fi
  echo "$headers_file|$body_file|$http_code"
}

get_header() {
  local file="$1" name="$2"
  # case-insensitive header search
  awk -v IGNORECASE=1 -v name="$name" '$0 ~ "^"name":" {print substr($0, index($0,$2))}' "$file" | head -n1 | sed 's/^.*: *//'
}

assert_json_ct() {
  local headers_file="$1"
  ct=$(get_header "$headers_file" 'Content-Type') || true
  if [[ ! "$ct" =~ application/json ]]; then
    echo "Expected Content-Type application/json, got: $ct"
    exit 1
  fi
}

# 1) Register
out=$(request POST "http://127.0.0.1:$PORT/register" '{"username":"alice_01","password":"password123"}')
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "201" ]] || { echo "Register failed: $code"; exit 1; }
assert_json_ct "$h"
user_id=$(cat "$b" | sed -n 's/.*\"id\":\s*\([0-9][0-9]*\).*/\1/p')
[[ -n "$user_id" ]] || { echo "No user id in response"; echo "$(cat "$b")"; exit 1; }

# 2) Login
out=$(request POST "http://127.0.0.1:$PORT/login" '{"username":"alice_01","password":"password123"}')
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "200" ]] || { echo "Login failed: $code"; exit 1; }
assert_json_ct "$h"
set_cookie=$(get_header "$h" 'Set-Cookie')
[[ "$set_cookie" == session_id=* ]] || { echo "Missing Set-Cookie: $set_cookie"; exit 1; }
session_token=$(echo "$set_cookie" | sed -n 's/.*session_id=\([^;]*\).*/\1/p')
[[ -n "$session_token" ]] || { echo "No session token"; exit 1; }
COOKIE_HEADER="Cookie: session_id=$session_token"

# 3) /me
out=$(request GET "http://127.0.0.1:$PORT/me" '' "$COOKIE_HEADER")
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "200" ]] || { echo "/me failed: $code"; exit 1; }
assert_json_ct "$h"

# 4) GET /todos (empty)
out=$(request GET "http://127.0.0.1:$PORT/todos" '' "$COOKIE_HEADER")
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "200" ]] || { echo "GET /todos failed: $code"; exit 1; }
assert_json_ct "$h"
[[ "$(cat "$b")" == "[]" ]] || true

# 5) POST /todos create
out=$(request POST "http://127.0.0.1:$PORT/todos" '{"title":"Task 1","description":"desc"}' "$COOKIE_HEADER")
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "201" ]] || { echo "POST /todos failed: $code"; exit 1; }
assert_json_ct "$h"
todo_id=$(sed -n 's/.*\"id\":\s*\([0-9][0-9]*\).*/\1/p' "$b")
[[ -n "$todo_id" ]] || { echo "No todo id"; cat "$b"; exit 1; }

# 6) GET /todos/:id
out=$(request GET "http://127.0.0.1:$PORT/todos/$todo_id" '' "$COOKIE_HEADER")
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "200" ]] || { echo "GET /todos/:id failed: $code"; exit 1; }
assert_json_ct "$h"

# 7) PUT /todos/:id partial update
out=$(request PUT "http://127.0.0.1:$PORT/todos/$todo_id" '{"completed": true, "description": "updated"}' "$COOKIE_HEADER")
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "200" ]] || { echo "PUT /todos/:id failed: $code"; exit 1; }
assert_json_ct "$h"

# 8) DELETE /todos/:id
out=$(request DELETE "http://127.0.0.1:$PORT/todos/$todo_id" '' "$COOKIE_HEADER")
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "204" ]] || { echo "DELETE /todos/:id failed: $code"; exit 1; }
# ensure no body
if [[ -s "$b" ]]; then echo "DELETE returned body"; cat "$b"; exit 1; fi

# 9) POST /logout
out=$(request POST "http://127.0.0.1:$PORT/logout" '' "$COOKIE_HEADER")
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "200" ]] || { echo "POST /logout failed: $code"; exit 1; }
assert_json_ct "$h"

# 10) Access /me should be 401 after logout
out=$(request GET "http://127.0.0.1:$PORT/me")
IFS='|' read -r h b code <<<"$out"
[[ "$code" == "401" ]] || { echo "Expected 401 after logout, got: $code"; exit 1; }
assert_json_ct "$h"

echo "All tests passed"