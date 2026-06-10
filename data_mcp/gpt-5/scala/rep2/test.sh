#!/usr/bin/env bash
set -euo pipefail

PORT=18080
SERVER_LOG=server.log
COOKIE_JAR=cookies.txt

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
  fi
  rm -f "$COOKIE_JAR" headers.txt
}
trap cleanup EXIT

./run.sh --port "$PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
echo "Started server PID $SERVER_PID on port $PORT"

# wait for server to accept connections
ok=0
for i in {1..120}; do
  if curl -sS "http://127.0.0.1:$PORT/" -o /dev/null; then
    ok=1
    break
  fi
  sleep 0.5
done
if [[ $ok -ne 1 ]]; then
  echo "Server failed to start; server log:" >&2
  tail -n +1 "$SERVER_LOG" >&2 || true
  exit 1
fi

base="http://127.0.0.1:$PORT"

uname="user_$RANDOM$RANDOM"
pass="password123"

# 1) Register
resp=$(curl -sS -H 'Content-Type: application/json' -d "{\"username\":\"$uname\",\"password\":\"$pass\"}" "$base/register")
[[ $(echo "$resp" | jq -r .username) == "$uname" ]]

# 1b) Register duplicate
status=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d "{\"username\":\"$uname\",\"password\":\"$pass\"}" "$base/register")
[[ "$status" == "409" ]]

# 2) Login wrong
status=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d "{\"username\":\"$uname\",\"password\":\"wrongpass\"}" "$base/login")
[[ "$status" == "401" ]]

# 3) Login correct and save cookies
resp=$(curl -sS -D headers.txt -c "$COOKIE_JAR" -H 'Content-Type: application/json' -d "{\"username\":\"$uname\",\"password\":\"$pass\"}" "$base/login")
[[ $(echo "$resp" | jq -r .username) == "$uname" ]]
grep -qi '^set-cookie: session_id=' headers.txt

# 4) /me
resp=$(curl -sS -b "$COOKIE_JAR" "$base/me")
[[ $(echo "$resp" | jq -r .username) == "$uname" ]]

# 5) /todos empty
resp=$(curl -sS -b "$COOKIE_JAR" "$base/todos")
[[ "$resp" == "[]" ]]

# 6) Create todos
resp1=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"t1","description":"d1"}' "$base/todos")
resp2=$(curl -sS -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"t2"}' "$base/todos")
id1=$(echo "$resp1" | jq -r .id)
id2=$(echo "$resp2" | jq -r .id)
[[ $((id2)) -eq $((id1+1)) ]]

# 7) Get todo 1
resp=$(curl -sS -b "$COOKIE_JAR" "$base/todos/$id1")
[[ $(echo "$resp" | jq -r .title) == "t1" ]]

# 8) Update todo invalid empty title
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"title":""}' "$base/todos/$id1")
[[ "$status" == "400" ]]

# 9) Update todo 1
before=$(echo "$resp" | jq -r .updated_at)
resp=$(curl -sS -b "$COOKIE_JAR" -X PUT -H 'Content-Type: application/json' -d '{"title":"new title","completed":true}' "$base/todos/$id1")
[[ $(echo "$resp" | jq -r .title) == "new title" ]]
[[ $(echo "$resp" | jq -r .completed) == "true" ]]
after=$(echo "$resp" | jq -r .updated_at)
[[ "$after" != "$before" ]]

# 10) List todos
resp=$(curl -sS -b "$COOKIE_JAR" "$base/todos")
[[ $(echo "$resp" | jq 'length') -eq 2 ]]

# 11) Delete todo 2
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X DELETE "$base/todos/$id2")
[[ "$status" == "204" ]]

# 12) Get deleted -> 404
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" "$base/todos/$id2")
[[ "$status" == "404" ]]

# 13) Logout
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X POST "$base/logout")
[[ "$status" == "200" ]]

# 14) Access after logout -> 401
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" "$base/me")
[[ "$status" == "401" ]]

# 15) Login again to change password
resp=$(curl -sS -c "$COOKIE_JAR" -H 'Content-Type: application/json' -d "{\"username\":\"$uname\",\"password\":\"$pass\"}" "$base/login")
[[ $(echo "$resp" | jq -r .username) == "$uname" ]]

# 16) Wrong old password
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword1"}' "$base/password")
[[ "$status" == "401" ]]

# 17) Too short new password
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' "$base/password")
[[ "$status" == "400" ]]

# 18) Change password
status=$(curl -sS -b "$COOKIE_JAR" -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword1"}' "$base/password")
[[ "$status" == "200" ]]

# 19) Logout
curl -sS -b "$COOKIE_JAR" -X POST "$base/logout" >/dev/null

# 20) Login with old should fail
status=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d "{\"username\":\"$uname\",\"password\":\"$pass\"}" "$base/login")
[[ "$status" == "401" ]]

# 21) Login with new should succeed
status=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d "{\"username\":\"$uname\",\"password\":\"newpassword1\"}" "$base/login")
[[ "$status" == "200" ]]

echo "All tests passed"