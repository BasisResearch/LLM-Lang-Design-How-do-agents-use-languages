#!/usr/bin/env bash
set -euo pipefail

# Pre-compile to avoid long first-run downloads
scala-cli compile Main.scala >/dev/null 2>&1 || true

# Choose a free random port unless provided
if [[ ${1:-} == "--port" ]]; then
  PORT=${2}
else
  PORT=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()
PY
)
fi
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
SERVER_LOG=$(mktemp)
USER="user_$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
cleanup() { rm -f "$COOKIE_JAR" "$SERVER_LOG"; if [[ -n "${PID:-}" ]]; then kill $PID 2>/dev/null || true; fi }
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" >"$SERVER_LOG" 2>&1 &
PID=$!
# Wait for server (max ~20s)
for i in {1..200}; do
  if curl -sS -o /dev/null "$BASE/me"; then
    break
  fi
  sleep 0.1
done

# Register
STATUS=$(curl -s -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"'"$USER"'","password":"password123"}' -o /tmp/reg_body.json "$BASE/register")
jq . /tmp/reg_body.json >/dev/null
[[ "$STATUS" == "201" ]] || { echo "Register failed: $STATUS"; cat "$SERVER_LOG"; exit 1; }

# Duplicate register
STATUS=$(curl -s -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"'"$USER"'","password":"password123"}' -o /dev/null "$BASE/register")
[[ "$STATUS" == "409" ]] || { echo "Duplicate register expected 409: $STATUS"; exit 1; }

# Login
STATUS=$(curl -s -D /tmp/login_headers.txt -c "$COOKIE_JAR" -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"'"$USER"'","password":"password123"}' -o /tmp/login_body.json "$BASE/login")
[[ "$STATUS" == "200" ]] || { echo "Login failed: $STATUS"; cat "$SERVER_LOG"; exit 1; }
cat /tmp/login_headers.txt | grep -i 'set-cookie: session_id=' >/dev/null || { echo "No Set-Cookie"; exit 1; }

# /me
STATUS=$(curl -s -b "$COOKIE_JAR" -w "%{http_code}" -o /tmp/me_body.json "$BASE/me")
[[ "$STATUS" == "200" ]] || { echo "/me failed: $STATUS"; exit 1; }

# Create todo missing title
STATUS=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"description":"d"}' -w "%{http_code}" -o /dev/null "$BASE/todos")
[[ "$STATUS" == "400" ]] || { echo "Create todo missing title failed: $STATUS"; exit 1; }

# Create todo
STATUS=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"title":"t1","description":"d1"}' -w "%{http_code}" -o /tmp/todo1.json "$BASE/todos")
[[ "$STATUS" == "201" ]] || { echo "Create todo failed: $STATUS"; exit 1; }
ID=$(jq -r .id /tmp/todo1.json)

# List todos
STATUS=$(curl -s -b "$COOKIE_JAR" -w "%{http_code}" -o /tmp/list.json "$BASE/todos")
[[ "$STATUS" == "200" ]] || { echo "List todos failed: $STATUS"; exit 1; }

# Get todo by id
STATUS=$(curl -s -b "$COOKIE_JAR" -w "%{http_code}" -o /tmp/get.json "$BASE/todos/$ID")
[[ "$STATUS" == "200" ]] || { echo "Get todo failed: $STATUS"; exit 1; }

# Update todo partial
STATUS=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"completed":true}' -w "%{http_code}" -o /tmp/update.json -X PUT "$BASE/todos/$ID")
[[ "$STATUS" == "200" ]] || { echo "Update todo failed: $STATUS"; exit 1; }

# Delete todo
STATUS=$(curl -s -b "$COOKIE_JAR" -w "%{http_code}" -o /dev/null -X DELETE "$BASE/todos/$ID")
[[ "$STATUS" == "204" ]] || { echo "Delete todo failed: $STATUS"; exit 1; }

# Ensure deleted returns 404
STATUS=$(curl -s -b "$COOKIE_JAR" -w "%{http_code}" -o /dev/null "$BASE/todos/$ID")
[[ "$STATUS" == "404" ]] || { echo "Deleted get should 404: $STATUS"; exit 1; }

# Change password: wrong old
STATUS=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword"}' -w "%{http_code}" -o /dev/null -X PUT "$BASE/password")
[[ "$STATUS" == "401" ]] || { echo "Password wrong old should 401: $STATUS"; exit 1; }

# Change password
STATUS=$(curl -s -b "$COOKIE_JAR" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword"}' -w "%{http_code}" -o /dev/null -X PUT "$BASE/password")
[[ "$STATUS" == "200" ]] || { echo "Password change failed: $STATUS"; exit 1; }

# Logout
STATUS=$(curl -s -b "$COOKIE_JAR" -w "%{http_code}" -o /dev/null -X POST "$BASE/logout")
[[ "$STATUS" == "200" ]] || { echo "Logout failed: $STATUS"; exit 1; }

# After logout, authenticated endpoint should 401
STATUS=$(curl -s -b "$COOKIE_JAR" -w "%{http_code}" -o /dev/null "$BASE/me")
[[ "$STATUS" == "401" ]] || { echo "Post-logout should 401: $STATUS"; exit 1; }

echo "All tests passed"
