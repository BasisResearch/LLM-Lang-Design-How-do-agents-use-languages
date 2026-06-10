#!/usr/bin/env bash
set -euo pipefail
set -x
PORT=3456
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT
base="http://0.0.0.0:$PORT"
# wait for server up
for i in {1..60}; do
  if curl -s -o /dev/null "$base/me"; then
    break
  fi
  sleep 0.5
done

# Ensure JSON content-type except DELETE 204
check_content_type() {
  ct="$1"
  if [[ "$ct" != application/json* ]]; then
    echo "Invalid content-type: $ct" >&2
    exit 1
  fi
}

get_ct() {
  # reads headers from stdin and prints content-type value (2nd field)
  awk 'BEGIN{IGNORECASE=1} /^Content-Type:/{print $2; exit}'
}

uname="user_$RANDOM"
pass="password123"
newpass="newpassword123"

# 1) Register
res=$(curl -s -D - -o /tmp/body1 -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"'"$uname"'","password":"'"$pass"'"}')
code=$(echo "$res" | head -n1 | awk '{print $2}')
ct=$(echo "$res" | tr -d '\r' | get_ct)
check_content_type "$ct"
body=$(cat /tmp/body1)
[[ "$code" == "201" ]] || { echo "Register failed: $code $body"; exit 1; }
[[ "$body" == *'"username":"'"$uname"'"'* ]]

# 2) Login
res=$(curl -s -D - -o /tmp/body2 -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"'"$uname"'","password":"'"$pass"'"}')
code=$(echo "$res" | head -n1 | awk '{print $2}')
ct=$(echo "$res" | tr -d '\r' | get_ct)
check_content_type "$ct"
[[ "$code" == "200" ]] || { echo "Login failed: $code"; cat /tmp/body2; exit 1; }
cookie=$(echo "$res" | tr -d '\r' | awk 'BEGIN{IGNORECASE=1} /^Set-Cookie:/{print $2; exit}')
if [[ -z "${cookie:-}" ]]; then echo "Missing Set-Cookie"; exit 1; fi

# 3) /me should work
res=$(curl -s -D - -o /tmp/body3 -X GET "$base/me" -H "Cookie: $cookie")
code=$(echo "$res" | head -n1 | awk '{print $2}')
ct=$(echo "$res" | tr -d '\r' | get_ct)
check_content_type "$ct"
[[ "$code" == "200" ]]

# 4) password change with wrong old password
res=$(curl -s -D - -o /tmp/body4 -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"wrong","new_password":"'"$newpass"'"}')
code=$(echo "$res" | head -n1 | awk '{print $2}')
[[ "$code" == "401" ]]

# 5) password change correct
res=$(curl -s -D - -o /tmp/body5 -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"old_password":"'"$pass"'","new_password":"'"$newpass"'"}')
code=$(echo "$res" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]]

# 6) create todo
res=$(curl -s -D - -o /tmp/body6 -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"title":"Task 1","description":"First"}')
code=$(echo "$res" | head -n1 | awk '{print $2}')
ct=$(echo "$res" | tr -d '\r' | get_ct)
check_content_type "$ct"
[[ "$code" == "201" ]]
body=$(cat /tmp/body6)
id1=$(echo "$body" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')

# 7) create second todo
res=$(curl -s -D - -o /tmp/body7 -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"title":"Task 2","description":"Second"}')
code=$(echo "$res" | head -n1 | awk '{print $2}')
[[ "$code" == "201" ]]
body=$(cat /tmp/body7)
id2=$(echo "$body" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')

# 8) list todos
res=$(curl -s -D - -o /tmp/body8 -X GET "$base/todos" -H "Cookie: $cookie")
code=$(echo "$res" | head -n1 | awk '{print $2}')
ct=$(echo "$res" | tr -d '\r' | get_ct)
check_content_type "$ct"
[[ "$code" == "200" ]]

# 9) get one
res=$(curl -s -D - -o /tmp/body9 -X GET "$base/todos/$id1" -H "Cookie: $cookie")
code=$(echo "$res" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]]

# 10) partial update
res=$(curl -s -D - -o /tmp/body10 -X PUT "$base/todos/$id1" -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"completed":true}')
code=$(echo "$res" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]]

# 11) delete second todo
res=$(curl -s -D - -o /tmp/body11 -X DELETE "$base/todos/$id2" -H "Cookie: $cookie")
code=$(echo "$res" | head -n1 | awk '{print $2}')
[[ "$code" == "204" ]]
ct=$(echo "$res" | tr -d '\r' | get_ct)
if [[ -n "${ct:-}" ]]; then echo "DELETE should have no content-type"; exit 1; fi

# 12) logout
res=$(curl -s -D - -o /tmp/body12 -X POST "$base/logout" -H "Cookie: $cookie")
code=$(echo "$res" | head -n1 | awk '{print $2}')
[[ "$code" == "200" ]]

# 13) ensure session invalidated
res=$(curl -s -D - -o /tmp/body13 -X GET "$base/me" -H "Cookie: $cookie")
code=$(echo "$res" | head -n1 | awk '{print $2}')
[[ "$code" == "401" ]]

echo "All tests passed"
