#!/usr/bin/env bash
set -euo pipefail

PORT=18080
COOKIE_JAR=$(mktemp)

cleanup() {
  rm -f "$COOKIE_JAR"
  if [[ -n ${SRV_PID-} ]]; then kill $SRV_PID || true; fi
}
trap cleanup EXIT

./run.sh --port "$PORT" &
SRV_PID=$!

# wait for server to start: try a harmless POST to /login and ignore status code
for i in {1..120}; do
  if curl -sS -o /dev/null -X POST http://127.0.0.1:$PORT/login -H 'Content-Type: application/json' -d '{}'; then
    break
  fi
  sleep 0.5
done

# register
REG=$(curl -sS -X POST http://127.0.0.1:$PORT/register -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
echo "REGISTER: $REG"

# duplicate register should 409
DUP_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:$PORT/register -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[[ "$DUP_STATUS" == "409" ]] || { echo "Expected 409 on duplicate, got $DUP_STATUS"; exit 1; }

# login
LOGIN=$(curl -sS -D /tmp/headers.$$ -c $COOKIE_JAR -X POST http://127.0.0.1:$PORT/login -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
echo "LOGIN: $LOGIN"

# me
ME=$(curl -sS -b $COOKIE_JAR http://127.0.0.1:$PORT/me)
echo "ME: $ME"

# create todo
T1=$(curl -sS -b $COOKIE_JAR -H 'Content-Type: application/json' -X POST http://127.0.0.1:$PORT/todos -d '{"title":"Task 1","description":"Desc"}')
echo "CREATE TODO: $T1"
ID1=$(echo "$T1" | jq -r .id)

# list todos
LST=$(curl -sS -b $COOKIE_JAR http://127.0.0.1:$PORT/todos)
echo "LIST: $LST"

# get todo
G1=$(curl -sS -b $COOKIE_JAR http://127.0.0.1:$PORT/todos/$ID1)
echo "GET: $G1"

# update todo
U1=$(curl -sS -b $COOKIE_JAR -H 'Content-Type: application/json' -X PUT http://127.0.0.1:$PORT/todos/$ID1 -d '{"completed":true}')
echo "UPDATE: $U1"

# delete todo
DEL_STATUS=$(curl -sS -b $COOKIE_JAR -o /dev/null -w '%{http_code}' -X DELETE http://127.0.0.1:$PORT/todos/$ID1)
[[ "$DEL_STATUS" == "204" ]] || { echo "Expected 204, got $DEL_STATUS"; exit 1; }

# logout
LOGOUT=$(curl -sS -b $COOKIE_JAR -X POST http://127.0.0.1:$PORT/logout)
echo "LOGOUT: $LOGOUT"

# after logout, should 401
ME401=$(curl -sS -b $COOKIE_JAR -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/me)
[[ "$ME401" == "401" ]] || { echo "Expected 401 after logout, got $ME401"; exit 1; }

echo "All tests passed."