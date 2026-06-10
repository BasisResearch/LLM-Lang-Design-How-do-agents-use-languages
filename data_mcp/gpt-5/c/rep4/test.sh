#!/bin/bash
set -euo pipefail

# Ensure dependencies for testing
if ! command -v jq >/dev/null 2>&1; then
  sudo apt-get update && sudo apt-get install -y jq
fi
if ! command -v curl >/dev/null 2>&1; then
  sudo apt-get update && sudo apt-get install -y curl
fi

PORT=8091
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
COOKIE_JAR2=$(mktemp)
cleanup(){ kill $(cat /tmp/server.pid.test 2>/dev/null) 2>/dev/null || true; rm -f "$COOKIE_JAR" "$COOKIE_JAR2"; }
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" >/tmp/server_test.log 2>&1 & echo $! > /tmp/server.pid.test
sleep 1

# Helper: curl with cookie jar as array to preserve header spacing
CURL=(curl -s -S -D /tmp/headers.$$ -b "$COOKIE_JAR" -c "$COOKIE_JAR" -H "Content-Type: application/json")

# 1. Register
REG=$("${CURL[@]}" -X POST "$BASE/register" --data '{"username":"user_1","password":"password123"}')
echo "REGISTER: $REG"
[[ $(echo "$REG" | jq -r .username) == "user_1" ]]

# Duplicate username -> 409
DUP_CODE=$("${CURL[@]}" -o /tmp/dup.out -w "%{http_code}" -X POST "$BASE/register" --data '{"username":"user_1","password":"anotherpass"}')
[[ "$DUP_CODE" == "409" ]]

# 2. Login
LOGIN=$("${CURL[@]}" -X POST "$BASE/login" --data '{"username":"user_1","password":"password123"}')
echo "LOGIN: $LOGIN"
[[ $(echo "$LOGIN" | jq -r .username) == "user_1" ]]

# 3. /me
ME=$("${CURL[@]}" "$BASE/me")
echo "ME: $ME"
[[ $(echo "$ME" | jq -r .username) == "user_1" ]]

# 4. Create todo
T1=$("${CURL[@]}" -X POST "$BASE/todos" --data '{"title":"Task A","description":"First"}')
echo "T1: $T1"
ID1=$(echo "$T1" | jq -r .id)

# 5. List todos
LIST=$("${CURL[@]}" "$BASE/todos")
echo "LIST: $LIST"
[[ $(echo "$LIST" | jq length) -ge 1 ]]

# 6. Get todo by id
G1=$("${CURL[@]}" "$BASE/todos/$ID1")
echo "G1: $G1"
[[ $(echo "$G1" | jq -r .title) == "Task A" ]]

# 7. Update todo
U1=$("${CURL[@]}" -X PUT "$BASE/todos/$ID1" --data '{"completed":true,"title":"Task A+"}')
echo "U1: $U1"
[[ $(echo "$U1" | jq -r .completed) == "true" ]]

# 8. Delete todo
CODE=$("${CURL[@]}" -o /tmp/del.out -w "%{http_code}" -X DELETE "$BASE/todos/$ID1")
[[ "$CODE" == "204" ]]

# 9. Get deleted -> 404
CODE=$("${CURL[@]}" -o /tmp/get404.out -w "%{http_code}" "$BASE/todos/$ID1")
[[ "$CODE" == "404" ]]

# 10. Change password
PCH=$("${CURL[@]}" -X PUT "$BASE/password" --data '{"old_password":"password123","new_password":"newpass123"}')
echo "PCH: $PCH"

# 11. Logout
LOGO=$("${CURL[@]}" -X POST "$BASE/logout")
echo "LOGOUT: $LOGO"

# 12. Check auth required after logout
CODE=$("${CURL[@]}" -o /tmp/after_logout.out -w "%{http_code}" "$BASE/me")
[[ "$CODE" == "401" ]]

# 13. Second user isolation
CURL2=(curl -s -S -D /tmp/headers2.$$ -b "$COOKIE_JAR2" -c "$COOKIE_JAR2" -H "Content-Type: application/json")
"${CURL2[@]}" -X POST "$BASE/register" --data '{"username":"user_2","password":"password123"}' >/dev/null
"${CURL2[@]}" -X POST "$BASE/login" --data '{"username":"user_2","password":"password123"}' >/dev/null
T2=$("${CURL2[@]}" -X POST "$BASE/todos" --data '{"title":"Other","description":"Second"}')
ID2=$(echo "$T2" | jq -r .id)

# Try to access other's todo with user1 (currently logged out) should 401
CODE=$("${CURL[@]}" -o /tmp/other.out -w "%{http_code}" "$BASE/todos/$ID2")
[[ "$CODE" == "401" ]]

# Login user1 with new password
LOGIN2=$("${CURL[@]}" -X POST "$BASE/login" --data '{"username":"user_1","password":"newpass123"}')
[[ $(echo "$LOGIN2" | jq -r .username) == "user_1" ]]

# Access other's todo -> 404
CODE=$("${CURL[@]}" -o /tmp/other2.out -w "%{http_code}" "$BASE/todos/$ID2")
[[ "$CODE" == "404" ]]

echo "All tests passed."