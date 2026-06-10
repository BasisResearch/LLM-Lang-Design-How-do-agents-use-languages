#!/usr/bin/env bash
set -euo pipefail
PORT=4567
LOG=/tmp/todo_server.log
./run.sh --port "$PORT" >"$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
base="http://127.0.0.1:$PORT"
jar1=$(mktemp)
jar2=$(mktemp)

wait_ready() {
  for i in {1..50}; do
    if curl -sS "$base/me" -o /dev/null; then
      return 0
    fi
    sleep 0.1
  done
  echo "Server not responding; log:" >&2
  tail -n +1 "$LOG" >&2 || true
  exit 1
}

# server doesn't require /me unauth, so just wait on TCP by attempting /register
for i in {1..50}; do
  if curl -sS -o /dev/null "$base/register"; then break; fi
  sleep 0.1
done

# Helper
curl_json() {
  local method="$1" path="$2" data="${3:-}" jar="$4"
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" -H 'Content-Type: application/json' -d "$data" -b "$jar" -c "$jar" "$base$path"
  else
    curl -sS -X "$method" -b "$jar" -c "$jar" "$base$path"
  fi
}

code_only() {
  local method="$1" path="$2" data="${3:-}" jar="$4"
  if [[ -n "$data" ]]; then
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" -H 'Content-Type: application/json' -d "$data" -b "$jar" -c "$jar" "$base$path"
  else
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" -b "$jar" -c "$jar" "$base$path"
  fi
}

# 1. Register user_one
resp=$(curl_json POST /register '{"username":"user_one","password":"password123"}' "$jar1")
[[ "$resp" == *'"username":"user_one"'* ]]
status=$(code_only POST /register '{"username":"user_one","password":"password123"}' "$jar1")
[[ "$status" == "409" ]]

# 2. Login wrong
status=$(code_only POST /login '{"username":"user_one","password":"wrongpass"}' "$jar1")
[[ "$status" == "401" ]]

# 3. Login correct
resp=$(curl_json POST /login '{"username":"user_one","password":"password123"}' "$jar1")
[[ "$resp" == *'"username":"user_one"'* ]]

# 4. Me
resp=$(curl_json GET /me '' "$jar1")
[[ "$resp" == *'"username":"user_one"'* ]]

# 5. Create todos
resp=$(curl_json POST /todos '{"title":"Task A","description":"Desc A"}' "$jar1")
[[ "$resp" == *'"title":"Task A"'* ]]
id1=$(echo "$resp" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
resp=$(curl_json POST /todos '{"title":"Task B"}' "$jar1")
id2=$(echo "$resp" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')

# 6. List todos
resp=$(curl_json GET /todos '' "$jar1")
[[ "$resp" == *'Task A'* && "$resp" == *'Task B'* ]]

# 7. Get by id
resp=$(curl_json GET /todos/"$id1" '' "$jar1")
[[ "$resp" == *'"title":"Task A"'* ]]

# 8. Update partial
resp=$(curl_json PUT /todos/"$id1" '{"completed":true}' "$jar1")
[[ "$resp" == *'"completed":true'* ]]

# 9. Change password
status=$(code_only PUT /password '{"old_password":"password123","new_password":"newpass456"}' "$jar1")
[[ "$status" == "200" ]]

# 10. Logout
status=$(code_only POST /logout '' "$jar1")
[[ "$status" == "200" ]]

# 11. Access after logout should 401
status=$(code_only GET /me '' "$jar1")
[[ "$status" == "401" ]]

# 12. Register second user and test 404 on other user's todo
resp=$(curl_json POST /register '{"username":"user_two","password":"password123"}' "$jar2")
resp=$(curl_json POST /login '{"username":"user_two","password":"password123"}' "$jar2")
status=$(code_only GET /todos/"$id1" '' "$jar2")
[[ "$status" == "404" ]]

# 13. Delete todo
# Need to login as user_one again
resp=$(curl_json POST /login '{"username":"user_one","password":"newpass456"}' "$jar1")
status=$(code_only DELETE /todos/"$id2" '' "$jar1")
[[ "$status" == "204" ]]

# 14. Ensure content-type for non-DELETE is application/json
ct=$(curl -sS -D - -o /dev/null -X GET -b "$jar1" -c "$jar1" "$base/todos" | tr -d '\r' | awk '/^Content-Type:/ {print $2}')
[[ "$ct" == "application/json" ]]

echo "All tests passed."
kill $PID
trap - EXIT
