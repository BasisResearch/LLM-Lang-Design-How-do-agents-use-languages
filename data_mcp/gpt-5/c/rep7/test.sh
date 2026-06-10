#!/bin/bash
set -euo pipefail
PORT=8099
# Build first to avoid long first-run compile within run.sh
if ! command -v gcc >/dev/null 2>&1; then
  sudo apt-get update && sudo apt-get install -y build-essential
fi
gcc -Wall -Wextra -O2 -pthread -o server main.c

# Kill any previously running server
pkill -f "./server --port $PORT" 2>/dev/null || true
pkill -x server 2>/dev/null || true
sleep 0.5

./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup(){
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

# wait for server to be ready
for i in {1..200}; do
  if curl -sS --max-time 2 "http://127.0.0.1:$PORT/unknown" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)

curlj(){
  curl --max-time 5 -sS -i -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

UNAME="alice_$(date +%s)"

# 1. Register
RESP=$(curlj -X POST "$BASE/register" --data '{"username":"'$UNAME'","password":"password123"}')
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
[[ "$STATUS" == "201" ]] || { echo "Register failed: $RESP"; exit 1; }
BODY=$(echo "$RESP" | awk '/\r$/{p=1;next} p{print}')
USER_ID=$(echo "$BODY" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
[[ "$USER_ID" =~ ^[0-9]+$ ]] || { echo "Invalid user id: $BODY"; exit 1; }

# 2. Login
RESP=$(curlj -X POST "$BASE/login" --data '{"username":"'$UNAME'","password":"password123"}')
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
[[ "$STATUS" == "200" ]] || { echo "Login failed: $RESP"; exit 1; }

# 3. /me
RESP=$(curlj "$BASE/me")
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
BODY=$(echo "$RESP" | awk '/\r$/{p=1;next} p{print}')
[[ "$STATUS" == "200" ]] || { echo "/me failed: $RESP"; exit 1; }
U=$(echo "$BODY" | sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
[[ "$U" == "$UNAME" ]] || { echo "Wrong username in /me: $BODY"; exit 1; }

# 4. Create todo
RESP=$(curlj -X POST "$BASE/todos" --data '{"title":"Task 1","description":"Desc"}')
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
BODY=$(echo "$RESP" | awk '/\r$/{p=1;next} p{print}')
[[ "$STATUS" == "201" ]] || { echo "Create todo failed: $RESP"; exit 1; }
TID=$(echo "$BODY" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')

# 5. List todos
RESP=$(curlj "$BASE/todos")
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
BODY=$(echo "$RESP" | awk '/\r$/{p=1;next} p{print}')
[[ "$STATUS" == "200" ]] || { echo "List todos failed: $RESP"; exit 1; }
[[ "$BODY" == \[*\] ]] || { echo "Todos body not array: $BODY"; exit 1; }

# 6. Get todo by id
RESP=$(curlj "$BASE/todos/$TID")
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
[[ "$STATUS" == "200" ]] || { echo "Get todo failed: $RESP"; exit 1; }

# 7. Update todo
RESP=$(curlj -X PUT "$BASE/todos/$TID" --data '{"completed":true}')
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
BODY=$(echo "$RESP" | awk '/\r$/{p=1;next} p{print}')
[[ "$STATUS" == "200" ]] || { echo "Update todo failed: $RESP"; exit 1; }
(echo "$BODY" | grep -q '"completed"[[:space:]]*:[[:space:]]*true') || { echo "Todo not updated: $BODY"; exit 1; }

# 8. Change password
RESP=$(curlj -X PUT "$BASE/password" --data '{"old_password":"password123","new_password":"newpassword456"}')
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
[[ "$STATUS" == "200" ]] || { echo "Password change failed: $RESP"; exit 1; }

# 9. Logout
RESP=$(curlj -X POST "$BASE/logout")
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
[[ "$STATUS" == "200" ]] || { echo "Logout failed: $RESP"; exit 1; }

# 10. Ensure auth required after logout
RESP=$(curlj "$BASE/me" || true)
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
[[ "$STATUS" == "401" ]] || { echo "/me after logout should be 401: $RESP"; exit 1; }

# 11. Delete todo should require auth (now logged out)
RESP=$(curlj -X DELETE "$BASE/todos/$TID" || true)
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
[[ "$STATUS" == "401" ]] || { echo "Delete without auth should be 401: $RESP"; exit 1; }

echo "All tests passed"
