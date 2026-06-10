#!/usr/bin/env bash
set -euo pipefail
PORT=$((15000 + RANDOM % 10000))
echo "Using PORT=$PORT"
./run.sh --port $PORT > server.log 2>&1 &
SERVER_PID=$!
cleanup() { kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true; }
trap cleanup EXIT
base="http://127.0.0.1:$PORT"
# Wait for server to be ready
for i in {1..50}; do
  if curl -sS -o /dev/null -w '%{http_code}' $base/register >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
  if [[ $i -eq 50 ]]; then echo "Server failed to start"; cat server.log || true; exit 1; fi
done
# 1. Register
reg=$(curl -sS -X POST -H 'Content-Type: application/json' -d '{"username":"user_01","password":"password123"}' $base/register)
echo REG:$reg
# 2. Login
login_resp=$(curl -i -sS -X POST -H 'Content-Type: application/json' -d '{"username":"user_01","password":"password123"}' $base/login)
echo "$login_resp" | sed -n '1,10p'
cookie_header=$(echo "$login_resp" | tr -d '\r' | awk 'tolower($0) ~ /^set-cookie:/ {print $0}' | head -n1 | sed -E 's/^[Ss]et-[Cc]ookie: *([^;]+).*/\1/')
echo COOKIE:$cookie_header
# 3. /me
me=$(curl -sS -H "Cookie: $cookie_header" $base/me)
echo ME:$me
# 4. Change password
curl -sS -X PUT -H 'Content-Type: application/json' -H "Cookie: $cookie_header" -d '{"old_password":"password123","new_password":"newpass123"}' $base/password
# 5. Create todo
create=$(curl -sS -X POST -H 'Content-Type: application/json' -H "Cookie: $cookie_header" -d '{"title":"Task 1","description":"First"}' $base/todos)
echo CREATE:$create
id=$(echo "$create" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
# 6. List todos
list=$(curl -sS -H "Cookie: $cookie_header" $base/todos)
echo LIST:$list
# 7. Get todo by id
get=$(curl -sS -H "Cookie: $cookie_header" $base/todos/$id)
echo GET:$get
# 8. Update todo
upd=$(curl -sS -X PUT -H 'Content-Type: application/json' -H "Cookie: $cookie_header" -d '{"completed":true,"title":"Task 1 updated"}' $base/todos/$id)
echo UPD:$upd
# 9. Delete todo
curl -sS -i -X DELETE -H "Cookie: $cookie_header" $base/todos/$id | head -n1
# 10. Logout
curl -sS -X POST -H "Cookie: $cookie_header" $base/logout
# 11. Auth check after logout
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie_header" $base/me)
echo POST_LOGOUT_CODE:$code
