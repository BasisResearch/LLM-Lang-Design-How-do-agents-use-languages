#!/usr/bin/env bash
set -euo pipefail
PORT=4567
./run.sh --port "$PORT" &
PID=$!
sleep 2
base="http://127.0.0.1:$PORT"
json(){ jq -c .; }

# register
out=$(curl -s -D /tmp/headers -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' $base/register)
echo "$out" | jq . >/dev/null
if [[ $(echo "$out" | jq -r .username) != "alice" ]]; then echo "register failed"; kill $PID; exit 1; fi

# login
out=$(curl -s -D /tmp/headers -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' $base/login)
COOKIE=$(grep -i '^Set-Cookie:' /tmp/headers | sed -n 's/Set-Cookie: session_id=\([^;]*\).*/\1/p' | tr -d '\r')
if [[ -z "$COOKIE" ]]; then echo "login cookie missing"; kill $PID; exit 1; fi

# me
curl -s -H "Cookie: session_id=$COOKIE" $base/me | jq . >/dev/null

# change password wrong
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -X PUT -d '{"old_password":"bad","new_password":"newpassword123"}' $base/password)
if [[ "$code" != "401" ]]; then echo "password wrong expected 401"; kill $PID; exit 1; fi

# change password ok
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -X PUT -d '{"old_password":"password123","new_password":"newpassword123"}' $base/password)
if [[ "$code" != "200" ]]; then echo "password change failed"; kill $PID; exit 1; fi

# create todos
T1=$(curl -s -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -d '{"title":"t1","description":"d1"}' $base/todos | jq -r .id)
T2=$(curl -s -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -d '{"title":"t2"}' $base/todos | jq -r .id)

# list todos
curl -s -H "Cookie: session_id=$COOKIE" $base/todos | jq . >/dev/null

# get todo
curl -s -H "Cookie: session_id=$COOKIE" $base/todos/$T1 | jq . >/dev/null

# update todo partial
curl -s -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -X PUT -d '{"completed":true}' $base/todos/$T2 | jq . >/dev/null

# delete todo
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: session_id=$COOKIE" -X DELETE $base/todos/$T1)
if [[ "$code" != "204" ]]; then echo "delete failed"; kill $PID; exit 1; fi

# logout
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: session_id=$COOKIE" -X POST $base/logout)
if [[ "$code" != "200" ]]; then echo "logout failed"; kill $PID; exit 1; fi

# ensure session invalidated
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: session_id=$COOKIE" $base/me)
if [[ "$code" != "401" ]]; then echo "session should be invalid"; kill $PID; exit 1; fi

kill $PID
wait $PID 2>/dev/null || true
echo "All tests passed"
