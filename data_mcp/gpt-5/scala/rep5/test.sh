#!/usr/bin/env bash
set -euo pipefail
PORT=${1:-9091}
BASE="http://127.0.0.1:$PORT"

echo "Testing server on $BASE"

# Helper to extract cookie
COOKIE_FILE=$(mktemp)
trap 'rm -f "$COOKIE_FILE"' EXIT

# 1) Register
echo '1) Register'
REG=$(curl -sS -D "$COOKIE_FILE" -H 'Content-Type: application/json' -X POST "$BASE/register" -d '{"username":"alice_1","password":"password123"}')
echo "$REG" | jq . >/dev/null
ID=$(echo "$REG" | jq -r .id)
[ "$ID" != "null" ]

# 1b) Duplicate username -> 409
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/register" -d '{"username":"alice_1","password":"password123"}')
[ "$code" = "409" ]

# 2) Login
echo '2) Login'
LOGIN_HEADERS=$(mktemp)
LOGIN_BODY=$(curl -sS -D "$LOGIN_HEADERS" -H 'Content-Type: application/json' -X POST "$BASE/login" -d '{"username":"alice_1","password":"password123"}')
SESSION=$(grep -i '^Set-Cookie:' "$LOGIN_HEADERS" | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r')
[ -n "$SESSION" ]

# 3) /me without auth -> 401
code=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/me")
[ "$code" = "401" ]

# 4) /me with auth -> 200
ME=$(curl -sS -H "Cookie: session_id=$SESSION" "$BASE/me")
USER=$(echo "$ME" | jq -r .username)
[ "$USER" = "alice_1" ]

# 5) Password change invalid old -> 401
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: session_id=$SESSION" -X PUT "$BASE/password" -d '{"old_password":"wrong","new_password":"newpassword123"}')
[ "$code" = "401" ]

# 6) Password change too short -> 400
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: session_id=$SESSION" -X PUT "$BASE/password" -d '{"old_password":"password123","new_password":"short"}')
[ "$code" = "400" ]

# 7) Password change success -> 200
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: session_id=$SESSION" -X PUT "$BASE/password" -d '{"old_password":"password123","new_password":"newpassword123"}')
[ "$code" = "200" ]

# 8) Login with old password -> 401
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" -d '{"username":"alice_1","password":"password123"}')
[ "$code" = "401" ]

# 9) Login with new password -> 200 + cookie
HEADERS=$(mktemp)
BODY=$(curl -sS -D "$HEADERS" -H 'Content-Type: application/json' -X POST "$BASE/login" -d '{"username":"alice_1","password":"newpassword123"}')
SESSION=$(grep -i '^Set-Cookie:' "$HEADERS" | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r')
[ -n "$SESSION" ]

# 10) Create todo without title -> 400
code=$(curl -sS -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: session_id=$SESSION" -X POST "$BASE/todos" -d '{"title":"   ","description":"d"}')
[ "$code" = "400" ]

# 11) Create todo -> 201
TODO=$(curl -sS -H 'Content-Type: application/json' -H "Cookie: session_id=$SESSION" -X POST "$BASE/todos" -d '{"title":"Task1","description":"Desc"}')
TID=$(echo "$TODO" | jq -r .id)
[ "$TID" != "null" ]

# 12) List todos -> contains 1
LST=$(curl -sS -H "Cookie: session_id=$SESSION" "$BASE/todos")
COUNT=$(echo "$LST" | jq 'length')
[ "$COUNT" = "1" ]

# 13) Get todo -> 200
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: session_id=$SESSION" "$BASE/todos/$TID")
[ "$code" = "200" ]

# 14) Update todo partial -> 200
UPD=$(curl -sS -H 'Content-Type: application/json' -H "Cookie: session_id=$SESSION" -X PUT "$BASE/todos/$TID" -d '{"completed":true}')
C=$(echo "$UPD" | jq -r .completed)
[ "$C" = "true" ]

# 15) Delete todo -> 204
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: session_id=$SESSION" -X DELETE "$BASE/todos/$TID")
[ "$code" = "204" ]

# 16) Get deleted -> 404
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: session_id=$SESSION" "$BASE/todos/$TID")
[ "$code" = "404" ]

# 17) Logout -> 200 and token invalidated
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: session_id=$SESSION" -X POST "$BASE/logout")
[ "$code" = "200" ]

# 18) Auth after logout -> 401
code=$(curl -sS -o /dev/null -w "%{http_code}" -H "Cookie: session_id=$SESSION" "$BASE/me")
[ "$code" = "401" ]

echo "All tests passed"