#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-$((18000 + (RANDOM % 1000)))}
ROOT=$(pwd)

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f headers body headers2 body2 c1.txt c2.txt
}
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" &
SERVER_PID=$!

# Wait for server
for i in {1..60}; do
  if curl -sS "http://127.0.0.1:$PORT/me" -o /dev/null; then break; fi
  sleep 0.2
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then echo "Server died"; exit 1; fi
  if [[ $i -eq 60 ]]; then echo "Server did not start"; exit 1; fi
done

base="http://127.0.0.1:$PORT"

check_json_ct() {
  # Expect application/json content-type in headers file $1
  grep -i '^Content-Type: application/json' "$1" >/dev/null || { echo "Missing JSON content-type"; cat "$1"; exit 1; }
}

# Register user1
code=$(curl -s -o body -D headers -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/register" --data '{"username":"user_one","password":"password123"}')
[[ "$code" == "201" ]] || { echo "Register failed: $code"; cat body; exit 1; }
check_json_ct headers
grep '"username":"user_one"' body >/dev/null || { echo "Bad register body"; cat body; exit 1; }

# Duplicate username -> 409
code=$(curl -s -o body -D headers -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/register" --data '{"username":"user_one","password":"password123"}')
[[ "$code" == "409" ]] || { echo "Duplicate register did not 409: $code"; cat body; exit 1; }
check_json_ct headers

# Login user1
code=$(curl -s -o body -D headers -c c1.txt -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/login" --data '{"username":"user_one","password":"password123"}')
[[ "$code" == "200" ]] || { echo "Login failed: $code"; cat body; exit 1; }
check_json_ct headers
grep -i '^Set-Cookie: session_id=' headers >/dev/null || { echo "Missing Set-Cookie"; cat headers; exit 1; }

# GET /me
code=$(curl -s -o body -D headers -b c1.txt -w '%{http_code}' "$base/me")
[[ "$code" == "200" ]] || { echo "/me failed: $code"; cat body; exit 1; }
check_json_ct headers

# List todos (empty)
code=$(curl -s -o body -D headers -b c1.txt -w '%{http_code}' "$base/todos")
[[ "$code" == "200" ]] || { echo "GET /todos failed: $code"; cat body; exit 1; }
check_json_ct headers
grep '^\[\]' body >/dev/null || true

# Create todo 1
code=$(curl -s -o body -D headers -b c1.txt -H 'Content-Type: application/json' -w '%{http_code}' -X POST "$base/todos" --data '{"title":"First","description":"D1"}')
[[ "$code" == "201" ]] || { echo "POST /todos failed: $code"; cat body; exit 1; }
check_json_ct headers
grep '"title":"First"' body >/dev/null || { echo "Todo not returned"; cat body; exit 1; }
ID1=$(grep -o '"id":[0-9]\+' body | head -1 | cut -d: -f2)
[ -n "$ID1" ] || { echo "Failed to parse todo id"; cat body; exit 1; }

grep -o '"created_at":"[^"]\+Z"' body >/dev/null || true

# Create todo 2
code=$(curl -s -o body2 -D headers2 -b c1.txt -H 'Content-Type: application/json' -w '%{http_code}' -X POST "$base/todos" --data '{"title":"Second"}')
[[ "$code" == "201" ]] || { echo "POST /todos 2 failed: $code"; cat body2; exit 1; }
check_json_ct headers2
ID2=$(grep -o '"id":[0-9]\+' body2 | head -1 | cut -d: -f2)

# List and check order
code=$(curl -s -o body -D headers -b c1.txt -w '%{http_code}' "$base/todos")
[[ "$code" == "200" ]] || { echo "GET /todos failed: $code"; cat body; exit 1; }
check_json_ct headers
FIRST_ID=$(grep -o '"id":[0-9]\+' body | head -1 | cut -d: -f2)
SECOND_ID=$(grep -o '"id":[0-9]\+' body | sed -n '2p' | cut -d: -f2)
[[ "$FIRST_ID" -le "$SECOND_ID" ]] || { echo "Todos not ordered"; cat body; exit 1; }

# Get todo by id
code=$(curl -s -o body -D headers -b c1.txt -w '%{http_code}' "$base/todos/$ID1")
[[ "$code" == "200" ]] || { echo "GET /todos/$ID1 failed: $code"; cat body; exit 1; }
check_json_ct headers

# Update with empty title -> 400
code=$(curl -s -o body -D headers -b c1.txt -H 'Content-Type: application/json' -w '%{http_code}' -X PUT "$base/todos/$ID1" --data '{"title":""}')
[[ "$code" == "400" ]] || { echo "Empty title did not 400: $code"; cat body; exit 1; }
check_json_ct headers

# Update todo
code=$(curl -s -o body -D headers -b c1.txt -H 'Content-Type: application/json' -w '%{http_code}' -X PUT "$base/todos/$ID1" --data '{"description":"Updated","completed":true}')
[[ "$code" == "200" ]] || { echo "PUT /todos/$ID1 failed: $code"; cat body; exit 1; }
check_json_ct headers
grep '"completed":true' body >/dev/null || { echo "Update not applied"; cat body; exit 1; }

# Delete todo 1
code=$(curl -s -o body -D headers -b c1.txt -w '%{http_code}' -X DELETE "$base/todos/$ID1")
[[ "$code" == "204" ]] || { echo "DELETE /todos/$ID1 failed: $code"; cat headers; exit 1; }
# No body expected
[[ ! -s body ]] || { echo "DELETE returned body"; cat body; exit 1; }

# Deleted not found
code=$(curl -s -o body -D headers -b c1.txt -w '%{http_code}' "$base/todos/$ID1")
[[ "$code" == "404" ]] || { echo "Deleted todo did not return 404: $code"; cat body; exit 1; }
check_json_ct headers

# Logout
code=$(curl -s -o body -D headers -b c1.txt -w '%{http_code}' -X POST "$base/logout")
[[ "$code" == "200" ]] || { echo "Logout failed: $code"; cat body; exit 1; }
check_json_ct headers

# Auth-required after logout
code=$(curl -s -o body -D headers -b c1.txt -w '%{http_code}' "$base/me")
[[ "$code" == "401" ]] || { echo "Auth not enforced after logout: $code"; cat body; exit 1; }
check_json_ct headers

# Login with wrong password -> 401
code=$(curl -s -o body -D headers -c c1.txt -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/login" --data '{"username":"user_one","password":"wrongpass"}')
[[ "$code" == "401" ]] || { echo "Login wrong pass not 401: $code"; cat body; exit 1; }
check_json_ct headers

# Login again with correct password
code=$(curl -s -o body -D headers -c c1.txt -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/login" --data '{"username":"user_one","password":"password123"}')
[[ "$code" == "200" ]] || { echo "Re-login failed: $code"; cat body; exit 1; }
check_json_ct headers

# Change password wrong old -> 401
code=$(curl -s -o body -D headers -b c1.txt -H 'Content-Type: application/json' -w '%{http_code}' -X PUT "$base/password" --data '{"old_password":"bad","new_password":"newpassword1"}')
[[ "$code" == "401" ]] || { echo "Wrong old password not 401: $code"; cat body; exit 1; }
check_json_ct headers

# Change password too short -> 400
code=$(curl -s -o body -D headers -b c1.txt -H 'Content-Type: application/json' -w '%{http_code}' -X PUT "$base/password" --data '{"old_password":"password123","new_password":"short"}')
[[ "$code" == "400" ]] || { echo "Short new password not 400: $code"; cat body; exit 1; }
check_json_ct headers

# Change password correct
code=$(curl -s -o body -D headers -b c1.txt -H 'Content-Type: application/json' -w '%{http_code}' -X PUT "$base/password" --data '{"old_password":"password123","new_password":"newpassword1"}')
[[ "$code" == "200" ]] || { echo "Password change failed: $code"; cat body; exit 1; }
check_json_ct headers

# Logout and verify old login fails
code=$(curl -s -o body -D headers -b c1.txt -w '%{http_code}' -X POST "$base/logout")
[[ "$code" == "200" ]] || { echo "Logout after pw change failed: $code"; cat body; exit 1; }

# Login with old password -> 401
code=$(curl -s -o body -D headers -c c1.txt -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/login" --data '{"username":"user_one","password":"password123"}')
[[ "$code" == "401" ]] || { echo "Old password still works: $code"; cat body; exit 1; }
check_json_ct headers

# Login with new password
code=$(curl -s -o body -D headers -c c1.txt -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/login" --data '{"username":"user_one","password":"newpassword1"}')
[[ "$code" == "200" ]] || { echo "New password login failed: $code"; cat body; exit 1; }

# Second user cannot see first user's todo (ID2)
code=$(curl -s -o body -D headers -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/register" --data '{"username":"user_two","password":"passwordABC"}')
[[ "$code" == "201" ]] || { echo "Register user_two failed: $code"; cat body; exit 1; }

code=$(curl -s -o body -D headers -c c2.txt -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/login" --data '{"username":"user_two","password":"passwordABC"}')
[[ "$code" == "200" ]] || { echo "Login user_two failed: $code"; cat body; exit 1; }

code=$(curl -s -o body -D headers -b c2.txt -w '%{http_code}' "$base/todos/$ID2")
[[ "$code" == "404" ]] || { echo "Other user's todo did not 404: $code"; cat body; exit 1; }
check_json_ct headers

echo "All tests passed on port $PORT"