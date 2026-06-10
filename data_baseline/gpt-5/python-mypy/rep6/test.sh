#!/bin/bash
set -euo pipefail
set -x
PORT=$(shuf -i 20000-39999 -n1)
./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
# Wait for server to listen
for i in {1..50}; do
  if curl -s "http://127.0.0.1:$PORT/does-not-exist" -o /dev/null; then break; fi
  sleep 0.1
done
base=http://127.0.0.1:$PORT

# Register should be 201
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ "$code" == "201" ]]

# Duplicate register should 409
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ "$code" == "409" ]]

# Login get cookie
login_headers=$(mktemp)
login_body=$(curl -s -D "$login_headers" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
code=$(awk 'NR==1{print $2}' "$login_headers")
cat "$login_headers"
[[ "$code" == "200" ]]
cookie=$(awk -F': ' '/^Set-Cookie:/ {print $2}' "$login_headers" | tr -d '\r' | head -n1)
echo "Cookie: $cookie"
rm -f "$login_headers"

# /me requires auth
code=$(curl -s -o /dev/null -w "%{http_code}" "$base/me" -H "Cookie: $cookie")
[[ "$code" == "200" ]]

# Change password wrong old -> 401
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$code" == "401" ]]
# Change password good -> 200
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]]

# Create todo -> 201 and capture id
create_pair=$(curl -s -w "\n%{http_code}" -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"title":"Task 1","description":"Desc"}')
echo "$create_pair"
create_code=$(echo "$create_pair" | tail -n1)
body_create=$(echo "$create_pair" | sed '$d')
[[ "$create_code" == "201" ]]
id=$(echo "$body_create" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read().strip())["id"])')

echo "Created todo id: $id"

# List todos -> 200 and contains created id
list_pair=$(curl -s -w "\n%{http_code}" "$base/todos" -H "Cookie: $cookie")
list_code=$(echo "$list_pair" | tail -n1)
list_body=$(echo "$list_pair" | sed '$d')
[[ "$list_code" == "200" ]]
echo "$list_body" | python3 - "$id" <<'PY'
import sys, json
body = sys.stdin.read().strip()
arr = json.loads(body)
pid = int(sys.argv[1])
assert any(t['id']==pid for t in arr)
print('ok')
PY

# Get todo by id -> 200
get_code=$(curl -s -o /dev/null -w "%{http_code}" "$base/todos/$id" -H "Cookie: $cookie")
[[ "$get_code" == "200" ]]

# Update todo -> 200 and completed true
upd_pair=$(curl -s -w "\n%{http_code}" -X PUT "$base/todos/$id" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"completed":true}')
upd_code=$(echo "$upd_pair" | tail -n1)
upd_body=$(echo "$upd_pair" | sed '$d')
[[ "$upd_code" == "200" ]]
echo "$upd_body" | python3 - <<'PY'
import sys, json
obj = json.loads(sys.stdin.read().strip())
assert obj['completed'] is True
print('ok')
PY

# Delete todo -> 204
code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$base/todos/$id" -H "Cookie: $cookie")
[[ "$code" == "204" ]]

# After delete -> 404
code=$(curl -s -o /dev/null -w "%{http_code}" "$base/todos/$id" -H "Cookie: $cookie")
[[ "$code" == "404" ]]

# Logout -> 200
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$base/logout" -H "Cookie: $cookie")
[[ "$code" == "200" ]]

# After logout, accessing should be 401
code=$(curl -s -o /dev/null -w "%{http_code}" "$base/me" -H "Cookie: $cookie")
[[ "$code" == "401" ]]

echo "All tests passed"
kill $PID
trap - EXIT
