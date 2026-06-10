#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
# pick a random high port to avoid collisions
PORT=$(( ( RANDOM % 30000 )  + 20000 ))
"$ROOT_DIR/run.sh" --port "$PORT" &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
base="http://127.0.0.1:$PORT"

# Wait for server to be ready
for i in {1..100}; do
  if curl -s -o /dev/null "$base/register"; then break; fi
  sleep 0.1
done

CJ=$(mktemp)

# 1) Register (expect 201)
curl -s -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "201" ]]; then echo "Register failed: $code"; cat /tmp/h; cat /tmp/b; exit 1; fi

# Duplicate (expect 409)
curl -s -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' -D /tmp/h -o /tmp/b >/dev/null || true
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "409" ]]; then echo "Expected 409 on duplicate, got $code"; cat /tmp/h; cat /tmp/b; exit 1; fi

# 2) Login
curl -s -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' -c "$CJ" -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "Login failed"; cat /tmp/h; cat /tmp/b; exit 1; fi
if ! grep -qi '^set-cookie: session_id=' /tmp/h; then echo "No Set-Cookie"; exit 1; fi

# 3) /me
curl -s -X GET "$base/me" -b "$CJ" -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "/me failed"; cat /tmp/h; cat /tmp/b; exit 1; fi
if ! grep -qi '^content-type: application/json' /tmp/h; then echo "Bad content-type"; exit 1; fi

# 4) Create todo
curl -s -X POST "$base/todos" -b "$CJ" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"Desc"}' -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "201" ]]; then echo "Create todo failed"; cat /tmp/h; cat /tmp/b; exit 1; fi

# 5) List todos
curl -s -X GET "$base/todos" -b "$CJ" -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "List todos failed"; cat /tmp/h; cat /tmp/b; exit 1; fi

# Grab id
TID=$(jq -r '.[0].id' </tmp/b)

# 6) Get todo by id
curl -s -X GET "$base/todos/$TID" -b "$CJ" -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "Get todo failed"; cat /tmp/h; cat /tmp/b; exit 1; fi

# 7) Update todo
curl -s -X PUT "$base/todos/$TID" -b "$CJ" -H 'Content-Type: application/json' -d '{"completed":true}' -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "Update todo failed"; cat /tmp/h; cat /tmp/b; exit 1; fi

# 8) Delete todo
curl -s -X DELETE "$base/todos/$TID" -b "$CJ" -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "204" ]]; then echo "Delete todo failed"; cat /tmp/h; cat /tmp/b; exit 1; fi
if grep -qi '^content-type:' /tmp/h; then echo "DELETE should not have content-type"; exit 1; fi

# 9) Logout
curl -s -X POST "$base/logout" -b "$CJ" -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "Logout failed"; cat /tmp/h; cat /tmp/b; exit 1; fi

# 10) Auth required after logout
curl -s -X GET "$base/me" -b "$CJ" -D /tmp/h -o /tmp/b >/dev/null || true
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "401" ]]; then echo "Auth not enforced after logout"; cat /tmp/h; cat /tmp/b; exit 1; fi

# 11) Change password flow
# Login again first
curl -s -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' -c "$CJ" >/dev/null
curl -s -X PUT "$base/password" -b "$CJ" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpass123"}' -D /tmp/h -o /tmp/b >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "Change password failed"; cat /tmp/h; cat /tmp/b; exit 1; fi

# Try login with old password should fail
curl -s -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}' -D /tmp/h -o /tmp/b >/dev/null || true
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "401" ]]; then echo "Old password still works"; cat /tmp/h; cat /tmp/b; exit 1; fi

# New password should work
curl -s -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"newpass123"}' -D /tmp/h -o /tmp/b -c "$CJ" >/dev/null
code=$(head -1 /tmp/h | awk '{print $2}')
if [[ "$code" != "200" ]]; then echo "New password login failed"; cat /tmp/h; cat /tmp/b; exit 1; fi

echo "All tests passed on port $PORT" 
