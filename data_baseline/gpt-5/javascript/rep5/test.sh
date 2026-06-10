#!/usr/bin/env bash
set -euo pipefail

PORT=3456
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)

cleanup() {
  rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

./run.sh --port "$PORT" &
SERVER_PID=$!
# ensure server killed
trap 'kill $SERVER_PID 2>/dev/null || true; cleanup' EXIT

# wait for server
for i in {1..50}; do
  if curl -sS "$BASE/me" -D /dev/null -o /dev/null; then
    break
  fi
  sleep 0.1
done

# Helper function to curl with cookie jar and JSON header
jcurl() {
  method=$1
  url=$2
  shift 2
  curl -sS -X "$method" "$url" -H 'Content-Type: application/json' -b "$COOKIE_JAR" -c "$COOKIE_JAR" "$@"
}

# 1. Register a new user
RESP=$(jcurl POST "$BASE/register" --data '{"username":"test_user","password":"supersecret"}')
[[ $(echo "$RESP" | jq -r '.username') == "test_user" ]]

# 2. Login
RESP=$(jcurl POST "$BASE/login" --data '{"username":"test_user","password":"supersecret"}')
[[ $(echo "$RESP" | jq -r '.id') == "1" ]]

# 3. /me
RESP=$(jcurl GET "$BASE/me")
[[ $(echo "$RESP" | jq -r '.username') == "test_user" ]]

# 4. Change password
RESP=$(jcurl PUT "$BASE/password" --data '{"old_password":"supersecret","new_password":"newsupersecret"}')
[[ "$RESP" == "{}" ]]

# 5. Create todos
RESP=$(jcurl POST "$BASE/todos" --data '{"title":"First","description":"desc1"}')
ID1=$(echo "$RESP" | jq -r '.id')
RESP=$(jcurl POST "$BASE/todos" --data '{"title":"Second"}')
ID2=$(echo "$RESP" | jq -r '.id')

# 6. List todos
RESP=$(jcurl GET "$BASE/todos")
COUNT=$(echo "$RESP" | jq 'length')
[[ "$COUNT" -eq 2 ]]

# 7. Get todo by id
RESP=$(jcurl GET "$BASE/todos/$ID1")
[[ $(echo "$RESP" | jq -r '.title') == "First" ]]

# 8. Update todo partially
RESP=$(jcurl PUT "$BASE/todos/$ID1" --data '{"completed": true}')
[[ $(echo "$RESP" | jq -r '.completed') == "true" ]]

# 9. Delete todo
CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$BASE/todos/$ID2" -b "$COOKIE_JAR" -c "$COOKIE_JAR")
[[ "$CODE" -eq 204 ]]

# 10. Logout
RESP=$(jcurl POST "$BASE/logout")
[[ "$RESP" == "{}" ]]

# 11. Ensure session invalidated
CODE=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/me" -b "$COOKIE_JAR")
[[ "$CODE" -eq 401 ]]

kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo "All tests passed"
