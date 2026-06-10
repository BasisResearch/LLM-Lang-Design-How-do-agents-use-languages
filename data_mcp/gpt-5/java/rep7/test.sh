#!/usr/bin/env bash
set -euo pipefail
PORT=8091
./run.sh --port "$PORT" >/dev/null 2>&1 &
PID=$!
sleep 1
cleanup() { kill $PID >/dev/null 2>&1 || true; }
trap cleanup EXIT

base() { echo "http://127.0.0.1:$PORT$1"; }
expect_code() {
  local expected=$1; shift
  local code=$(curl -sS -o /dev/null -w "%{http_code}" "$@")
  if [[ "$code" != "$expected" ]]; then
    echo "Expected $expected but got $code for: $@" >&2
    exit 1
  fi
}

# Register
expect_code 400 -H 'Content-Type: application/json' -d '{"username":"ab","password":"short"}' -X POST "$(base /register)"
expect_code 400 -H 'Content-Type: application/json' -d '{"username":"user_1","password":"short"}' -X POST "$(base /register)"
expect_code 201 -H 'Content-Type: application/json' -d '{"username":"user_1","password":"longpassword"}' -X POST "$(base /register)"
expect_code 409 -H 'Content-Type: application/json' -d '{"username":"user_1","password":"anotherpass"}' -X POST "$(base /register)"

# Login
expect_code 401 -H 'Content-Type: application/json' -d '{"username":"user_1","password":"wrong"}' -X POST "$(base /login)"
COOKIE=$(curl -sS -D - -H 'Content-Type: application/json' -d '{"username":"user_1","password":"longpassword"}' -X POST "$(base /login)" | awk '/Set-cookie:/ {print $2}' | sed 's/;$//' | tr -d '\r')
[ -n "$COOKIE" ] || { echo "No session cookie"; exit 1; }

# Me
expect_code 200 -H "Cookie: $COOKIE" "$(base /me)"

# Password change
expect_code 401 -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"wrong","new_password":"newpass123"}' -X PUT "$(base /password)"
expect_code 400 -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"longpassword","new_password":"short"}' -X PUT "$(base /password)"
expect_code 200 -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"longpassword","new_password":"newpass123"}' -X PUT "$(base /password)"

# Login with new password
COOKIE=$(curl -sS -D - -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpass123"}' -X POST "$(base /login)" | awk '/Set-cookie:/ {print $2}' | sed 's/;$//' | tr -d '\r')

# Todos
expect_code 200 -H "Cookie: $COOKIE" "$(base /todos)"
expect_code 400 -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":"","description":""}' -X POST "$(base /todos)"
expect_code 201 -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":"First","description":"desc"}' -X POST "$(base /todos)"

# Get todo id 1
expect_code 200 -H "Cookie: $COOKIE" "$(base /todos/1)"
expect_code 404 -H "Cookie: $COOKIE" "$(base /todos/999)"

# Ensure other user cannot access
expect_code 201 -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password123"}' -X POST "$(base /register)"
COOKIE2=$(curl -sS -D - -H 'Content-Type: application/json' -d '{"username":"user_2","password":"password123"}' -X POST "$(base /login)" | awk '/Set-cookie:/ {print $2}' | sed 's/;$//' | tr -d '\r')
expect_code 404 -H "Cookie: $COOKIE2" "$(base /todos/1)"

# Update and delete
expect_code 200 -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"completed": true, "description":"changed"}' -X PUT "$(base /todos/1)"
expect_code 400 -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":""}' -X PUT "$(base /todos/1)"
# Delete
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" -X DELETE "$(base /todos/1)")
[[ "$code" == "204" ]] || { echo "Delete should 204, got $code"; exit 1; }
# Confirm gone
expect_code 404 -H "Cookie: $COOKIE" "$(base /todos/1)"

# Logout invalidates session
expect_code 200 -H "Cookie: $COOKIE" -X POST "$(base /logout)"
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE" "$(base /me)")
[[ "$code" == "401" ]] || { echo "Expected 401 after logout, got $code"; exit 1; }

echo "All tests passed"
