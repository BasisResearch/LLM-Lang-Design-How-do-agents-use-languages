#!/bin/bash
set -euo pipefail
PORT=8765
./run.sh --port "$PORT" &
PID=$!
cleanup() { kill $PID 2>/dev/null || true; }
trap cleanup EXIT
# wait for server
for i in {1..30}; do
  if curl -sSf "http://127.0.0.1:$PORT/" >/dev/null; then
    break
  fi
  sleep 0.2
done

base="http://127.0.0.1:$PORT"
# 1. register
resp=$(curl -sS -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
echo "$resp" | jq .
# 1b duplicate
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[[ "$code" == "409" ]]

# 2. login
headers=$(mktemp)
resp=$(curl -sS -D "$headers" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
cat "$headers"
echo "$resp" | jq .
session=$(grep -i '^set-cookie:' "$headers" | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r\n')
if [[ -z "$session" ]]; then echo "no session"; exit 1; fi
cookie="session_id=$session"

# 3. me
curl -sS -H "Cookie: $cookie" "$base/me" | jq .

# 4. create todo
resp=$(curl -sS -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"title":"Task A","description":"First"}')
echo "$resp" | jq .

# 5. list todos
curl -sS -H "Cookie: $cookie" "$base/todos" | jq .

# 6. get by id
curl -sS -H "Cookie: $cookie" "$base/todos/1" | jq .

# 7. update
curl -sS -X PUT -H 'Content-Type: application/json' -H "Cookie: $cookie" "$base/todos/1" -d '{"completed": true, "title": "Task A updated"}' | jq .

# 8. delete
code=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Cookie: $cookie" "$base/todos/1")
echo "DELETE code=$code"
[[ "$code" == "204" ]]

# 9. logout
curl -sS -X POST -H "Cookie: $cookie" "$base/logout" | jq .
# 9b. use old session should 401
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" "$base/me")
echo "after logout /me code=$code"
[[ "$code" == "401" ]]

# 10. change password flow
# login again first
headers2=$(mktemp)
resp=$(curl -sS -D "$headers2" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
session2=$(grep -i '^set-cookie:' "$headers2" | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r\n')
cookie2="session_id=$session2"
# change pw
curl -sS -X PUT -H 'Content-Type: application/json' -H "Cookie: $cookie2" "$base/password" -d '{"old_password":"password123", "new_password":"newpass123"}' | jq .
# login with old should fail
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
echo "login with old password code=$code"
[[ "$code" == "401" ]]
# login with new should succeed
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"newpass123"}')
echo "login with new password code=$code"
[[ "$code" == "200" ]]

echo "All tests passed"
