#!/bin/bash
set -euo pipefail
set -x
# Kill any existing server instances
pkill -f 'java -cp out TodoServer' 2>/dev/null || true

PORT=$(( 18000 + (RANDOM % 1000) ))
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true' EXIT
# wait for server up
for i in {1..100}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "http://127.0.0.1:$PORT/does_not_exist" || true)
  if [ "$code" != "000" ]; then break; fi
  sleep 0.1
done

base="http://127.0.0.1:$PORT"
CURL="curl -s -m 5"

# Register user (expect 201)
resp=$($CURL -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' "$base/register")
echo "$resp" | grep '"id"' >/dev/null

# Duplicate (expect 409)
status=$($CURL -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' "$base/register" || true)
[ "$status" = "409" ] || { echo "Expected 409 for duplicate"; exit 1; }

# Login
headers=$(mktemp)
resp=$($CURL -D "$headers" -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' "$base/login")
tr -d '\r' <"$headers" | sed -n '1,20p'
tr -d '\r' <"$headers" | grep -i '^Set-Cookie: session_id=' >/dev/null
cookie=$(tr -d '\r' <"$headers" | grep -i '^Set-Cookie: session_id=' | head -n1 | sed -E 's/Set-Cookie: (session_id=[^;]+).*/\1/I')
[ -n "$cookie" ] || { echo "No cookie"; exit 1; }

# Get /me
resp=$($CURL -H "Cookie: $cookie" "$base/me")
echo "$resp" | grep -E '"username"\s*:\s*"alice"' >/dev/null

# Change password
resp=$($CURL -X PUT -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"password123","new_password":"newpassword456"}' "$base/password")
echo "$resp" | grep '{}' >/dev/null

# Logout
resp=$($CURL -X POST -H 'Content-Type: application/json' -H "Cookie: $cookie" "$base/logout")
# Subsequent request should 401
status=$($CURL -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" "$base/me")
[ "$status" = "401" ] || { echo "Expected 401 after logout"; exit 1; }

# Login again with new password
headers2=$(mktemp)
resp=$($CURL -D "$headers2" -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"newpassword456"}' "$base/login")
cookie2=$(tr -d '\r' <"$headers2" | grep -i '^Set-Cookie: session_id=' | head -n1 | sed -E 's/Set-Cookie: (session_id=[^;]+).*/\1/I')
[ -n "$cookie2" ] || { echo "No cookie2"; exit 1; }

# Create todos
resp=$($CURL -X POST -H 'Content-Type: application/json' -H "Cookie: $cookie2" -d '{"title":"Task1","description":"Do it"}' "$base/todos")
echo "$resp" | grep '"id"' >/dev/null
resp=$($CURL -X POST -H 'Content-Type: application/json' -H "Cookie: $cookie2" -d '{"title":"Task2"}' "$base/todos")
echo "$resp" | grep '"id"' >/dev/null

# List todos
resp=$($CURL -H "Cookie: $cookie2" "$base/todos")
echo "$resp" | grep '\[' >/dev/null

# Get specific todo
resp=$($CURL -H "Cookie: $cookie2" "$base/todos/1")
echo "$resp" | grep '"title"' >/dev/null

# Update todo
resp=$($CURL -X PUT -H 'Content-Type: application/json' -H "Cookie: $cookie2" -d '{"completed":true,"description":"Done"}' "$base/todos/1")
echo "$resp" | grep -E '"completed"\s*:\s*true' >/dev/null

# Delete todo
status=$($CURL -o /dev/null -w '%{http_code}' -X DELETE -H "Cookie: $cookie2" "$base/todos/1")
[ "$status" = "204" ] || { echo "Expected 204 on delete"; exit 1; }

# Get deleted todo should be 404
status=$($CURL -o /dev/null -w '%{http_code}' -H "Cookie: $cookie2" "$base/todos/1")
[ "$status" = "404" ] || { echo "Expected 404 for deleted todo"; exit 1; }

# Unauthorized access
status=$($CURL -o /dev/null -w '%{http_code}' "$base/todos")
[ "$status" = "401" ] || { echo "Expected 401 for no auth"; exit 1; }

echo "All tests passed"