#!/usr/bin/env bash
set -euo pipefail
PORT=18080
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() { kill $SERVER_PID || true; }
trap cleanup EXIT
# wait for server
for i in {1..60}; do
  if curl -sS -o /dev/null "http://127.0.0.1:$PORT/me"; then break; fi
  sleep 0.2
done

base=http://127.0.0.1:$PORT
cookiejar=$(mktemp)

get_ct() {
  awk 'BEGIN{RS="\r\n\r\n"} NR==1{print}' | tr -d '\r' | grep -i '^content-type:' | head -n1 | cut -d' ' -f2
}

# register
resp=$(curl -s -D - -o /dev/stdout -X POST "$base/register" -H 'Content-Type: application/json' --data '{"username":"alice","password":"password123"}')
ct=$(echo "$resp" | get_ct)
body=$(echo "$resp" | awk 'BEGIN{RS="\r\n\r\n"} NR==2{print}')
[[ "$ct" == "application/json" ]] || { echo "CT register $ct"; exit 1; }
[[ $(echo "$body" | jq -r '.username') == "alice" ]]

# duplicate username
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/register" -H 'Content-Type: application/json' --data '{"username":"alice","password":"password123"}')
[[ "$code" == "409" ]]

# login wrong
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/login" -H 'Content-Type: application/json' --data '{"username":"alice","password":"wrong"}')
[[ "$code" == "401" ]]

# login ok
resp=$(curl -s -D - -c "$cookiejar" -o /dev/stdout -X POST "$base/login" -H 'Content-Type: application/json' --data '{"username":"alice","password":"password123"}')
ct=$(echo "$resp" | get_ct)
[[ "$ct" == "application/json" ]] || { echo "CT login $ct"; exit 1; }

# me
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' "$base/me")
[[ "$code" == "200" ]]

# change password wrong old
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' -X PUT "$base/password" -H 'Content-Type: application/json' --data '{"old_password":"bad","new_password":"newpassword"}')
[[ "$code" == "401" ]]
# change password too short
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' -X PUT "$base/password" -H 'Content-Type: application/json' --data '{"old_password":"password123","new_password":"short"}')
[[ "$code" == "400" ]]
# change password ok
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' -X PUT "$base/password" -H 'Content-Type: application/json' --data '{"old_password":"password123","new_password":"newpassword"}')
[[ "$code" == "200" ]]

# create todo validations
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' -X POST "$base/todos" -H 'Content-Type: application/json' --data '{"title":"","description":"d"}')
[[ "$code" == "400" ]]
# create todo ok
todo=$(curl -s -b "$cookiejar" -X POST "$base/todos" -H 'Content-Type: application/json' --data '{"title":"t1","description":"d1"}')
id=$(echo "$todo" | jq -r '.id')
[[ "$id" == "1" ]]

# list todos
list=$(curl -s -b "$cookiejar" "$base/todos")
[[ $(echo "$list" | jq 'length') -ge 1 ]]

# get todo
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' "$base/todos/$id")
[[ "$code" == "200" ]]

# update empty title invalid
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' -X PUT "$base/todos/$id" -H 'Content-Type: application/json' --data '{"title":""}')
[[ "$code" == "400" ]]
# update ok
up=$(curl -s -b "$cookiejar" -X PUT "$base/todos/$id" -H 'Content-Type: application/json' --data '{"completed":true}')
[[ $(echo "$up" | jq -r '.completed') == "true" ]]

# delete
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' -X DELETE "$base/todos/$id")
[[ "$code" == "204" ]]

# after delete get 404
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' "$base/todos/$id")
[[ "$code" == "404" ]]

# logout
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' -X POST "$base/logout")
[[ "$code" == "200" ]]

# access after logout -> 401
code=$(curl -s -b "$cookiejar" -o /dev/null -w '%{http_code}' "$base/me")
[[ "$code" == "401" ]]

echo "All tests passed"