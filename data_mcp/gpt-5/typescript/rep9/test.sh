#!/usr/bin/env bash
set -euo pipefail
set -x

pick_port() {
  for i in {1..50}; do
    p=$(( ( RANDOM % 10000 )  + 30000 ))
    if ! lsof -iTCP -sTCP:LISTEN -P 2>/dev/null | grep -q ":$p "; then
      echo "$p"
      return 0
    fi
  done
  echo 34567
}

PORT=$(pick_port)
SERVER_LOG=.server_test.log
./run.sh --port "$PORT" >"$SERVER_LOG" 2>&1 &
PID=$!
cleanup() { kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; }
trap cleanup EXIT

base="http://127.0.0.1:$PORT"

wait_for_server() {
  for i in {1..100}; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$base/") || true
    if [[ "$code" =~ ^(200|404)$ ]]; then
      return 0
    fi
    sleep 0.1
  done
  echo "Server did not start" >&2
  echo "--- server log ---" >&2
  cat "$SERVER_LOG" >&2 || true
  return 1
}

wait_for_server

# Helper to extract cookie (case-insensitive)
cookie_from_headers() {
  awk 'BEGIN{IGNORECASE=1} /^Set-Cookie:/ { sub(/^Set-Cookie:[ ]*/, "", $0); print $0; exit }' | tr -d '\r' | cut -d';' -f1
}

# 1) Register
reg=$(curl -fsS -H 'Content-Type: application/json' -d '{"username":"test_user","password":"password123"}' "$base/register")
[[ $(echo "$reg" | jq -r '.username') == "test_user" ]]

# 2) Login
login_headers=$(mktemp)
login_body=$(curl -fsS -D "$login_headers" -H 'Content-Type: application/json' -d '{"username":"test_user","password":"password123"}' "$base/login")
cookie=$(cat "$login_headers" | cookie_from_headers)
[[ -n "$cookie" ]]

# 3) /me
me=$(curl -fsS -H "Cookie: $cookie" "$base/me")
[[ $(echo "$me" | jq -r '.username') == "test_user" ]]

# 4) Change password
curl -fsS -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT -d '{"old_password":"password123","new_password":"newpassword456"}' "$base/password" >/dev/null

# 5) Logout
curl -fsS -H "Cookie: $cookie" -X POST "$base/logout" >/dev/null

# Ensure session invalidated
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" "$base/me")
[[ "$code" == "401" ]]

# 6) Login with new password
login_headers2=$(mktemp)
login_body2=$(curl -fsS -D "$login_headers2" -H 'Content-Type: application/json' -d '{"username":"test_user","password":"newpassword456"}' "$base/login")
cookie2=$(cat "$login_headers2" | cookie_from_headers)

# 7) Create todo
create=$(curl -fsS -H 'Content-Type: application/json' -H "Cookie: $cookie2" -d '{"title":"Task 1","description":"First task"}' "$base/todos")
id1=$(echo "$create" | jq -r '.id')

# 8) Get todo
get1=$(curl -fsS -H "Cookie: $cookie2" "$base/todos/$id1")
[[ $(echo "$get1" | jq -r '.title') == "Task 1" ]]

# 9) Update todo (partial)
upd=$(curl -fsS -H 'Content-Type: application/json' -H "Cookie: $cookie2" -X PUT -d '{"completed":true}' "$base/todos/$id1")
[[ $(echo "$upd" | jq -r '.completed') == "true" ]]

# 10) List todos
list=$(curl -fsS -H "Cookie: $cookie2" "$base/todos")
[[ $(echo "$list" | jq 'length') -ge 1 ]]

# 11) Delete todo
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie2" -X DELETE "$base/todos/$id1")
[[ "$code" == "204" ]]

# 12) Ensure 404 on missing todo
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie2" "$base/todos/$id1")
[[ "$code" == "404" ]]

echo "All tests passed"
