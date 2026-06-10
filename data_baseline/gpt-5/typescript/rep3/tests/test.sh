#!/usr/bin/env bash
set -euo pipefail
PORT=3456
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SERVER_CMD="$ROOT_DIR/run.sh --port $PORT"
COOKIE1=$(mktemp)
COOKIE2=$(mktemp)
BODY=$(mktemp)
HEADERS=$(mktemp)

cleanup() {
  rm -f "$COOKIE1" "$COOKIE2" "$BODY" "$HEADERS"
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Start server
bash -lc "$SERVER_CMD" &
SERVER_PID=$!

# wait for server
for i in {1..50}; do
  if curl -s "http://127.0.0.1:$PORT/me" -o /dev/null; then
    break
  fi
  sleep 0.1
done

echo "Testing unauthorized /me..."
code=$(curl -s -o "$BODY" -w "%{http_code}" "http://127.0.0.1:$PORT/me")
[[ "$code" == "401" ]] || { echo "Expected 401, got $code"; cat "$BODY"; exit 1; }

echo "Register user_one..."
code=$(curl -s -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "http://127.0.0.1:$PORT/register")
[[ "$code" == "201" ]] || { echo "Expected 201, got $code"; cat "$BODY"; exit 1; }

echo "Register duplicate user_one..."
code=$(curl -s -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "http://127.0.0.1:$PORT/register")
[[ "$code" == "409" ]] || { echo "Expected 409, got $code"; cat "$BODY"; exit 1; }

echo "Login wrong password..."
code=$(curl -s -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"wrongpass"}' "http://127.0.0.1:$PORT/login")
[[ "$code" == "401" ]] || { echo "Expected 401, got $code"; cat "$BODY"; exit 1; }

echo "Login correct..."
code=$(curl -s -c "$COOKIE1" -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "http://127.0.0.1:$PORT/login")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }

echo "GET /me..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" "http://127.0.0.1:$PORT/me")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }

echo "Change password wrong old..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword123"}' "http://127.0.0.1:$PORT/password")
[[ "$code" == "401" ]] || { echo "Expected 401, got $code"; cat "$BODY"; exit 1; }

echo "Change password too short..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' "http://127.0.0.1:$PORT/password")
[[ "$code" == "400" ]] || { echo "Expected 400, got $code"; cat "$BODY"; exit 1; }

echo "Change password correct..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}' "http://127.0.0.1:$PORT/password")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }

echo "Logout..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" -X POST "http://127.0.0.1:$PORT/logout")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }

echo "Access after logout should 401..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" "http://127.0.0.1:$PORT/me")
[[ "$code" == "401" ]] || { echo "Expected 401 after logout, got $code"; cat "$BODY"; exit 1; }

echo "Login with new password..."
code=$(curl -s -c "$COOKIE1" -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpassword123"}' "http://127.0.0.1:$PORT/login")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }

echo "GET /todos should be empty..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" "http://127.0.0.1:$PORT/todos")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }
[[ "$(cat "$BODY")" == "[]" ]] || { echo "Expected empty list, got:"; cat "$BODY"; exit 1; }

echo "POST /todos missing title..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"description":"desc"}' "http://127.0.0.1:$PORT/todos")
[[ "$code" == "400" ]] || { echo "Expected 400, got $code"; cat "$BODY"; exit 1; }

echo "POST /todos create first..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"First"}' "http://127.0.0.1:$PORT/todos")
[[ "$code" == "201" ]] || { echo "Expected 201, got $code"; cat "$BODY"; exit 1; }

echo "Create second todo to test privacy later..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"title":"Second","description":"abc"}' "http://127.0.0.1:$PORT/todos")
[[ "$code" == "201" ]] || { echo "Expected 201, got $code"; cat "$BODY"; exit 1; }

# get list and extract ID 1 and 2 counts by simple greps
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" "http://127.0.0.1:$PORT/todos")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }
[[ "$(grep -o '"id":' "$BODY" | wc -l)" -ge 2 ]] || { echo "Expected at least 2 todos"; cat "$BODY"; exit 1; }

# Assume ids are 1 and 2

echo "GET /todos/1..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" "http://127.0.0.1:$PORT/todos/1")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }

echo "PUT /todos/1 update..."
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"title":"First updated","completed":true}' "http://127.0.0.1:$PORT/todos/1")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }

echo "DELETE /todos/1..."
code=$(curl -s -D "$HEADERS" -b "$COOKIE1" -o /dev/null -w "%{http_code}" -X DELETE "http://127.0.0.1:$PORT/todos/1")
[[ "$code" == "204" ]] || { echo "Expected 204, got $code"; cat "$HEADERS"; exit 1; }

# After delete, GET should 404
code=$(curl -s -b "$COOKIE1" -o "$BODY" -w "%{http_code}" "http://127.0.0.1:$PORT/todos/1")
[[ "$code" == "404" ]] || { echo "Expected 404 after delete, got $code"; cat "$BODY"; exit 1; }

# Privacy test: user_two cannot access user_one's todo id 2

echo "Register user_two..."
code=$(curl -s -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password456"}' "http://127.0.0.1:$PORT/register")
[[ "$code" == "201" ]] || { echo "Expected 201, got $code"; cat "$BODY"; exit 1; }

echo "Login user_two..."
code=$(curl -s -c "$COOKIE2" -o "$BODY" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password456"}' "http://127.0.0.1:$PORT/login")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }

# user_two list should be empty
code=$(curl -s -b "$COOKIE2" -o "$BODY" -w "%{http_code}" "http://127.0.0.1:$PORT/todos")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; cat "$BODY"; exit 1; }
[[ "$(cat "$BODY")" == "[]" ]] || { echo "Expected empty list for user_two, got:"; cat "$BODY"; exit 1; }

# user_two try to access user_one's todo id 2
code=$(curl -s -b "$COOKIE2" -o "$BODY" -w "%{http_code}" "http://127.0.0.1:$PORT/todos/2")
[[ "$code" == "404" ]] || { echo "Expected 404 for other user's todo, got $code"; cat "$BODY"; exit 1; }

echo "All tests passed"
