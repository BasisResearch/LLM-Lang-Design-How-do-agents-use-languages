#!/usr/bin/env bash
set -euo pipefail
PORT=8099
./run.sh --port "$PORT" >/tmp/todo-server.log 2>&1 &
PID=$!
# wait until server responds
base="http://127.0.0.1:$PORT"
for i in {1..50}; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' "$base/me" || true)
  if [[ "$code" == "200" || "$code" == "401" ]]; then
    break
  fi
  sleep 0.2
done
jar=$(mktemp)
header='Content-Type: application/json'

req() {
  method=$1; path=$2; data=${3:-}
  if [[ -n "$data" ]]; then
    curl -sS -X "$method" -H "$header" -b "$jar" -c "$jar" "$base$path" -d "$data" -i
  else
    curl -sS -X "$method" -H "$header" -b "$jar" -c "$jar" "$base$path" -i
  fi
}

uname="user_$(date +%s)"
pw="password123"

# Register
echo 'Register'
resp=$(req POST /register "{\"username\":\"$uname\",\"password\":\"$pw\"}")
echo "$resp"

# Login
echo 'Login'
resp=$(req POST /login "{\"username\":\"$uname\",\"password\":\"$pw\"}")
echo "$resp"

# /me
echo 'Get me'
echo "$(req GET /me)"

# Create todos
echo 'Create todos'
r1=$(req POST /todos '{"title":"Task A","description":"Desc"}')
echo "$r1"
r2=$(req POST /todos '{"title":"Task B"}')
echo "$r2"
# Extract IDs
id1=$(echo "$r1" | tr -d '\r' | awk -F'\r?\n\r?\n' 'END{print $NF}' | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
id2=$(echo "$r2" | tr -d '\r' | awk -F'\r?\n\r?\n' 'END{print $NF}' | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
echo "IDs: $id1, $id2"

# List todos
echo "$(req GET /todos)"

# Get first todo
[[ -n "$id1" ]] && echo "$(req GET /todos/$id1)"

# Update first todo
[[ -n "$id1" ]] && echo "$(req PUT /todos/$id1 '{"completed":true,"description":"Updated"}')"

# Delete second todo
[[ -n "$id2" ]] && req DELETE /todos/$id2 || true

# Ensure deleted
[[ -n "$id2" ]] && echo "$(req GET /todos/$id2)" || true

# Change password
echo "$(req PUT /password '{"old_password":"'"$pw"'","new_password":"newpassword456"}')"

# Logout
echo "$(req POST /logout)"

# After logout should 401
req GET /me || true

kill "$PID" 2>/dev/null || true
