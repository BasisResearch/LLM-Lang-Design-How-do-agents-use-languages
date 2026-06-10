#!/usr/bin/env bash
set -euo pipefail
PORT=3100
./run.sh --port "$PORT" >/tmp/server.out 2>&1 &
SERVER_PID=$!
cleanup() { kill $SERVER_PID || true; }
trap cleanup EXIT
sleep 0.5
base=http://127.0.0.1:$PORT
hdr=( -s -S -D - -o /dev/stderr -H 'Content-Type: application/json' )

# Helper to extract cookie
cookie_from_headers() {
  grep -i '^set-cookie:' | head -n1 | sed -E 's/.*session_id=([^;]+).*/\1/i'
}

# Register
reg=$(curl -s -S -D - -o /dev/stderr -X POST "$base/register" -H 'Content-Type: application/json' --data '{"username":"alice_1","password":"supersecret"}')

# Login
login_headers=$(curl -s -S -D - -o /dev/stderr -X POST "$base/login" -H 'Content-Type: application/json' --data '{"username":"alice_1","password":"supersecret"}')
COOKIE=$(echo "$login_headers" | cookie_from_headers)
if [[ -z "$COOKIE" ]]; then echo 'No cookie set'; exit 1; fi

# Auth-required endpoints
auth=( -H "Cookie: session_id=$COOKIE" )

# /me
curl -s -S "$base/me" "${auth[@]}" | jq -e '.username=="alice_1"' >/dev/null

# Create todos
T1=$(curl -s -S -X POST "$base/todos" "${auth[@]}" -H 'Content-Type: application/json' --data '{"title":"Task 1","description":"First"}')
T1_ID=$(echo "$T1" | jq -r '.id')
T2=$(curl -s -S -X POST "$base/todos" "${auth[@]}" -H 'Content-Type: application/json' --data '{"title":"Task 2"}')
T2_ID=$(echo "$T2" | jq -r '.id')

# List
curl -s -S "$base/todos" "${auth[@]}" | jq -e 'length==2' >/dev/null

# Get specific
curl -s -S "$base/todos/$T1_ID" "${auth[@]}" | jq -e '.title=="Task 1"' >/dev/null

# Update partial
curl -s -S -X PUT "$base/todos/$T2_ID" "${auth[@]}" -H 'Content-Type: application/json' --data '{"completed":true}' | jq -e '.completed==true' >/dev/null

# Delete
curl -s -S -X DELETE "$base/todos/$T1_ID" "${auth[@]}" -o /dev/null -w "%{http_code}" | grep -q 204

# Password change and re-login
curl -s -S -X PUT "$base/password" "${auth[@]}" -H 'Content-Type: application/json' --data '{"old_password":"supersecret","new_password":"newsupersecret"}' | jq -e 'type=="object"' >/dev/null

# Logout invalidates session
curl -s -S -X POST "$base/logout" "${auth[@]}" | jq -e 'type=="object"' >/dev/null
# Subsequent request should 401
CODE=$(curl -s -S -o /dev/null -w "%{http_code}" "$base/me" "${auth[@]}")
[[ "$CODE" == "401" ]] || { echo "Expected 401 after logout"; exit 1; }

echo "All tests passed"
