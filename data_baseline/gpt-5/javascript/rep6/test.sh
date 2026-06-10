#!/usr/bin/env bash
set -euo pipefail
PORT=3456
SERVE_LOG=$(mktemp)
./run.sh --port "$PORT" >"$SERVE_LOG" 2>&1 &
PID=$!
cleanup(){ kill $PID 2>/dev/null || true; }
trap cleanup EXIT
sleep 0.5
base=http://127.0.0.1:$PORT

expect_json(){ local code="$1"; local body="$2"; local got_code="$3"; local got_body="$4";
  if [[ "$got_code" != "$code" ]]; then echo "Expected code $code got $got_code"; echo "$got_body"; exit 1; fi
  if ! jq . >/dev/null 2>&1 <<<"$got_body"; then echo "Response not JSON"; echo "$got_body"; exit 1; fi
}

# Register user
resp=$(curl -sk -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' "$base/register")
body=$(head -n -1 <<<"$resp"); code=$(tail -n1 <<<"$resp")
expect_json 201 "$body" "$code" "$body"

# Login
resp=$(curl -sk -i -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' "$base/login")
code=$(tail -n1 <<<"$resp"); headers=$(head -n -1 <<<"$resp")
if [[ "$headers" != *"Set-Cookie: session_id="* ]]; then echo "Missing Set-Cookie"; echo "$headers"; exit 1; fi
cookie=$(sed -n 's/Set-Cookie: \(session_id[^;]*\).*/\1/p' <<<"$headers" | head -n1)

# /me
resp=$(curl -sk -w "\n%{http_code}" -H 'Cookie: '$cookie "$base/me")
body=$(head -n -1 <<<"$resp"); code=$(tail -n1 <<<"$resp")
expect_json 200 "$body" "$code" "$body"

# Change password
resp=$(curl -sk -w "\n%{http_code}" -X PUT -H 'Content-Type: application/json' -H 'Cookie: '$cookie -d '{"old_password":"password123","new_password":"newpassword456"}' "$base/password")
body=$(head -n -1 <<<"$resp"); code=$(tail -n1 <<<"$resp")
expect_json 200 "$body" "$code" "$body"

# Create todo
resp=$(curl -sk -w "\n%{http_code}" -X POST -H 'Content-Type: application/json' -H 'Cookie: '$cookie -d '{"title":"Task 1","description":"First"}' "$base/todos")
body=$(head -n -1 <<<"$resp"); code=$(tail -n1 <<<"$resp")
expect_json 201 "$body" "$code" "$body"
id1=$(jq -r .id <<<"$body")

# List todos
resp=$(curl -sk -w "\n%{http_code}" -H 'Cookie: '$cookie "$base/todos")
body=$(head -n -1 <<<"$resp"); code=$(tail -n1 <<<"$resp")
expect_json 200 "$body" "$code" "$body"

# Get todo by id
resp=$(curl -sk -w "\n%{http_code}" -H 'Cookie: '$cookie "$base/todos/$id1")
body=$(head -n -1 <<<"$resp"); code=$(tail -n1 <<<"$resp")
expect_json 200 "$body" "$code" "$body"

# Update todo partial
resp=$(curl -sk -w "\n%{http_code}" -X PUT -H 'Content-Type: application/json' -H 'Cookie: '$cookie -d '{"completed":true}' "$base/todos/$id1")
body=$(head -n -1 <<<"$resp"); code=$(tail -n1 <<<"$resp")
expect_json 200 "$body" "$code" "$body"

# Delete todo
code=$(curl -sk -o /dev/null -w "%{http_code}" -X DELETE -H 'Cookie: '$cookie "$base/todos/$id1")
if [[ "$code" != 204 ]]; then echo "Expected 204 got $code"; exit 1; fi

# Logout
resp=$(curl -sk -w "\n%{http_code}" -X POST -H 'Cookie: '$cookie "$base/logout")
body=$(head -n -1 <<<"$resp"); code=$(tail -n1 <<<"$resp")
expect_json 200 "$body" "$code" "$body"

# Ensure auth fails after logout
resp=$(curl -sk -w "\n%{http_code}" -H 'Cookie: '$cookie "$base/me")
body=$(head -n -1 <<<"$resp"); code=$(tail -n1 <<<"$resp")
if [[ "$code" != 401 ]]; then echo "Expected 401 after logout got $code"; echo "$body"; exit 1; fi

echo "All tests passed"