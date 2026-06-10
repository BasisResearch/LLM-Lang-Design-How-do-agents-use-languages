#!/usr/bin/env bash
set -euo pipefail
PORT=8095
# Build and run server in background
cd "$(dirname "$0")"
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup(){ kill $SERVER_PID 2>/dev/null || true; }
trap cleanup EXIT
sleep 1
base=localhost:$PORT
# Helper to check status code and content type
check_ct(){ local ct=$(grep -i "^content-type:" -m1 | tr -d '\r' | awk '{print tolower($0)}'); echo "$ct"; }

# 1) Register
reg=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' http://$base/register)
code=$(echo "$reg" | tail -n1)
body=$(echo "$reg" | head -n -1)
[[ "$code" == "201" ]]
[[ "$(echo "$body" | jq -r .username)" == "user_1" ]]

# 1b) Register duplicate
dup=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' http://$base/register)
[[ "$(echo "$dup" | tail -n1)" == "409" ]]

# 2) Login
login_headers=$(mktemp)
login_body=$(curl -sS -D "$login_headers" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' http://$base/login)
[[ "$(grep -i "^set-cookie:" "$login_headers" | grep -c session_id=)" -ge 1 ]]
session=$(grep -i "^set-cookie:" "$login_headers" | head -n1 | sed -n 's/.*session_id=\([^;]*\).*/\1/p')

# 3) /me
me=$(curl -sS -H "Cookie: session_id=$session" http://$base/me)
[[ "$(echo "$me" | jq -r .username)" == "user_1" ]]

# 4) Change password invalid old
pc=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: session_id=$session" -X PUT -d '{"old_password":"wrong","new_password":"newpassword123"}' http://$base/password)
[[ "$pc" == "401" ]]
# 4b) Change password ok
pc2=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: session_id=$session" -X PUT -d '{"old_password":"password123","new_password":"newpassword123"}' http://$base/password)
[[ "$pc2" == "200" ]]

# 5) Todos list empty
list=$(curl -sS -H "Cookie: session_id=$session" http://$base/todos)
[[ "$list" == "[]" ]]

# 6) Create todo
create=$(curl -sS -H 'Content-Type: application/json' -H "Cookie: session_id=$session" -d '{"title":"Buy milk","description":"2L"}' http://$base/todos)
[[ "$(echo "$create" | jq -r .title)" == "Buy milk" ]]

# 7) List has 1
list2=$(curl -sS -H "Cookie: session_id=$session" http://$base/todos)
[[ "$(echo "$list2" | jq -r 'length')" == "1" ]]
id=$(echo "$list2" | jq -r '.[0].id')

# 8) Get todo
get=$(curl -sS -H "Cookie: session_id=$session" http://$base/todos/$id)
[[ "$(echo "$get" | jq -r .id)" == "$id" ]]

# 9) Update todo
upd=$(curl -sS -H 'Content-Type: application/json' -H "Cookie: session_id=$session" -X PUT -d '{"completed":true}' http://$base/todos/$id)
[[ "$(echo "$upd" | jq -r .completed)" == "true" ]]

# 10) Delete todo
code_del=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: session_id=$session" -X DELETE http://$base/todos/$id)
[[ "$code_del" == "204" ]]

# 11) Logout
logout_code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: session_id=$session" -X POST http://$base/logout)
[[ "$logout_code" == "200" ]]
# Ensure invalidated
me_after=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: session_id=$session" http://$base/me)
[[ "$me_after" == "401" ]]

echo "All tests passed."
