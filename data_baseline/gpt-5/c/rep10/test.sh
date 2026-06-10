#!/bin/bash
set -euo pipefail

# Ensure curl and jq installed
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  sudo apt-get update && sudo apt-get install -y curl jq
fi

PORT=${PORT:-8095}
BASE=http://127.0.0.1:$PORT
COOKIE_JAR=$(mktemp)
COOKIE_JAR2=$(mktemp)
LOGFILE=$(mktemp)
cleanup() {
  rm -f "$COOKIE_JAR" "$COOKIE_JAR2" "$LOGFILE"
  if [[ -n "${SERVER_PID-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" >"$LOGFILE" 2>&1 &
SERVER_PID=$!

# Wait for server readiness
for i in {1..50}; do
  if curl -sS -o /dev/null "$BASE/me"; then break; fi
  sleep 0.1
done

check_status() {
  local code=$1
  local expected=$2
  if [[ "$code" != "$expected" ]]; then
    echo "Expected HTTP $expected but got $code" >&2
    echo "Server log:" >&2
    tail -n +1 "$LOGFILE" >&2 || true
    exit 1
  fi
}

# Register user alice
R=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' $BASE/register)
BODY=$(echo "$R" | head -n1)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 201
id=$(echo "$BODY" | jq -r .id)
[[ "$id" == "1" ]]

# Register duplicate should 409
R=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' $BASE/register)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 409

# Register user bob
R=$(curl -sS -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"bob","password":"password456"}' $BASE/register)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 201

# Login alice
R=$(curl -sS -c "$COOKIE_JAR" -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' $BASE/login)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 200

# /me
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" $BASE/me)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 200

# /password wrong old
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword"}' $BASE/password)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 401

# /password correct
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword"}' $BASE/password)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 200

# /todos list empty
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" $BASE/todos)
BODY=$(echo "$R" | head -n1)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 200
[[ "$(echo "$BODY" | jq 'length')" == "0" ]]

# Create todo (missing title error)
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"description":"No title"}' $BASE/todos)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 400

# Create todo
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"title":"Task1","description":"Desc"}' $BASE/todos)
BODY=$(echo "$R" | head -n1)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 201
TID=$(echo "$BODY" | jq -r .id)
[[ "$TID" == "1" ]]

# Get todo
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" $BASE/todos/$TID)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 200

# Update todo partial
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"completed":true}' $BASE/todos/$TID)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 200

# Update todo invalid title
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"title":""}' $BASE/todos/$TID)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 400

# Login bob
R=$(curl -sS -c "$COOKIE_JAR2" -w "\n%{http_code}" -H 'Content-Type: application/json' -d '{"username":"bob","password":"password456"}' $BASE/login)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 200

# Bob tries to access Alice's todo -> 404
R=$(curl -sS -b "$COOKIE_JAR2" -w "\n%{http_code}" $BASE/todos/$TID)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 404

# Delete todo by Alice
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" -X DELETE $BASE/todos/$TID)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 204

# Get deleted
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" $BASE/todos/$TID)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 404

# Logout
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" -X POST $BASE/logout)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 200

# Ensure session invalid
R=$(curl -sS -b "$COOKIE_JAR" -w "\n%{http_code}" $BASE/me)
CODE=$(echo "$R" | tail -n1)
check_status "$CODE" 401

echo "All tests passed"