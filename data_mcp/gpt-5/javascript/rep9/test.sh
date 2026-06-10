#!/usr/bin/env bash
set -euo pipefail
PORT=4050
./run.sh --port "$PORT" &
PID=$!
cleanup() {
  kill $PID 2>/dev/null || true
}
trap cleanup EXIT
sleep 0.5
BASE="http://127.0.0.1:$PORT"

COOKIE_JAR=$(mktemp)
COOKIE_JAR2=$(mktemp)

# 0) Unauthorized /me should be 401
HTTP=$(curl -s -S -o /dev/null -w "%{http_code}" "$BASE/me")
[[ "$HTTP" == "401" ]] || { echo "Expected 401 for unauth /me, got $HTTP"; exit 1; }

# 1) Register
RESP=$(curl -s -S -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
if [[ $(echo "$RESP" | jq -r '.id') != "1" ]]; then echo "Register failed: $RESP"; exit 1; fi

# 1b) Duplicate username should 409
HTTP=$(curl -s -S -o /dev/null -w "%{http_code}" -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ "$HTTP" == "409" ]] || { echo "Expected 409 for duplicate username, got $HTTP"; exit 1; }

# 2) Login
RESP=$(curl -s -S -c "$COOKIE_JAR" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
if [[ $(echo "$RESP" | jq -r '.username') != "user_1" ]]; then echo "Login failed: $RESP"; exit 1; fi

# 3) /me
RESP=$(curl -s -S -b "$COOKIE_JAR" "$BASE/me")
if [[ $(echo "$RESP" | jq -r '.id') != "1" ]]; then echo "/me failed: $RESP"; exit 1; fi

# 3b) Change password wrong old -> 401
HTTP=$(curl -s -S -o /dev/null -w "%{http_code}" -X PUT -b "$COOKIE_JAR" "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$HTTP" == "401" ]] || { echo "Expected 401 for wrong old password, got $HTTP"; exit 1; }

# 3c) Change password correct
HTTP=$(curl -s -S -o /dev/null -w "%{http_code}" -X PUT -b "$COOKIE_JAR" "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$HTTP" == "200" ]] || { echo "Password change failed"; exit 1; }

# 4) Create todo with description
RESP=$(curl -s -S -X POST -b "$COOKIE_JAR" "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Desc"}')
ID1=$(echo "$RESP" | jq -r '.id')
[[ "$ID1" == "1" ]] || { echo "Todo create failed: $RESP"; exit 1; }

# 4b) Create todo with only title (description defaults to "")
RESP=$(curl -s -S -X POST -b "$COOKIE_JAR" "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 2"}')
ID2=$(echo "$RESP" | jq -r '.id')
[[ $(echo "$RESP" | jq -r '.description') == "" ]] || { echo "Description default failed: $RESP"; exit 1; }

# 5) List todos should be 2 ordered by id
RESP=$(curl -s -S -b "$COOKIE_JAR" "$BASE/todos")
COUNT=$(echo "$RESP" | jq 'length')
[[ "$COUNT" == "2" ]] || { echo "List failed: $RESP"; exit 1; }
FIRST_ID=$(echo "$RESP" | jq -r '.[0].id')
SECOND_ID=$(echo "$RESP" | jq -r '.[1].id')
[[ "$FIRST_ID" == "1" && "$SECOND_ID" == "2" ]] || { echo "Order by id failed: $RESP"; exit 1; }

# 6) Get todo
RESP=$(curl -s -S -b "$COOKIE_JAR" "$BASE/todos/$ID1")
[[ $(echo "$RESP" | jq -r '.title') == "Task 1" ]] || { echo "Get failed: $RESP"; exit 1; }

# 7) Update todo
RESP=$(curl -s -S -X PUT -b "$COOKIE_JAR" "$BASE/todos/$ID1" -H 'Content-Type: application/json' -d '{"completed": true}')
[[ $(echo "$RESP" | jq -r '.completed') == "true" ]] || { echo "Update failed: $RESP"; exit 1; }

# 8) Delete todo 1
HTTP=$(curl -s -S -o /dev/null -w "%{http_code}" -X DELETE -b "$COOKIE_JAR" "$BASE/todos/$ID1")
[[ "$HTTP" == "204" ]] || { echo "Delete failed: HTTP $HTTP"; exit 1; }

# 9) Logout
RESP=$(curl -s -S -X POST -b "$COOKIE_JAR" "$BASE/logout")
[[ $(echo "$RESP" | jq -r '.') == "{}" ]] || { echo "Logout failed: $RESP"; exit 1; }

# 10) Ensure session invalidated
HTTP=$(curl -s -S -o /dev/null -w "%{http_code}" -b "$COOKIE_JAR" "$BASE/me")
[[ "$HTTP" == "401" ]] || { echo "Session not invalidated"; exit 1; }

# 11) Login with OLD password should fail
HTTP=$(curl -s -S -o /dev/null -w "%{http_code}" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password123"}')
[[ "$HTTP" == "401" ]] || { echo "Expected 401 for old password login"; exit 1; }

# 12) Login with NEW password should work
RESP=$(curl -s -S -c "$COOKIE_JAR2" -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"newpassword123"}')
[[ $(echo "$RESP" | jq -r '.username') == "user_1" ]] || { echo "Login with new password failed: $RESP"; exit 1; }

# 13) Access todo 2 with new session and then delete it
RESP=$(curl -s -S -b "$COOKIE_JAR2" "$BASE/todos/$ID2")
[[ $(echo "$RESP" | jq -r '.id') == "$ID2" ]] || { echo "Get todo 2 failed: $RESP"; exit 1; }
HTTP=$(curl -s -S -o /dev/null -w "%{http_code}" -X DELETE -b "$COOKIE_JAR2" "$BASE/todos/$ID2")
[[ "$HTTP" == "204" ]] || { echo "Delete todo 2 failed: HTTP $HTTP"; exit 1; }

echo "All tests passed"