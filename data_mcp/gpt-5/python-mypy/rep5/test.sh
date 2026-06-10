#!/usr/bin/env bash
set -euo pipefail
PORT=8123
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() { kill $SERVER_PID 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5
base="http://127.0.0.1:$PORT"
# Ensure JSON content type and functionality
curl_json() { curl -sS -H 'Content-Type: application/json' "$@"; }

# Register
resp=$(curl_json -X POST "$base/register" -d '{"username":"alice","password":"password123"}')
echo "Register: $resp"
# Duplicate register should 409
code=$(curl_json -o /dev/null -w "%{http_code}" -X POST "$base/register" -d '{"username":"alice","password":"password123"}')
[[ "$code" == "409" ]] || { echo "Expected 409, got $code"; exit 1; }
# Login
headers=$(mktemp)
resp=$(curl_json -D "$headers" -X POST "$base/login" -d '{"username":"alice","password":"password123"}')
echo "Login: $resp"
session=$(grep -i '^Set-Cookie:' "$headers" | sed -E 's/.*session_id=([^;]+).*/\1/i' | tr -d '\r\n')
[[ -n "$session" ]] || { echo "Missing session cookie"; exit 1; }

auth_curl() { curl -sS -H 'Content-Type: application/json' -H "Cookie: session_id=$session" "$@"; }

# /me
resp=$(auth_curl "$base/me")
echo "Me: $resp"
# Change password wrong old
code=$(auth_curl -o /dev/null -w "%{http_code}" -X PUT "$base/password" -d '{"old_password":"bad","new_password":"newpassword123"}')
[[ "$code" == "401" ]] || { echo "Expected 401, got $code"; exit 1; }
# Change password ok
code=$(auth_curl -o /dev/null -w "%{http_code}" -X PUT "$base/password" -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; exit 1; }

# Todos list empty
resp=$(auth_curl "$base/todos")
echo "Todos list: $resp"
# Create todo
resp=$(auth_curl -X POST "$base/todos" -d '{"title":"Task 1","description":"Desc"}')
echo "Create todo: $resp"
# List again
resp=$(auth_curl "$base/todos")
echo "Todos list 2: $resp"
# Get id 1
resp=$(auth_curl "$base/todos/1")
echo "Get todo 1: $resp"
# Update
resp=$(auth_curl -X PUT "$base/todos/1" -d '{"completed":true}')
echo "Update todo 1: $resp"
# Delete
code=$(auth_curl -o /dev/null -w "%{http_code}" -X DELETE "$base/todos/1")
[[ "$code" == "204" ]] || { echo "Expected 204, got $code"; exit 1; }
# Get after delete 404
code=$(auth_curl -o /dev/null -w "%{http_code}" "$base/todos/1")
[[ "$code" == "404" ]] || { echo "Expected 404, got $code"; exit 1; }

# Logout
code=$(auth_curl -o /dev/null -w "%{http_code}" -X POST "$base/logout")
[[ "$code" == "200" ]] || { echo "Expected 200, got $code"; exit 1; }
# Authenticated actions should now be 401
code=$(auth_curl -o /dev/null -w "%{http_code}" "$base/me")
[[ "$code" == "401" ]] || { echo "Expected 401 after logout, got $code"; exit 1; }

echo "All tests passed."
