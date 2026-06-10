#!/usr/bin/env bash
set -euo pipefail
PORT=3456
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID || true' EXIT
sleep 1

base="http://127.0.0.1:$PORT"

json_hdr=(-H 'Content-Type: application/json')

# helper to get only http code
http_code() { curl -o /dev/null -s -w "%{http_code}" "$@"; }

# helper to capture headers and body
curl_hb() { curl -s -D - "$@"; }

extract_cookie() {
  sed -n 's/^[Ss]et-[Cc]ookie: \([^;]*\).*/\1/p' | tr -d '\r' | tail -n1
}

# 1) Register
resp=$(curl_hb -X POST "$base/register" "${json_hdr[@]}" --data '{"username":"alice_1","password":"password123"}')
echo "$resp" | grep '"id"' >/dev/null

# 2) Duplicate register -> 409
code=$(http_code -X POST "$base/register" "${json_hdr[@]}" --data '{"username":"alice_1","password":"password123"}')
[[ "$code" == "409" ]]

# 3) Login
login=$(curl_hb -X POST "$base/login" "${json_hdr[@]}" --data '{"username":"alice_1","password":"password123"}')
cookie=$(echo "$login" | extract_cookie)
[[ -n "$cookie" ]]

# 4) Me
curl -X GET "$base/me" -H "Cookie: $cookie" -s | grep '"username":"alice_1"' >/dev/null

# 5) Change password with wrong old -> 401
code=$(http_code -X PUT "$base/password" -H "Cookie: $cookie" "${json_hdr[@]}" --data '{"old_password":"wrong","new_password":"newpassword"}')
[[ "$code" == "401" ]]

# 6) Change password success
code=$(http_code -X PUT "$base/password" -H "Cookie: $cookie" "${json_hdr[@]}" --data '{"old_password":"password123","new_password":"newpassword"}')
[[ "$code" == "200" ]]

# 7) Create todo
resp=$(curl -X POST "$base/todos" -H "Cookie: $cookie" "${json_hdr[@]}" --data '{"title":"Task1","description":"Desc"}' -s)
echo "$resp" | grep '"id"' >/dev/null

# 8) List todos
curl -X GET "$base/todos" -H "Cookie: $cookie" -s | grep '"title":"Task1"' >/dev/null

# 9) Get todo id 1
curl -X GET "$base/todos/1" -H "Cookie: $cookie" -s | grep '"id":1' >/dev/null

# 10) Update todo partial
curl -X PUT "$base/todos/1" -H "Cookie: $cookie" "${json_hdr[@]}" --data '{"completed":true}' -s | grep '"completed":true' >/dev/null

# 11) Delete todo
code=$(http_code -X DELETE "$base/todos/1" -H "Cookie: $cookie")
[[ "$code" == "204" ]]

# 12) Get deleted -> 404
code=$(http_code -X GET "$base/todos/1" -H "Cookie: $cookie")
[[ "$code" == "404" ]]

# 13) Logout
curl -X POST "$base/logout" -H "Cookie: $cookie" -s | grep '{}' >/dev/null

# 14) Use old session -> 401
code=$(http_code -X GET "$base/me" -H "Cookie: $cookie")
[[ "$code" == "401" ]]

echo "All tests passed"
