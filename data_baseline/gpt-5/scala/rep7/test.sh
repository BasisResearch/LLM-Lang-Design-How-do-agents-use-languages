#!/usr/bin/env bash
set -euo pipefail
PORT=9097
./run.sh --port "$PORT" &
PID=$!
cleanup(){ kill $PID || true; }
trap cleanup EXIT
# Wait for server
for i in {1..60}; do
  if curl -sS localhost:"$PORT"/me -H 'Accept: application/json' -b 'session_id=invalid' >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

base=localhost:$PORT
hdr='Content-Type: application/json'

check_json(){
  jq . >/dev/null 2>&1 || { echo "Invalid JSON"; exit 1; }
}

# 1. Register
resp=$(curl -sS -X POST http://$base/register -H "$hdr" -d '{"username":"alice_1","password":"password123"}')
echo "$resp" | check_json
id=$(echo "$resp" | jq -r .id)
[[ "$id" =~ ^[0-9]+$ ]]

# 2. Duplicate register
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://$base/register -H "$hdr" -d '{"username":"alice_1","password":"password123"}')
[[ "$code" == "409" ]]

# 3. Login
cookiejar=$(mktemp)
resp=$(curl -sS -c "$cookiejar" -X POST http://$base/login -H "$hdr" -d '{"username":"alice_1","password":"password123"}')
echo "$resp" | check_json
[[ $(grep -c 'session_id' "$cookiejar") -ge 1 ]]

# 4. Me
resp=$(curl -sS -b "$cookiejar" http://$base/me)
echo "$resp" | check_json

# 5. Change password wrong old
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$cookiejar" -X PUT http://$base/password -H "$hdr" -d '{"old_password":"bad","new_password":"newpassword123"}')
[[ "$code" == "401" ]]

# 6. Change password correct
code=$(curl -sS -o /dev/null -w '%{http_code}' -b "$cookiejar" -X PUT http://$base/password -H "$hdr" -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]]

# 7. List todos empty
resp=$(curl -sS -b "$cookiejar" http://$base/todos)
echo "$resp" | jq -e 'type=="array" and length==0' >/dev/null

# 8. Create todo
resp=$(curl -sS -b "$cookiejar" -X POST http://$base/todos -H "$hdr" -d '{"title":"Task 1","description":"First"}')
echo "$resp" | check_json
todo1=$(echo "$resp" | jq -r .id)

# 9. Get todo
resp=$(curl -sS -b "$cookiejar" http://$base/todos/$todo1)
echo "$resp" | jq -e '.id==1 and .title=="Task 1"' >/dev/null

# 10. Update todo partial
resp=$(curl -sS -b "$cookiejar" -X PUT http://$base/todos/$todo1 -H "$hdr" -d '{"completed":true}')
echo "$resp" | jq -e '.completed==true' >/dev/null

# 11. Create second todo with default desc
resp=$(curl -sS -b "$cookiejar" -X POST http://$base/todos -H "$hdr" -d '{"title":"Task 2"}')
echo "$resp" | jq -e '.description==""' >/dev/null

# 12. List todos order
resp=$(curl -sS -b "$cookiejar" http://$base/todos)
echo "$resp" | jq -e '.[0].id==1 and .[1].id==2' >/dev/null

# 13. Delete todo 1
code=$(curl -sS -b "$cookiejar" -o /dev/null -w '%{http_code}' -X DELETE http://$base/todos/$todo1)
[[ "$code" == "204" ]]

# 14. Get deleted
code=$(curl -sS -b "$cookiejar" -o /dev/null -w '%{http_code}' http://$base/todos/$todo1)
[[ "$code" == "404" ]]

# 15. Logout
code=$(curl -sS -b "$cookiejar" -o /dev/null -w '%{http_code}' -X POST http://$base/logout)
[[ "$code" == "200" ]]

# 16. Ensure session invalidated
code=$(curl -sS -b "$cookiejar" -o /dev/null -w '%{http_code}' http://$base/me)
[[ "$code" == "401" ]]

echo "All tests passed."