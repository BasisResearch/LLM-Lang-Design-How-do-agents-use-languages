#!/usr/bin/env bash
set -euo pipefail

PORT=8098
./run.sh --port "$PORT" &
SERVER_PID=$!

cleanup() {
  kill $SERVER_PID || true
}
trap cleanup EXIT

# Wait for server
for i in {1..60}; do
  if curl -sfS "http://127.0.0.1:$PORT/me" -H 'Accept: application/json' >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

base="http://127.0.0.1:$PORT"

jq() { command jq -r "$@"; }

# Register
reg_resp=$(curl -sS -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ $(echo "$reg_resp" | jq '.username') == "user_1" ]]

# Login
login_headers=$(mktemp)
login_resp=$(curl -sS -D "$login_headers" -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ $(echo "$login_resp" | jq '.username') == "user_1" ]]
COOKIE=$(grep -i '^Set-Cookie:' "$login_headers" | sed -n 's/Set-Cookie: \(session_id=[^;]*\).*/\1/p' | tr -d '\r')
if [[ -z "$COOKIE" ]]; then echo "No cookie set"; exit 1; fi

# Me
me_resp=$(curl -sS -H "Cookie: $COOKIE" "$base/me")
[[ $(echo "$me_resp" | jq '.username') == "user_1" ]]

# Password change with wrong old -> 401
bad_pw=$(curl -sS -o /dev/stderr -w "%{http_code}" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$bad_pw" == "401" ]]

# Password change success
pw_code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$pw_code" == "200" ]]

# Create todo
create_resp=$(curl -sS -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":"T1","description":"D1"}')
T1_ID=$(echo "$create_resp" | jq '.id')
[[ "$T1_ID" =~ ^[0-9]+$ ]]

# List todos
list_resp=$(curl -sS -H "Cookie: $COOKIE" "$base/todos")
[[ $(echo "$list_resp" | jq 'length') -ge 1 ]]

# Get todo
get_resp=$(curl -sS -H "Cookie: $COOKIE" "$base/todos/$T1_ID")
[[ $(echo "$get_resp" | jq '.title') == "T1" ]]

# Update todo (partial)
upd_resp=$(curl -sS -X PUT "$base/todos/$T1_ID" -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"completed":true}')
[[ $(echo "$upd_resp" | jq '.completed') == "true" ]]

# Delete todo
del_code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$base/todos/$T1_ID" -H "Cookie: $COOKIE")
[[ "$del_code" == "204" ]]

# 404 after delete
nf_code=$(curl -sS -o /dev/null -w "%{http_code}" "$base/todos/$T1_ID" -H "Cookie: $COOKIE")
[[ "$nf_code" == "404" ]]

# Logout
logout_code=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "$base/logout" -H "Cookie: $COOKIE")
[[ "$logout_code" == "200" ]]

# Access after logout -> 401
after_code=$(curl -sS -o /dev/null -w "%{http_code}" "$base/me" -H "Cookie: $COOKIE")
[[ "$after_code" == "401" ]]

echo "All tests passed"