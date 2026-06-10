#!/usr/bin/env bash
set -euo pipefail
PORT=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(('',0))
print(s.getsockname()[1])
s.close()
PY
)
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() { kill $SERVER_PID || true; }
trap cleanup EXIT
# wait server
for i in {1..100}; do
  if curl -sS "http://127.0.0.1:$PORT/doesnotexist" -o /dev/null; then
    break
  fi
  sleep 0.05
done

base="http://127.0.0.1:$PORT"
jar=$(mktemp)

# 1. Register
resp=$(curl -sS -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$resp" | python3 -c 'import sys, json; r=json.load(sys.stdin); assert r["id"]==1 and r["username"]=="user_1"'

# 2. Duplicate username
code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ "$code" == "409" ]]

# 3. Login
resp=$(curl -sS -c "$jar" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
echo "$resp" | python3 -c 'import sys, json; r=json.load(sys.stdin); assert r["username"]=="user_1"'

# 4. Me (authenticated)
resp=$(curl -sS -b "$jar" "$base/me")
echo "$resp" | python3 -c 'import sys, json; r=json.load(sys.stdin); assert r["username"]=="user_1"'

# 5. Change password with wrong old password
code=$(curl -sS -o /dev/null -w "%{http_code}" -b "$jar" -X PUT "$base/password" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$code" == "401" ]]

# 6. Change password correctly
code=$(curl -sS -o /dev/null -w "%{http_code}" -b "$jar" -X PUT "$base/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]]

# 7. Logout
code=$(curl -sS -o /dev/null -w "%{http_code}" -b "$jar" -X POST "$base/logout")
[[ "$code" == "200" ]]

# 8. Access after logout should be 401
code=$(curl -sS -o /dev/null -w "%{http_code}" -b "$jar" "$base/me")
[[ "$code" == "401" ]]

# 9. Login with new password
resp=$(curl -sS -c "$jar" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword123"}')
echo "$resp" | python3 -c 'import sys, json; r=json.load(sys.stdin); assert r["username"]=="user_1"'

# 10. Create todo (missing title)
code=$(curl -sS -o /dev/null -w "%{http_code}" -b "$jar" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"description":"desc"}')
[[ "$code" == "400" ]]

# 11. Create todo
resp=$(curl -sS -b "$jar" -X POST "$base/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Do it"}')
echo "$resp" | python3 -c 'import sys, json; r=json.load(sys.stdin); assert r["title"]=="Task 1" and r["description"]=="Do it" and r["completed"] is False'

# 12. List todos
resp=$(curl -sS -b "$jar" "$base/todos")
echo "$resp" | python3 -c 'import sys, json; arr=json.load(sys.stdin); assert isinstance(arr,list) and len(arr)==1 and arr[0]["title"]=="Task 1"; print(arr[0]["id"])' > /tmp/todo_id.txt
id=$(cat /tmp/todo_id.txt)

# 13. Get todo by id
resp=$(curl -sS -b "$jar" "$base/todos/$id")
echo "$resp" | python3 -c 'import sys, json; r=json.load(sys.stdin); assert r["id"]>0'

# 14. Update todo (partial)
resp=$(curl -sS -b "$jar" -X PUT "$base/todos/$id" -H 'Content-Type: application/json' -d '{"completed": true}')
echo "$resp" | python3 -c 'import sys, json; r=json.load(sys.stdin); assert r["completed"] is True'

# 15. Delete todo
code=$(curl -sS -o /dev/null -w "%{http_code}" -b "$jar" -X DELETE "$base/todos/$id")
[[ "$code" == "204" ]]

# 16. Get deleted todo -> 404
code=$(curl -sS -o /dev/null -w "%{http_code}" -b "$jar" "$base/todos/$id")
[[ "$code" == "404" ]]

echo "All tests passed"