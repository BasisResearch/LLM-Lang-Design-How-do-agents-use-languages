#!/usr/bin/env bash
set -euo pipefail
PORT=8099
BASE="http://127.0.0.1:${PORT}"
COOKIE_JAR=$(mktemp)
cleanup() { rm -f "$COOKIE_JAR"; if [[ -n "${SERVER_PID-}" ]]; then kill $SERVER_PID || true; fi }
trap cleanup EXIT

chmod +x run.sh
./run.sh --port ${PORT} &
SERVER_PID=$!

# Wait for server
for i in {1..50}; do
  if curl -s -o /dev/null "${BASE}/me"; then sleep 0.1; break; fi
  sleep 0.1
done

# 1. Register
REG=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"user_1","password":"passpass"}' ${BASE}/register)
echo "Register: $REG"
# 1b. Duplicate register should 409
DUP=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"username":"user_1","password":"passpass"}' ${BASE}/register)
if [[ "$DUP" != "409" ]]; then echo "Expected 409 on duplicate register, got $DUP"; exit 1; fi

# 2. Login
LOGIN=$(curl -i -s -X POST -c "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"passpass"}' ${BASE}/login)
echo "$LOGIN" | grep -qi 'Set-Cookie: session_id='
BODY=$(echo "$LOGIN" | awk 'BEGIN{RS="\r\n\r\n"} NR==2{print}')
echo "Login body: $BODY"

# 3. Get /me (authenticated)
ME=$(curl -s -b "$COOKIE_JAR" ${BASE}/me)
echo "Me: $ME"

# 4. Create todo
TODO1=$(curl -s -b "$COOKIE_JAR" -X POST -H 'Content-Type: application/json' -d '{"title":"t1","description":"d1"}' ${BASE}/todos)
echo "Todo1: $TODO1"
ID1=$(echo "$TODO1" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')

# 5. List todos
LIST=$(curl -s -b "$COOKIE_JAR" ${BASE}/todos)
echo "List: $LIST" 

# 6. Get todo by id
GET1=$(curl -s -b "$COOKIE_JAR" ${BASE}/todos/${ID1})
echo "Get1: $GET1"

# 7. Update todo
UPD=$(curl -s -b "$COOKIE_JAR" -X PUT -H 'Content-Type: application/json' -d '{"completed":true}' ${BASE}/todos/${ID1})
echo "Updated: $UPD"

# 8. Delete todo
DEL_CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" -X DELETE ${BASE}/todos/${ID1})
if [[ "$DEL_CODE" != "204" ]]; then echo "Expected 204 on delete, got $DEL_CODE"; exit 1; fi

# 9. Confirm 404 after delete
NF=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" ${BASE}/todos/${ID1})
if [[ "$NF" != "404" ]]; then echo "Expected 404 after delete, got $NF"; exit 1; fi

# 10. Change password
CHP=$(curl -s -b "$COOKIE_JAR" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"passpass","new_password":"newpass1"}' ${BASE}/password)
echo "Change password: $CHP"

# 11. Logout
LOGOUT=$(curl -s -b "$COOKIE_JAR" -X POST ${BASE}/logout)
echo "Logout: $LOGOUT"

# 12. Auth endpoints should now 401
CODE401=$(curl -s -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" ${BASE}/me)
if [[ "$CODE401" != "401" ]]; then echo "Expected 401 after logout, got $CODE401"; exit 1; fi

echo "All tests passed."
