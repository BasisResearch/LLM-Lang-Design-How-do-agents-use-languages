#!/bin/bash
set -euo pipefail
set -x
PORT=3456
# Clean up any prior servers on this port
pkill -f "dist/server.js --port $PORT" >/dev/null 2>&1 || true
sleep 0.2
bash ./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID >/dev/null 2>&1 || true; pkill -f "dist/server.js --port $PORT" >/dev/null 2>&1 || true' EXIT
# wait for server to accept connections
for i in {1..100}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/me || true)
  if [[ "$code" != "000" ]]; then break; fi
  sleep 0.1
done

# Register
resp=$(curl -sS -i -X POST http://127.0.0.1:$PORT/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice_1","password":"password123"}')
[[ "$resp" == *" 201 "* ]]
[[ "$resp" =~ [Cc]ontent-[Tt]ype:\ application/json ]]

# Duplicate username should 409
resp2=$(curl -sS -i -X POST http://127.0.0.1:$PORT/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice_1","password":"password123"}')
[[ "$resp2" == *" 409 "* ]]

# Login
resp=$(curl -sS -i -X POST http://127.0.0.1:$PORT/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"alice_1","password":"password123"}')
[[ "$resp" == *" 200 "* ]]
COOKIE=$(echo "$resp" | awk -F': ' '/Set-Cookie:/ {print $2}' | tr -d '\r' | head -n1)
[[ -n "$COOKIE" ]]

# Auth required endpoints should 401 without cookie
code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/me)
[[ "$code" == "401" ]]

# GET /me
code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/me -H "Cookie: ${COOKIE}")
[[ "$code" == "200" ]]

# Change password with wrong old_password
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT http://127.0.0.1:$PORT/password -H 'Content-Type: application/json' -H "Cookie: ${COOKIE}" -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$code" == "401" ]]

# Change password success
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT http://127.0.0.1:$PORT/password -H 'Content-Type: application/json' -H "Cookie: ${COOKIE}" -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]]

# Create todos
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/todos -H 'Content-Type: application/json' -H "Cookie: ${COOKIE}" -d '{"title":"Task 1","description":"Desc 1"}')
[[ "$code" == "201" ]]
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/todos -H 'Content-Type: application/json' -H "Cookie: ${COOKIE}" -d '{"title":"Task 2"}')
[[ "$code" == "201" ]]

# List todos
body=$(curl -sS http://127.0.0.1:$PORT/todos -H "Cookie: ${COOKIE}")
[[ "$body" == \[*\] ]]
[[ "$body" == *"Task 1"* ]]
[[ "$body" == *"Task 2"* ]]

# Get todo 1
code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/todos/1 -H "Cookie: ${COOKIE}")
[[ "$code" == "200" ]]

# Update todo 1 - partial
code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT http://127.0.0.1:$PORT/todos/1 -H 'Content-Type: application/json' -H "Cookie: ${COOKIE}" -d '{"completed":true}')
[[ "$code" == "200" ]]

# Delete todo 2
# Should return 204 and no body
resp=$(curl -sS -i -X DELETE http://127.0.0.1:$PORT/todos/2 -H "Cookie: ${COOKIE}")
[[ "$resp" == *" 204 "* ]]
# Ensure no body present after headers (empty or absent)
body_after=$(echo "$resp" | awk 'seen{print} /^\r$/{seen=1}')
[[ -z "$body_after" ]]

# Logout
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/logout -H "Cookie: ${COOKIE}")
[[ "$code" == "200" ]]

# After logout, requests should 401
code=$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/me -H "Cookie: ${COOKIE}")
[[ "$code" == "401" ]]

echo "All tests passed."