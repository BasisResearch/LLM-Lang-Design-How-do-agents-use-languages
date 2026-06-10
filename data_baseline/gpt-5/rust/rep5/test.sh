#!/usr/bin/env bash
set -euo pipefail
PORT=18123
./run.sh --port "$PORT" &
PID=$!
sleep 1
base="http://127.0.0.1:$PORT"
json(){ jq -c .; }
err(){ echo "Test failed: $1"; kill $PID || true; exit 1; }

cookiejar=$(mktemp)
trap 'kill $PID 2>/dev/null || true; rm -f "$cookiejar"' EXIT

# All responses should be JSON except DELETE 204
ct(){ [[ "$1" == *"application/json"* ]]; }

# Register
reg=$(curl -s -D - -o /tmp/body1 -X POST "$base/register" -H 'Content-Type: application/json' --data '{"username":"user_1","password":"password123"}')
code=$(echo "$reg" | head -n1 | awk '{print $2}')
cth=$(echo "$reg" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1}/^Content-Type:/{print tolower($0)}')
body=$(cat /tmp/body1)
[[ "$code" == "201" ]] || err "register code $code"
ct "$cth" || err "register content-type"
echo "$body" | jq -e '.id==1 and .username=="user_1"' >/dev/null || err "register body"

# Duplicate
reg2=$(curl -s -D - -o /tmp/body2 -X POST "$base/register" -H 'Content-Type: application/json' --data '{"username":"user_1","password":"password123"}')
code=$(echo "$reg2" | head -n1 | awk '{print $2}')
[[ "$code" == "409" ]] || err "register duplicate"

# Login
login=$(curl -s -D - -o /tmp/body3 -c "$cookiejar" -X POST "$base/login" -H 'Content-Type: application/json' --data '{"username":"user_1","password":"password123"}')
code=$(echo "$login" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]] || err "login code"
cat "$cookiejar" | grep -q session_id || err "no session cookie"

# Auth required on /me
me=$(curl -s -D - -o /tmp/body4 -b "$cookiejar" "$base/me")
code=$(echo "$me" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]] || err "/me code"

# Create todo
create=$(curl -s -D - -o /tmp/body5 -b "$cookiejar" -H 'Content-Type: application/json' -X POST "$base/todos" --data '{"title":"Task 1","description":"desc"}')
code=$(echo "$create" | head -n1 | awk '{print $2}')
[[ "$code" == "201" ]] || err "create todo code"

echo "Created: $(cat /tmp/body5)"

# List
list=$(curl -s -D - -o /tmp/body6 -b "$cookiejar" "$base/todos")
code=$(echo "$list" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]] || err "list code"

# Get by id
get=$(curl -s -D - -o /tmp/body7 -b "$cookiejar" "$base/todos/1")
code=$(echo "$get" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]] || err "get code"

# Update
upd=$(curl -s -D - -o /tmp/body8 -b "$cookiejar" -H 'Content-Type: application/json' -X PUT "$base/todos/1" --data '{"completed":true}')
code=$(echo "$upd" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]] || err "update code"

# Delete
del=$(curl -s -D - -o /tmp/body9 -b "$cookiejar" -X DELETE "$base/todos/1")
code=$(echo "$del" | head -n1 | awk '{print $2}')
[[ "$code" == "204" ]] || err "delete code"

# Ensure 404 after delete
get2=$(curl -s -D - -o /tmp/body10 -b "$cookiejar" "$base/todos/1")
code=$(echo "$get2" | head -n1 | awk '{print $2}')
[[ "$code" == "404" ]] || err "get after delete code"

# Change password
pwd=$(curl -s -D - -o /tmp/body11 -b "$cookiejar" -H 'Content-Type: application/json' -X PUT "$base/password" --data '{"old_password":"password123","new_password":"newpassword"}')
code=$(echo "$pwd" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]] || err "password change code"

# Logout
logout=$(curl -s -D - -o /tmp/body12 -b "$cookiejar" -X POST "$base/logout")
code=$(echo "$logout" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]] || err "logout code"

# Auth should now fail
me2=$(curl -s -D - -o /tmp/body13 -b "$cookiejar" "$base/me")
code=$(echo "$me2" | head -n1 | awk '{print $2}')
[[ "$code" == "401" ]] || err "auth after logout should fail"

echo "All tests passed"
kill $PID
