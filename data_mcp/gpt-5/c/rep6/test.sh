#!/bin/bash
set -euo pipefail
PORT=18080
if [[ "${1:-}" != "" ]]; then PORT="$1"; fi
./run.sh --port "$PORT" &
SERVER_PID=$!
# wait for server
for i in {1..50}; do
  if curl -s "http://127.0.0.1:$PORT/me" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
  if [[ $i -eq 50 ]]; then echo "Server did not start" >&2; kill $SERVER_PID || true; exit 1; fi
done

base="http://127.0.0.1:$PORT"

# 1) Register
resp=$(curl -s -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
echo "Register: $resp"
uid=$(echo "$resp" | jq -r '.id')
[[ "$uid" != "null" ]]

# 2) Login and capture cookie
login_resp=$(curl -i -s -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
echo "$login_resp" | sed -n '1,10p'
sess=$(echo "$login_resp" | awk -F': ' '/Set-Cookie:/ {print $2}' | tr -d '\r' | sed -n '1p' | awk -F';' '{print $1}')
[[ -n "$sess" ]]

cookie_header="$sess"

# 3) /me
me=$(curl -s -H "Cookie: $cookie_header" "$base/me")
echo "Me: $me"

# 4) Create todo
create=$(curl -s -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $cookie_header" -d '{"title":"Task 1","description":"First"}')
echo "Create: $create"
id1=$(echo "$create" | jq -r '.id')

# 5) List todos
list=$(curl -s -H "Cookie: $cookie_header" "$base/todos")
echo "List: $list"

# 6) Get todo by id
get=$(curl -s -H "Cookie: $cookie_header" "$base/todos/$id1")
echo "Get: $get"

# 7) Update todo
upd=$(curl -s -X PUT "$base/todos/$id1" -H 'Content-Type: application/json' -H "Cookie: $cookie_header" -d '{"completed":true,"title":"Task 1 updated"}')
echo "Update: $upd"

# 8) Delete todo
code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$base/todos/$id1" -H "Cookie: $cookie_header")
echo "Delete status: $code"

# 9) Logout
logout=$(curl -s -X POST "$base/logout" -H "Cookie: $cookie_header")
echo "Logout: $logout"

# 10) Access after logout should be 401
code=$(curl -s -o /dev/null -w "%{http_code}" "$base/me" -H "Cookie: $cookie_header")
echo "Me after logout status: $code"

kill $SERVER_PID || true
