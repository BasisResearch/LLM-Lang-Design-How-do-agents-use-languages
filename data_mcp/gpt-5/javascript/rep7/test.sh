#!/bin/sh
set -euo pipefail

PORT=43210
BASE=http://127.0.0.1:$PORT

# Start server in background
./run.sh --port $PORT >/tmp/todo_server.log 2>&1 &
PID=$!

echo "Started server PID $PID on $BASE"
# wait for server
sleep 0.5

cleanup() {
  kill $PID 2>/dev/null || true
}
trap cleanup EXIT

curl_json() {
  url=$1
  method=$2
  data=${3-}
  cookie_file=$4
  if [ -n "$data" ]; then
    curl -sS -X "$method" "$url" -H 'Content-Type: application/json' -d "$data" -b "$cookie_file" -c "$cookie_file" -D /tmp/headers.$$ -o /tmp/body.$$ 
  else
    curl -sS -X "$method" "$url" -b "$cookie_file" -c "$cookie_file" -D /tmp/headers.$$ -o /tmp/body.$$
  fi
  code=$(awk 'tolower($0) ~ /^http\// {code=$2} END{print code}' /tmp/headers.$$)
  ct=$(awk 'BEGIN{IGNORECASE=1} /^Content-Type:/ {print $2}' /tmp/headers.$$ | tr -d '\r')
  body=$(cat /tmp/body.$$)
  echo "STATUS:$code"
  echo "CT:$ct"
  echo "BODY:$body"
}

COOKIE=$(mktemp)

# 1. Register user
out=$(curl -sS -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"test_user","password":"password123"}')
echo "$out" | grep '"id"' >/dev/null

# 2. Login
out=$(curl -sS -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"test_user","password":"password123"}' -c "$COOKIE")
echo "$out" | grep '"username":"test_user"' >/dev/null

# 3. Me
out=$(curl -sS -X GET "$BASE/me" -b "$COOKIE")
echo "$out" | grep '"username":"test_user"' >/dev/null

# 4. Create todo
out=$(curl -sS -X POST "$BASE/todos" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Do it"}' -b "$COOKIE")
echo "$out" | grep '"title":"Task 1"' >/dev/null

# 5. List todos
out=$(curl -sS -X GET "$BASE/todos" -b "$COOKIE")
echo "$out" | grep '"title":"Task 1"' >/dev/null

# 6. Get todo by id 1
out=$(curl -sS -X GET "$BASE/todos/1" -b "$COOKIE")
echo "$out" | grep '"id":1' >/dev/null

# 7. Update todo
out=$(curl -sS -X PUT "$BASE/todos/1" -H 'Content-Type: application/json' -d '{"completed":true,"title":"Task 1 updated"}' -b "$COOKIE")
echo "$out" | grep '"completed":true' >/dev/null

# 8. Delete todo
code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$BASE/todos/1" -b "$COOKIE")
[ "$code" = "204" ]

# 9. Change password
out=$(curl -sS -X PUT "$BASE/password" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpass123"}' -b "$COOKIE")
echo "$out" | grep '{}' >/dev/null || true

# 10. Logout
out=$(curl -sS -X POST "$BASE/logout" -b "$COOKIE")
# 11. Me should now 401
code=$(curl -sS -o /dev/null -w "%{http_code}" -X GET "$BASE/me" -b "$COOKIE")
[ "$code" = "401" ]

echo "All tests passed"
