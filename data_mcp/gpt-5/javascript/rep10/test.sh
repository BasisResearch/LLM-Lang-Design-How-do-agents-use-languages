#!/bin/bash
set -euo pipefail
PORT=$(( ( RANDOM % 20000 ) + 20000 ))
cleanup() { if [[ -n "${SERVER_PID-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi }
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" &
SERVER_PID=$!
# wait a bit for server to start
sleep 1

base="http://127.0.0.1:$PORT"
CURL="curl -sS --max-time 5"

echo "1) Register user"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$base/register") || true
if [[ "$HTTP" != "201" ]]; then echo "Register failed (status $HTTP)"; exit 1; fi

# Login
echo "2) Login"
RESP=$($CURL -D - -o >(tee /tmp/body_login.$$ >/dev/null) -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$base/login")
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
if [[ "$STATUS" != "200" ]]; then echo "Login failed (status $STATUS)"; exit 1; fi
COOKIE=$(echo "$RESP" | awk 'BEGIN{IGNORECASE=1} /^Set-Cookie:/ {print $0; exit}' | sed -E 's/Set-Cookie: ([^;]+).*/\1/I')
if [[ -z "$COOKIE" ]]; then echo "Missing cookie"; exit 1; fi

# Create todo
echo "3) Create todo"
RESP=$($CURL -D - -o >(tee /tmp/body_todo1.$$ >/dev/null) -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"title":"First","description":"Desc"}' "$base/todos")
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
if [[ "$STATUS" != "201" ]]; then echo "Create todo failed (status $STATUS)"; exit 1; fi
TODO_ID=$(tr -d '\n' </tmp/body_todo1.$$ | sed -E 's/.*"id"\s*:\s*([0-9]+).*/\1/')
if [[ -z "$TODO_ID" ]]; then echo "Failed to parse todo id"; exit 1; fi

# Get me
echo "4) Get /me"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -H "Cookie: $COOKIE" "$base/me")
if [[ "$HTTP" != "200" ]]; then echo "/me failed (status $HTTP)"; exit 1; fi

# List todos
echo "5) List todos"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -H "Cookie: $COOKIE" "$base/todos")
if [[ "$HTTP" != "200" ]]; then echo "List failed (status $HTTP)"; exit 1; fi

# Get todo by id
echo "6) Get todo by id"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -H "Cookie: $COOKIE" "$base/todos/$TODO_ID")
if [[ "$HTTP" != "200" ]]; then echo "Get by id failed (status $HTTP)"; exit 1; fi

# Update todo
echo "7) Update todo"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"completed":true}' "$base/todos/$TODO_ID")
if [[ "$HTTP" != "200" ]]; then echo "Update failed (status $HTTP)"; exit 1; fi

# Change password
echo "8) Change password"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -H "Cookie: $COOKIE" -d '{"old_password":"password123","new_password":"newpassword456"}' "$base/password")
if [[ "$HTTP" != "200" ]]; then echo "Password change failed (status $HTTP)"; exit 1; fi

# Logout
echo "9) Logout"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -X POST -H "Cookie: $COOKIE" "$base/logout")
if [[ "$HTTP" != "200" ]]; then echo "Logout failed (status $HTTP)"; exit 1; fi

# Access after logout should be 401
echo "10) Access after logout"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -H "Cookie: $COOKIE" "$base/me")
if [[ "$HTTP" != "401" ]]; then echo "Expected 401 after logout (status $HTTP)"; exit 1; fi

# Delete todo should be unauthorized now
echo "11) Delete after logout should be 401"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -X DELETE -H "Cookie: $COOKIE" "$base/todos/$TODO_ID")
if [[ "$HTTP" != "401" ]]; then echo "Expected 401 on delete after logout (status $HTTP)"; exit 1; fi

# Login again and delete todo
echo "12) Login again"
RESP=$($CURL -D - -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpassword456"}' "$base/login")
STATUS=$(echo "$RESP" | awk 'NR==1{print $2}')
if [[ "$STATUS" != "200" ]]; then echo "Re-Login failed (status $STATUS)"; exit 1; fi
COOKIE=$(echo "$RESP" | awk 'BEGIN{IGNORECASE=1} /^Set-Cookie:/ {print $0; exit}' | sed -E 's/Set-Cookie: ([^;]+).*/\1/I')

# Delete
echo "13) Delete todo"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -X DELETE -H "Cookie: $COOKIE" "$base/todos/$TODO_ID")
if [[ "$HTTP" != "204" ]]; then echo "Delete failed (status $HTTP)"; exit 1; fi

# Ensure not found now
echo "14) Ensure not found"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -H "Cookie: $COOKIE" "$base/todos/$TODO_ID")
if [[ "$HTTP" != "404" ]]; then echo "Expected 404 after delete (status $HTTP)"; exit 1; fi

# Validation checks
echo "15) Duplicate username should 409"
HTTP=$($CURL -o /dev/stderr -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$base/register") || true
if [[ "$HTTP" != "409" ]]; then echo "Expected 409 duplicate (status $HTTP)"; exit 1; fi

# All good
echo "All tests passed"