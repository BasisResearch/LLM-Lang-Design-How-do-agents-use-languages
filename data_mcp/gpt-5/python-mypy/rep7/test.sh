#!/bin/bash
set -euo pipefail
PORT=8123

# Start server in background
./run.sh --port "$PORT" &
SERVER_PID=$!

cleanup() {
  kill $SERVER_PID >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep 1

base="http://127.0.0.1:$PORT"

# Helper to extract Set-Cookie header value using curl -i
get_cookie() {
  grep -i "^Set-Cookie:" | head -n1 | sed -E 's/Set-Cookie: ([^;]+);.*/\1/i'
}

# 1) Register user
resp=$(curl -s -S -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
echo "$resp" | grep '"username":"alice_1"' >/dev/null

# 2) Login
headers=$(mktemp)
body=$(mktemp)
curl -s -S -D "$headers" -o "$body" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}'
cat "$headers" | get_cookie > cookie.txt
COOKIE=$(cat cookie.txt)
SESSION_TOKEN=$(echo "$COOKIE" | cut -d'=' -f2)
if [[ -z "$SESSION_TOKEN" ]]; then echo "No session token"; exit 1; fi

# 3) /me with cookie
curl -s -S -b "$COOKIE" "$base/me" | grep '"username":"alice_1"' >/dev/null

# 4) Create todo (missing title -> 400)
code=$(curl -s -S -o /dev/null -w '%{http_code}' -b "$COOKIE" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"description":"desc"}')
[[ "$code" == "400" ]]

# 5) Create todo OK
resp=$(curl -s -S -b "$COOKIE" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"First"}')
echo "$resp" | grep '"title":"Task 1"' >/dev/null
id1=$(echo "$resp" | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')

# 6) List todos
curl -s -S -b "$COOKIE" "$base/todos" | grep '"id":' >/dev/null

# 7) Get todo id1
curl -s -S -b "$COOKIE" "$base/todos/$id1" | grep '"title":"Task 1"' >/dev/null

# 8) Update todo partial
resp=$(curl -s -S -b "$COOKIE" -X PUT "$base/todos/$id1" -H 'Content-Type: application/json' -d '{"completed": true}')
echo "$resp" | grep '"completed":true' >/dev/null

# 9) Delete todo
code=$(curl -s -S -o /dev/null -w '%{http_code}' -b "$COOKIE" -X DELETE "$base/todos/$id1")
[[ "$code" == "204" ]]

# 10) Logout
curl -s -S -b "$COOKIE" -X POST "$base/logout" | grep '{}' >/dev/null

# 11) Access after logout should 401
code=$(curl -s -S -o /dev/null -w '%{http_code}' -b "$COOKIE" "$base/me")
[[ "$code" == "401" ]]

echo "All tests passed"
