#!/bin/bash
set -euo pipefail

pick_port() {
  for i in {1..50}; do
    P=$(shuf -i 20000-60000 -n 1)
    if ! ss -ltn | awk '{print $4}' | grep -q ":$P$"; then
      echo "$P"; return 0
    fi
  done
  echo "Failed to pick free port" >&2; exit 1
}

PORT=$(pick_port)
JAR="cookie.jar"
JAR2="cookie2.jar"
rm -f "$JAR" "$JAR2"

pkill -x server || true

bash ./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID || true' EXIT

wait_for() {
  for i in {1..100}; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/me" || true)
    if [[ "$code" != "000" ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "Server did not start on port $PORT" >&2
  exit 1
}

check_ct() {
  local method=$1; shift
  local url=$1; shift
  local data_flag=( )
  if [[ ${#@} -gt 0 ]]; then data_flag=(--data "$*"); fi
  local headers
  headers=$(mktemp)
  if [[ "$method" == "DELETE" ]]; then
    code=$(curl -s -X "$method" -D "$headers" -b "$JAR" -o /dev/null "http://127.0.0.1:$PORT$url" -w "%{http_code}")
    [[ "$code" == "204" ]] || { echo "Expected 204 for $method $url got $code"; exit 1; }
  else
    code=$(curl -s -X "$method" -H 'Content-Type: application/json' -D "$headers" -b "$JAR" -o /dev/null "http://127.0.0.1:$PORT$url" ${data_flag[@]:-} -w "%{http_code}")
    ct=$(grep -i '^Content-Type:' "$headers" | tail -n1 | tr -d '\r' | cut -d' ' -f2- | tr 'A-Z' 'a-z' | tr -d ' ')
    ct=${ct%%;*}
    [[ "$ct" == "application/json" ]] || { echo "Content-Type not application/json for $method $url: $ct"; exit 1; }
  fi
}

wait_for

# 1. /me without auth -> 401
code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/me)
[[ "$code" == "401" ]] || { echo "Expected 401 for unauth /me got $code"; exit 1; }

# 2. Register
resp=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' http://127.0.0.1:$PORT/register)
(echo "$resp" | jq -e '.id==1 and .username=="alice"') >/dev/null

# 2b. Duplicate username -> 409
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"anotherpass"}' http://127.0.0.1:$PORT/register)
[[ "$code" == "409" ]] || { echo "Expected 409 duplicate username got $code"; exit 1; }

# 3. Login wrong -> 401
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"wrong"}' http://127.0.0.1:$PORT/login)
[[ "$code" == "401" ]] || { echo "Expected 401 invalid login got $code"; exit 1; }

# 4. Login correct
resp=$(curl -s -c "$JAR" -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' http://127.0.0.1:$PORT/login)
(echo "$resp" | jq -e '.id==1 and .username=="alice"') >/dev/null

# 5. /me with auth -> 200
resp=$(curl -s -b "$JAR" http://127.0.0.1:$PORT/me)
(echo "$resp" | jq -e '.id==1 and .username=="alice"') >/dev/null

# 6. Password change validations
code=$(curl -s -b "$JAR" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword123"}' http://127.0.0.1:$PORT/password)
[[ "$code" == "401" ]] || { echo "Expected 401 wrong old password got $code"; exit 1; }
code=$(curl -s -b "$JAR" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' http://127.0.0.1:$PORT/password)
[[ "$code" == "400" ]] || { echo "Expected 400 short new password got $code"; exit 1; }

# 7. Successful password change
code=$(curl -s -b "$JAR" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}' http://127.0.0.1:$PORT/password)
[[ "$code" == "200" ]] || { echo "Expected 200 password change got $code"; exit 1; }

# 8. Logout
code=$(curl -s -b "$JAR" -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:$PORT/logout)
[[ "$code" == "200" ]] || { echo "Expected 200 logout got $code"; exit 1; }
code=$(curl -s -b "$JAR" -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/me)
[[ "$code" == "401" ]] || { echo "Expected 401 after logout got $code"; exit 1; }

# 9. Login with new password
resp=$(curl -s -c "$JAR" -X POST -H 'Content-Type: application/json' -d '{"username":"alice","password":"newpassword123"}' http://127.0.0.1:$PORT/login)
(echo "$resp" | jq -e '.id==1') >/dev/null

# 10. Todos list empty
resp=$(curl -s -b "$JAR" http://127.0.0.1:$PORT/todos)
(echo "$resp" | jq -e 'type=="array" and length==0') >/dev/null

# 11. Create todo validations
code=$(curl -s -b "$JAR" -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"title":""}' http://127.0.0.1:$PORT/todos)
[[ "$code" == "400" ]] || { echo "Expected 400 missing title got $code"; exit 1; }

# 12. Create two todos
T1=$(curl -s -b "$JAR" -X POST -H 'Content-Type: application/json' -d '{"title":"Task1","description":"Desc1"}' http://127.0.0.1:$PORT/todos)
(echo "$T1" | jq -e '.id==1 and .title=="Task1" and .completed==false') >/dev/null
sleep 1
T2=$(curl -s -b "$JAR" -X POST -H 'Content-Type: application/json' -d '{"title":"Task2"}' http://127.0.0.1:$PORT/todos)
(echo "$T2" | jq -e '.id==2 and .title=="Task2" and .description==""') >/dev/null

# 13. List todos should be ordered
LIST=$(curl -s -b "$JAR" http://127.0.0.1:$PORT/todos)
(echo "$LIST" | jq -e '.[0].id==1 and .[1].id==2') >/dev/null

# 14. Get /todos/1
ONE=$(curl -s -b "$JAR" http://127.0.0.1:$PORT/todos/1)
(echo "$ONE" | jq -e '.id==1 and .title=="Task1"') >/dev/null

# 15. Update partial
BEFORE=$(echo "$T1" | jq -r '.updated_at')
U=$(curl -s -b "$JAR" -X PUT -H 'Content-Type: application/json' -d '{"completed":true,"description":"Updated"}' http://127.0.0.1:$PORT/todos/1)
(echo "$U" | jq -e '.completed==true and .description=="Updated"') >/dev/null
AFTER=$(echo "$U" | jq -r '.updated_at')
[[ "$AFTER" != "$BEFORE" ]] || { echo "updated_at did not change"; exit 1; }

# 16. Update with empty title -> 400
code=$(curl -s -b "$JAR" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"title":""}' http://127.0.0.1:$PORT/todos/1)
[[ "$code" == "400" ]] || { echo "Expected 400 empty title got $code"; exit 1; }

# 17. Delete todo 2
check_ct DELETE /todos/2

# 18. Get deleted -> 404
code=$(curl -s -b "$JAR" -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/todos/2)
[[ "$code" == "404" ]] || { echo "Expected 404 after delete got $code"; exit 1; }

# 19. Cross-user isolation
curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"bob","password":"password123"}' http://127.0.0.1:$PORT/register >/dev/null
curl -s -c "$JAR2" -X POST -H 'Content-Type: application/json' -d '{"username":"bob","password":"password123"}' http://127.0.0.1:$PORT/login >/dev/null
code=$(curl -s -b "$JAR2" -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/todos/1)
[[ "$code" == "404" ]] || { echo "Expected 404 for other user todo got $code"; exit 1; }

# 20. Content-Type checks on a few endpoints
check_ct GET /me
check_ct POST /todos '{"title":"Another"}'
check_ct GET /todos

echo "All tests passed"