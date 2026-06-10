#!/usr/bin/env bash
set -euo pipefail
PORT=8100
if [[ $# -ge 2 && $1 == "--port" ]]; then PORT=$2; fi

./run.sh --port "$PORT" >/tmp/todo_srv.log 2>&1 &
SPID=$!
trap 'kill $SPID || true' EXIT
sleep 1

echo "Registering user..."
HTTP=$(curl -s -o /tmp/reg.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' http://127.0.0.1:${PORT}/register)
if [[ "$HTTP" != "201" ]]; then echo "Register failed: $HTTP"; cat /tmp/reg.json; exit 1; fi

# Duplicate register should 409
HTTP=$(curl -s -o /tmp/dup.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' http://127.0.0.1:${PORT}/register)
if [[ "$HTTP" != "409" ]]; then echo "Duplicate register code: $HTTP"; cat /tmp/dup.json; exit 1; fi

echo "Login..."
HTTP=$(curl -s -D /tmp/headers.txt -o /tmp/login.json -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' http://127.0.0.1:${PORT}/login)
if [[ "$HTTP" != "200" ]]; then echo "Login failed: $HTTP"; cat /tmp/login.json; exit 1; fi
COOKIE=$(grep -i '^Set-Cookie:' /tmp/headers.txt | sed -n 's/Set-Cookie: \(session_id=[^;]*\).*/\1/p' | head -n1)
if [[ -z "$COOKIE" ]]; then echo "Missing cookie"; exit 1; fi

# /me
echo "Me..."
HTTP=$(curl -s -o /tmp/me.json -w "%{http_code}" -H "Cookie: $COOKIE" http://127.0.0.1:${PORT}/me)
if [[ "$HTTP" != "200" ]]; then echo "/me failed: $HTTP"; cat /tmp/me.json; exit 1; fi

# Change password
HTTP=$(curl -s -o /tmp/pw.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"password123","new_password":"newpassword"}' http://127.0.0.1:${PORT}/password)
if [[ "$HTTP" != "200" ]]; then echo "Password change failed: $HTTP"; cat /tmp/pw.json; exit 1; fi

# Create todos
echo "Create todos..."
HTTP=$(curl -s -o /tmp/t1.json -w "%{http_code}" -X POST -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":"Task1","description":"First"}' http://127.0.0.1:${PORT}/todos)
if [[ "$HTTP" != "201" ]]; then echo "Create t1 failed: $HTTP"; cat /tmp/t1.json; exit 1; fi
HTTP=$(curl -s -o /tmp/t2.json -w "%{http_code}" -X POST -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":"Task2"}' http://127.0.0.1:${PORT}/todos)
if [[ "$HTTP" != "201" ]]; then echo "Create t2 failed: $HTTP"; cat /tmp/t2.json; exit 1; fi

# List
HTTP=$(curl -s -o /tmp/list.json -w "%{http_code}" -H "Cookie: $COOKIE" http://127.0.0.1:${PORT}/todos)
if [[ "$HTTP" != "200" ]]; then echo "List failed: $HTTP"; cat /tmp/list.json; exit 1; fi

ID1=$(jq -r '.[0].id' /tmp/list.json)

# Get by id
HTTP=$(curl -s -o /tmp/get1.json -w "%{http_code}" -H "Cookie: $COOKIE" http://127.0.0.1:${PORT}/todos/${ID1})
if [[ "$HTTP" != "200" ]]; then echo "Get by id failed: $HTTP"; cat /tmp/get1.json; exit 1; fi

# Update partial
HTTP=$(curl -s -o /tmp/upd.json -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"completed":true}' http://127.0.0.1:${PORT}/todos/${ID1})
if [[ "$HTTP" != "200" ]]; then echo "Update failed: $HTTP"; cat /tmp/upd.json; exit 1; fi

# Delete second
ID2=$(jq -r '.[1].id' /tmp/list.json)
HTTP=$(curl -s -o /tmp/del.out -w "%{http_code}" -X DELETE -H "Cookie: $COOKIE" http://127.0.0.1:${PORT}/todos/${ID2})
if [[ "$HTTP" != "204" ]]; then echo "Delete failed: $HTTP"; cat /tmp/del.out; exit 1; fi

# Logout
HTTP=$(curl -s -o /tmp/logout.json -w "%{http_code}" -X POST -H "Cookie: $COOKIE" http://127.0.0.1:${PORT}/logout)
if [[ "$HTTP" != "200" ]]; then echo "Logout failed: $HTTP"; cat /tmp/logout.json; exit 1; fi

# Auth should now fail
HTTP=$(curl -s -o /tmp/after.json -w "%{http_code}" -H "Cookie: $COOKIE" http://127.0.0.1:${PORT}/me)
if [[ "$HTTP" != "401" ]]; then echo "Expected 401 after logout, got: $HTTP"; cat /tmp/after.json; exit 1; fi

echo "All tests passed"
