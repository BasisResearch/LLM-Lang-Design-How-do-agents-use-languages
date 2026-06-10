#!/usr/bin/env bash
set -euo pipefail
PORT=8081
ROOT_DIR=$(pwd)
COOKIE_JAR=$(mktemp)
COOKIE_JAR2=$(mktemp)
trap 'kill $(jobs -p) >/dev/null 2>&1 || true; rm -f "$COOKIE_JAR" "$COOKIE_JAR2"' EXIT

./run.sh --port "$PORT" &
SERVER_PID=$!
# wait for server
for i in {1..60}; do
  if curl -s "http://127.0.0.1:$PORT/me" -o /dev/null; then
    break
  fi
  sleep 0.5
done

echo "1) Register user1"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user1","password":"password123"}' http://127.0.0.1:$PORT/register)
[ "$HTTP" = "201" ]

echo "2) Register duplicate user1 should 409"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user1","password":"password123"}' http://127.0.0.1:$PORT/register)
[ "$HTTP" = "409" ]

echo "3) Login user1"
BODY=$(curl -s -c "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"username":"user1","password":"password123"}' http://127.0.0.1:$PORT/login)
[[ "$BODY" == *"\"username\":\"user1\""* ]]

echo "4) GET /me should succeed"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" http://127.0.0.1:$PORT/me)
[ "$HTTP" = "200" ]

echo "5) Change password with wrong old should 401"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT -d '{"old_password":"wrong","new_password":"newpassword123"}' http://127.0.0.1:$PORT/password)
[ "$HTTP" = "401" ]

echo "6) Change password correct"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT -d '{"old_password":"password123","new_password":"newpassword123"}' http://127.0.0.1:$PORT/password)
[ "$HTTP" = "200" ]

echo "7) Logout"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -X POST http://127.0.0.1:$PORT/logout)
[ "$HTTP" = "200" ]

echo "8) Access protected after logout should 401"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" http://127.0.0.1:$PORT/me)
[ "$HTTP" = "401" ]

echo "9) Login with new password"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"username":"user1","password":"newpassword123"}' http://127.0.0.1:$PORT/login)
[ "$HTTP" = "200" ]

echo "10) Create todo missing title should 400"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"description":"desc"}' http://127.0.0.1:$PORT/todos)
[ "$HTTP" = "400" ]

echo "11) Create todo ok"
BODY=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"Task1","description":"First"}' http://127.0.0.1:$PORT/todos)
ID=$(echo "$BODY" | python3 -c 'import sys, json; print(json.load(sys.stdin)["id"])')


echo "12) List todos"
BODY=$(curl -s -b "$COOKIE_JAR" http://127.0.0.1:$PORT/todos)
COUNT=$(echo "$BODY" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')
[ "$COUNT" = "1" ]

echo "13) Get todo by id"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" http://127.0.0.1:$PORT/todos/$ID)
[ "$HTTP" = "200" ]

echo "14) Update todo with empty title should 400"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT -d '{"title":""}' http://127.0.0.1:$PORT/todos/$ID)
[ "$HTTP" = "400" ]

echo "15) Update todo title and completed"
BODY=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -X PUT -d '{"title":"Task1 updated","completed":true}' http://127.0.0.1:$PORT/todos/$ID)
[[ "$BODY" == *"\"completed\":true"* ]]


echo "16) Delete todo"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" -X DELETE http://127.0.0.1:$PORT/todos/$ID)
[ "$HTTP" = "204" ]

echo "17) Get deleted todo should 404"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" http://127.0.0.1:$PORT/todos/$ID)
[ "$HTTP" = "404" ]

# cross user test

echo "18) Register user2 and ensure isolation"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user2","password":"password123"}' http://127.0.0.1:$PORT/register)
[ "$HTTP" = "201" ]
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR2" -H 'Content-Type: application/json' -d '{"username":"user2","password":"password123"}' http://127.0.0.1:$PORT/login)
[ "$HTTP" = "200" ]
BODY=$(curl -s -b "$COOKIE_JAR2" http://127.0.0.1:$PORT/todos)
COUNT=$(echo "$BODY" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')
[ "$COUNT" = "0" ]

# ensure content-type json on non-delete

echo "19) Check content-type JSON"
CT=$(curl -s -D - -o /dev/null -H 'Content-Type: application/json' -d '{"username":"zzz","password":"password123"}' http://127.0.0.1:$PORT/register | tr -d '\r' | awk -F': ' '/^Content-Type:/ {print $2}' | tail -n1)
[ "$CT" = "application/json; charset=utf-8" ] || [ "$CT" = "application/json" ]


echo "All tests passed"
