#!/bin/sh
set -eu
PORT=8099
./run.sh --port $PORT &
PID=$!
# give server time
sleep 0.5
base=localhost:$PORT

REDIR=/dev/null

# Helper for curl with JSON and cookies
curl_j() {
  curl -sS -D - -o /tmp/resp_body.txt -H 'Content-Type: application/json' "$@"
}

get_cookie() {
  grep -i '^Set-Cookie:' /tmp/resp_headers.txt | sed -n 's/Set-Cookie: \([^;]*\).*/\1/p'
}

# 1) Register user
printf 'Register...'
status=$(curl -sS -o /tmp/resp1.json -w '%{http_code}' -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' http://$base/register)
[ "$status" = "201" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

# 2) Login and capture cookie
printf 'Login...'
status=$(curl -sS -D /tmp/resp_headers.txt -o /tmp/login.json -w '%{http_code}' -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' http://$base/login)
[ "$status" = "200" ] || { echo " failed: $status"; kill $PID; exit 1; }
cookie=$(grep -i '^Set-Cookie:' /tmp/resp_headers.txt | head -n1 | sed -n 's/Set-Cookie: \([^;]*\).*/\1/p')
[ -n "$cookie" ] || { echo ' failed: no cookie'; kill $PID; exit 1; }
echo OK

# 3) /me
printf 'Me...'
status=$(curl -sS -o /tmp/me.json -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" http://$base/me)
[ "$status" = "200" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

# 4) Create todo
printf 'Create todo...'
status=$(curl -sS -o /tmp/todo1.json -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" -d '{"title":"Task 1","description":"Desc"}' http://$base/todos)
[ "$status" = "201" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

# 5) List todos
printf 'List todos...'
status=$(curl -sS -o /tmp/todos.json -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" http://$base/todos)
[ "$status" = "200" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

id=$(jq '.[0].id' /tmp/todos.json)

# 6) Get todo by id
printf 'Get todo...'
status=$(curl -sS -o /tmp/todo_get.json -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" http://$base/todos/$id)
[ "$status" = "200" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

# 7) Update todo
printf 'Update todo...'
status=$(curl -sS -o /tmp/todo_upd.json -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT -d '{"completed": true}' http://$base/todos/$id)
[ "$status" = "200" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

# 8) Change password with wrong old
printf 'Change password wrong old...'
status=$(curl -sS -o /tmp/pw1.json -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT -d '{"old_password":"bad","new_password":"newpassword1"}' http://$base/password)
[ "$status" = "401" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

# 9) Change password correct
printf 'Change password...'
status=$(curl -sS -o /tmp/pw2.json -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT -d '{"old_password":"password123","new_password":"newpassword1"}' http://$base/password)
[ "$status" = "200" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

# 10) Logout
printf 'Logout...'
status=$(curl -sS -o /tmp/logout.json -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" -X POST http://$base/logout)
[ "$status" = "200" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

# 11) Ensure cookie invalidated
printf 'Cookie invalidated...'
status=$(curl -sS -o /tmp/me2.json -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" http://$base/me)
[ "$status" = "401" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

# 12) Login with new password
printf 'Login with new password...'
status=$(curl -sS -D /tmp/resp_headers2.txt -o /tmp/login2.json -w '%{http_code}' -H 'Content-Type: application/json' -d '{"username":"alice","password":"newpassword1"}' http://$base/login)
[ "$status" = "200" ] || { echo " failed: $status"; kill $PID; exit 1; }
cookie2=$(grep -i '^Set-Cookie:' /tmp/resp_headers2.txt | head -n1 | sed -n 's/Set-Cookie: \([^;]*\).*/\1/p')
[ -n "$cookie2" ] || { echo ' failed: no cookie2'; kill $PID; exit 1; }
echo OK

# 13) Delete todo
printf 'Delete todo...'
status=$(curl -sS -o /tmp/del.txt -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie2" -X DELETE http://$base/todos/$id)
[ "$status" = "204" ] || { echo " failed: $status"; kill $PID; exit 1; }
echo OK

kill $PID
wait $PID 2>/dev/null || true

echo 'All tests passed.'
