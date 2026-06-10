#!/bin/bash
set -euo pipefail
PORT=18080
if [[ "${1-}" == "--port" ]]; then
  PORT="$2"
fi
./run.sh --port "$PORT" &
SERV_PID=$!
sleep 1
cleanup(){
  kill $SERV_PID || true
}
trap cleanup EXIT

base="http://127.0.0.1:$PORT"

function expect_json_content_type(){
  local headers="$1"
  if ! grep -qi '^content-type: application/json' <<<"$headers"; then
    echo "Content-Type not application/json" >&2; exit 1
  fi
}

cookies=$(mktemp)

# Register
echo "Registering..."
reg_out=$(curl -sS -D - -o >(tee /tmp/reg_body.txt) -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
expect_json_content_type "$reg_out"
if ! grep -q " 201 " <<<"$reg_out"; then echo "Register status not 201"; exit 1; fi

# Login
echo "Logging in..."
login_out=$(curl -sS -D - -c "$cookies" -o >(tee /tmp/login_body.txt) -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
expect_json_content_type "$login_out"
if ! grep -q " 200 " <<<"$login_out"; then echo "Login status not 200"; exit 1; fi
if ! grep -qi '^set-cookie: session_id=' <<<"$login_out"; then echo "Missing Set-Cookie"; exit 1; fi

# /me
echo "Checking /me..."
me_out=$(curl -sS -D - -b "$cookies" -o >(tee /tmp/me_body.txt) "$base/me")
expect_json_content_type "$me_out"
if ! grep -q " 200 " <<<"$me_out"; then echo "/me status not 200"; exit 1; fi

# Create todo
echo "Creating todo..."
create_out=$(curl -sS -D - -b "$cookies" -o >(tee /tmp/todo_body.txt) -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Desc"}')
expect_json_content_type "$create_out"
if ! grep -q " 201 " <<<"$create_out"; then echo "Create status not 201"; exit 1; fi

# List todos
echo "Listing todos..."
list_out=$(curl -sS -D - -b "$cookies" -o >(tee /tmp/list_body.txt) "$base/todos")
expect_json_content_type "$list_out"
if ! grep -q " 200 " <<<"$list_out"; then echo "List status not 200"; exit 1; fi

# Get todo id 1
echo "Getting todo 1..."
get_out=$(curl -sS -D - -b "$cookies" -o >(tee /tmp/get_body.txt) "$base/todos/1")
expect_json_content_type "$get_out"
if ! grep -q " 200 " <<<"$get_out"; then echo "Get status not 200"; exit 1; fi

# Update todo 1
echo "Updating todo 1..."
upd_out=$(curl -sS -D - -b "$cookies" -o >(tee /tmp/upd_body.txt) -X PUT "$base/todos/1" -H 'Content-Type: application/json' -d '{"completed":true}')
expect_json_content_type "$upd_out"
if ! grep -q " 200 " <<<"$upd_out"; then echo "Update status not 200"; exit 1; fi

# Delete todo 1
echo "Deleting todo 1..."
del_code=$(curl -sS -o /dev/null -w "%{http_code}" -b "$cookies" -X DELETE "$base/todos/1")
if [[ "$del_code" != "204" ]]; then echo "Delete status not 204"; exit 1; fi

# Logout
echo "Logging out..."
logout_out=$(curl -sS -D - -b "$cookies" -o >(tee /tmp/logout_body.txt) -X POST "$base/logout")
expect_json_content_type "$logout_out"
if ! grep -q " 200 " <<<"$logout_out"; then echo "Logout status not 200"; exit 1; fi

# Ensure session invalidated
me_code=$(curl -sS -o /dev/null -w "%{http_code}" -b "$cookies" "$base/me")
if [[ "$me_code" != "401" ]]; then echo "Session not invalidated"; exit 1; fi

echo "All tests passed."
