#!/usr/bin/env bash
set -euo pipefail

# find a free port
choose_port() {
  for p in $(seq 20000 21000); do
    if ! ss -ltn | awk '{print $4}' | grep -q ":$p$"; then
      echo "$p"
      return 0
    fi
  done
  echo "No free port found" >&2
  return 1
}

PORT=${PORT:-$(choose_port)}
export PORT

# ensure jq and curl exist
if ! command -v jq >/dev/null 2>&1; then
  (sudo apt-get update -y >/dev/null 2>&1 || apt-get update -y >/dev/null 2>&1) || true
  (sudo apt-get install -y jq >/dev/null 2>&1 || apt-get install -y jq >/dev/null 2>&1) || true
fi

./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID >/dev/null 2>&1 || true' EXIT
sleep 2
base="http://127.0.0.1:$PORT"

extract_cookie() { grep -i "^Set-Cookie:" | sed -E 's/Set-Cookie: ([^;]+);.*/\1/Ig' | tr -d '\r'; }

# register
reg=$(curl -sS -H 'Content-Type: application/json' -X POST "$base/register" -d '{"username":"user_one","password":"password123"}')
[[ $(echo "$reg" | jq -r .username) == "user_one" ]]

# duplicate register should 409
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$base/register" -d '{"username":"user_one","password":"password123"}')
[[ "$code" == "409" ]]

# login
login_resp=$(curl -sS -i -H 'Content-Type: application/json' -X POST "$base/login" -d '{"username":"user_one","password":"password123"}')
cookie=$(echo "$login_resp" | extract_cookie)
[[ -n "$cookie" ]]

# me
me=$(curl -sS -H "Cookie: $cookie" "$base/me")
[[ $(echo "$me" | jq -r .username) == "user_one" ]]

# password change fail with wrong old
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/password" -d '{"old_password":"wrong","new_password":"password456"}')
[[ "$code" == "401" ]]

# password change success
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/password" -d '{"old_password":"password123","new_password":"password456"}')
[[ "$code" == "200" ]]

# create todo
todo1=$(curl -sS -H 'Content-Type: application/json' -H "Cookie: $cookie" -X POST "$base/todos" -d '{"title":"First","description":"A"}')
ID1=$(echo "$todo1" | jq -r .id)

# list todos
list=$(curl -sS -H "Cookie: $cookie" "$base/todos")
[[ $(echo "$list" | jq 'length') -eq 1 ]]

# get todo
get1=$(curl -sS -H "Cookie: $cookie" "$base/todos/$ID1")
[[ $(echo "$get1" | jq -r .title) == "First" ]]

# update todo partial
upd=$(curl -sS -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/todos/$ID1" -d '{"completed":true}')
[[ $(echo "$upd" | jq -r .completed) == "true" ]]

# delete todo
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" -X DELETE "$base/todos/$ID1")
[[ "$code" == "204" ]]

# logout
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" -X POST "$base/logout")
[[ "$code" == "200" ]]

# after logout, auth endpoints should 401
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" "$base/me")
[[ "$code" == "401" ]]

echo "All tests passed."