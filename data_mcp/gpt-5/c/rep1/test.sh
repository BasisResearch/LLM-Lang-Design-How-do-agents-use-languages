#!/bin/bash
set -euo pipefail
PORT=$(( 15000 + (RANDOM % 10000) ))
./run.sh --port "$PORT" &
RUN_PID=$!
# Wait for server readiness up to 10 seconds
base="http://127.0.0.1:$PORT"
jar=$(mktemp)
cleanup() {
  rm -f "$jar"
  kill "$RUN_PID" 2>/dev/null || true
}
trap cleanup EXIT

for i in {1..50}; do
  code=$(curl -sS -w "%{http_code}" -o /dev/null "$base/me" || true)
  if [[ "$code" == "401" || "$code" == "200" || "$code" == "404" ]]; then
    break
  fi
  sleep 0.2
  if [[ $i -eq 50 ]]; then
    echo "Server did not become ready" >&2
    exit 1
  fi
done

curlj() {
  curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -b "$jar" -c "$jar" "$@"
}

uname="user_$(date +%s%N | tail -c6)"
pass="password123"
# 1. Register user
resp=$(echo '{"username":"'$uname'","password":"'$pass'"}' | curlj -X POST "$base/register" --data @-)
code=$(echo "$resp" | tail -n1)
body=$(echo "$resp" | sed '$d')
[[ "$code" == "201" ]] || { echo "Register failed: $code $body"; exit 1; }

# 2. Login
resp=$(echo '{"username":"'$uname'","password":"'$pass'"}' | curlj -X POST "$base/login" --data @-)
code=$(echo "$resp" | tail -n1)
body=$(echo "$resp" | sed '$d')
[[ "$code" == "200" ]] || { echo "Login failed: $code $body"; exit 1; }

# 3. /me
resp=$(curlj "$base/me")
code=$(echo "$resp" | tail -n1)
[[ "$code" == "200" ]] || { echo "/me failed: $resp"; exit 1; }

# 4. create todo
resp=$(echo '{"title":"Task 1","description":"Desc"}' | curlj -X POST "$base/todos" --data @-)
code=$(echo "$resp" | tail -n1)
[[ "$code" == "201" ]] || { echo "Create todo failed: $resp"; exit 1; }

# 5. list todos
resp=$(curlj "$base/todos")
code=$(echo "$resp" | tail -n1)
[[ "$code" == "200" ]] || { echo "List todos failed: $resp"; exit 1; }

# 6. get todo 1
resp=$(curlj "$base/todos/1")
code=$(echo "$resp" | tail -n1)
[[ "$code" == "200" ]] || { echo "Get todo failed: $resp"; exit 1; }

# 7. update todo 1
resp=$(echo '{"completed":true}' | curlj -X PUT "$base/todos/1" --data @-)
code=$(echo "$resp" | tail -n1)
[[ "$code" == "200" ]] || { echo "Update todo failed: $resp"; exit 1; }

# 8. delete todo 1
code=$(curl -sS -w "%{http_code}" -o /dev/null -b "$jar" -c "$jar" -X DELETE "$base/todos/1")
[[ "$code" == "204" ]] || { echo "Delete todo failed: code=$code"; exit 1; }

# 9. password change
resp=$(echo '{"old_password":"'$pass'","new_password":"newpassword456"}' | curlj -X PUT "$base/password" --data @-)
code=$(echo "$resp" | tail -n1)
[[ "$code" == "200" ]] || { echo "Password change failed: $resp"; exit 1; }

# 10. logout
resp=$(curlj -X POST "$base/logout")
code=$(echo "$resp" | tail -n1)
[[ "$code" == "200" ]] || { echo "Logout failed: $resp"; exit 1; }

# 11. access after logout should be 401
code=$(curl -sS -w "%{http_code}" -o /dev/null -b "$jar" -c "$jar" "$base/me")
[[ "$code" == "401" ]] || { echo "Post-logout auth check failed: code=$code"; exit 1; }

echo "All tests passed"
