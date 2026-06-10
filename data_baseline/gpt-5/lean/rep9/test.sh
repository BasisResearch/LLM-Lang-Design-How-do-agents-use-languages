#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-8090}
BASE=http://127.0.0.1:$PORT
COOKIE_JAR=$(mktemp)
cleanup(){ rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" &
PID=$!
sleep 1

req(){ local method="$1" path="$2" data="${3:-}"; if [[ -n "$data" ]]; then curl -s -S -X "$method" -H 'Content-Type: application/json' -d "$data" -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE$path" -i; else curl -s -S -X "$method" -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE$path" -i; fi }

check_status(){ local got="$1" exp="$2"; [[ "$got" == *"HTTP/1.1 $exp"* ]] || { echo "Expected $exp got: $got"; exit 1; } }

# Register
R=$(req POST /register '{"username":"alice","password":"password123"}')
check_status "$R" 201
# Login
R=$(req POST /login '{"username":"alice","password":"password123"}')
check_status "$R" 200
# Me
R=$(req GET /me)
check_status "$R" 200
# Create todo
R=$(req POST /todos '{"title":"Task 1","description":"Desc"}')
check_status "$R" 201
ID=$(printf '%s' "$R" | sed -n 's/.*"id":\([0-9]\+\).*/\1/p' | head -n1)
# List
R=$(req GET /todos)
check_status "$R" 200
# Get by id
R=$(req GET /todos/$ID)
check_status "$R" 200
# Update
R=$(req PUT /todos/$ID '{"completed":true}')
check_status "$R" 200
# Delete
R=$(req DELETE /todos/$ID)
check_status "$R" 204
# Logout
R=$(req POST /logout)
check_status "$R" 200
# Ensure 401 after logout
R=$(req GET /me)
check_status "$R" 401

kill $PID || true
wait $PID 2>/dev/null || true

echo "All tests passed"