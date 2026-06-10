#!/bin/sh
set -euo pipefail

# Pick a free port
PORT=$(python3 - "$@" <<'PY'
import socket
s=socket.socket()
s.bind(("127.0.0.1",0))
print(s.getsockname()[1])
s.close()
PY
)

./run.sh --port "$PORT" > server.log 2>&1 &
PID=$!

cleanup() {
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

base="http://127.0.0.1:$PORT"

# Wait for server ready
for i in $(seq 1 50); do
  if curl -s -o /dev/null "$base/me"; then
    break
  fi
  sleep 0.1
done

# Unique username
SUFFIX=$(python3 - <<'PY'
import os, time, random
print(f"{int(time.time())}_{random.randint(1000,9999)}")
PY
)
USERNAME="user_$SUFFIX"
PASSWORD="password123"

# 1) Register
REG=$(curl -s -S -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"'$USERNAME'","password":"'$PASSWORD'"}')
echo "REGISTER: $REG"

# 1b) Duplicate register should 409
DUP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"'$USERNAME'","password":"'$PASSWORD'"}')
[ "$DUP_CODE" = "409" ] || { echo "Expected 409 for duplicate register, got $DUP_CODE"; exit 1; }

# 2) Login and capture cookie
LOGIN_RESP=$(curl -i -s -S -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"'$USERNAME'","password":"'$PASSWORD'"}')
echo "$LOGIN_RESP" | grep -i "^Set-Cookie: session_id=" > /dev/null || { echo "No Set-Cookie"; echo "$LOGIN_RESP"; exit 1; }
COOKIE=$(echo "$LOGIN_RESP" | awk '/^Set-Cookie: session_id=/{print $2}' | tr -d '\r')
COOKIE_VAL=$(echo "$COOKIE" | cut -d';' -f1)

# 3) /me requires auth
ME=$(curl -s -S -H "Cookie: $COOKIE_VAL" "$base/me")
echo "ME: $ME"

# 4) Create todo
TODO1=$(curl -s -S -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $COOKIE_VAL" -d '{"title":"Task A","description":"Desc A"}')
echo "TODO1: $TODO1"
ID1=$(echo "$TODO1" | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')

# 5) List todos
LIST=$(curl -s -S -H "Cookie: $COOKIE_VAL" "$base/todos")
echo "LIST: $LIST"

# 6) Get todo by id
GET1=$(curl -s -S -H "Cookie: $COOKIE_VAL" "$base/todos/$ID1")
echo "GET1: $GET1"

# 7) Update todo
UPD=$(curl -s -S -X PUT "$base/todos/$ID1" -H 'Content-Type: application/json' -H "Cookie: $COOKIE_VAL" -d '{"completed": true, "title":"Task A+"}')
echo "UPD: $UPD"

# 8) Delete todo
DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$base/todos/$ID1" -H "Cookie: $COOKIE_VAL")
[ "$DEL_CODE" = "204" ] || { echo "Expected 204 delete, got $DEL_CODE"; exit 1; }

# 9) Logout
LOGOUT=$(curl -s -S -X POST "$base/logout" -H "Cookie: $COOKIE_VAL")
echo "LOGOUT: $LOGOUT"

# 10) Ensure token invalidated
CODE401=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $COOKIE_VAL" "$base/me")
[ "$CODE401" = "401" ] || { echo "Expected 401 after logout, got $CODE401"; exit 1; }

# 11) Password change flow
# Login again
LOGIN2=$(curl -i -s -S -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"'$USERNAME'","password":"'$PASSWORD'"}')
COOKIE2=$(echo "$LOGIN2" | awk '/^Set-Cookie: session_id=/{print $2}' | tr -d '\r')
COOKIE2_VAL=$(echo "$COOKIE2" | cut -d';' -f1)
# Change password
PASS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $COOKIE2_VAL" -d '{"old_password":"'$PASSWORD'","new_password":"newsecret8"}')
[ "$PASS_CODE" = "200" ] || { echo "Expected 200 password change, got $PASS_CODE"; exit 1; }
# Old password should fail
FAIL_LOGIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"'$USERNAME'","password":"'$PASSWORD'"}')
[ "$FAIL_LOGIN_CODE" = "401" ] || { echo "Expected 401 for old password, got $FAIL_LOGIN_CODE"; exit 1; }
# New password should work
OK_LOGIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"'$USERNAME'","password":"newsecret8"}')
[ "$OK_LOGIN_CODE" = "200" ] || { echo "Expected 200 for new password, got $OK_LOGIN_CODE"; exit 1; }

echo "All tests passed."
