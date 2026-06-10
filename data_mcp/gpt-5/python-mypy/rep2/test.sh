#!/usr/bin/env bash
set -euo pipefail

PORT=8123
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"; kill "$SERVER_PID" 2>/dev/null || true' EXIT

# Start server
./run.sh --port "$PORT" &
SERVER_PID=$!
# Wait for server to start
sleep 0.5

echo "Register user"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/register")
[[ "$HTTP" == "201" ]]

# Duplicate username should 409
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/register")
[[ "$HTTP" == "409" ]]

echo "Login"
LOGIN_RESP=$(curl -s -D - -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}' "$BASE/login")
SESSION=$(echo "$LOGIN_RESP" | awk '/^Set-Cookie:/ {print $2}' | tr -d '\r' | cut -d';' -f1)
if [[ -z "$SESSION" ]]; then echo "No session cookie"; exit 1; fi
SESSION_ONLY=$(echo "$SESSION" | cut -d'=' -f2)

# Store cookie for subsequent requests
COOKIE_HEADER="Cookie: session_id=$SESSION_ONLY"

echo "Get /me"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOKIE_HEADER" "$BASE/me")
[[ "$HTTP" == "200" ]]

echo "Change password with wrong old_password -> 401"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "$COOKIE_HEADER" -X PUT -d '{"old_password":"wrong","new_password":"newpassword123"}' "$BASE/password")
[[ "$HTTP" == "401" ]]

echo "Change password valid -> 200"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "$COOKIE_HEADER" -X PUT -d '{"old_password":"password123","new_password":"newpassword123"}' "$BASE/password")
[[ "$HTTP" == "200" ]]

echo "Create todos"
RESP=$(curl -s -H 'Content-Type: application/json' -H "$COOKIE_HEADER" -d '{"title":"Task 1","description":"Desc"}' "$BASE/todos")
ID1=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
RESP=$(curl -s -H 'Content-Type: application/json' -H "$COOKIE_HEADER" -d '{"title":"Task 2"}' "$BASE/todos")
ID2=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOKIE_HEADER" "$BASE/todos")
[[ "$HTTP" == "200" ]]

HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOKIE_HEADER" "$BASE/todos/$ID1")
[[ "$HTTP" == "200" ]]

echo "Update todo partial"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "$COOKIE_HEADER" -X PUT -d '{"completed": true}' "$BASE/todos/$ID1")
[[ "$HTTP" == "200" ]]

echo "Delete todo"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOKIE_HEADER" -X DELETE "$BASE/todos/$ID2")
[[ "$HTTP" == "204" ]]

echo "Logout"
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOKIE_HEADER" -X POST "$BASE/logout")
[[ "$HTTP" == "200" ]]

# After logout, should be 401
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOKIE_HEADER" "$BASE/me")
[[ "$HTTP" == "401" ]]

echo "All tests passed."
