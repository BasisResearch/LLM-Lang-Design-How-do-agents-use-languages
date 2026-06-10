#!/usr/bin/env bash
set -euo pipefail

# Find a free port
find_port() {
  for i in {1..50}; do
    p=$(shuf -i 20000-40000 -n1)
    if command -v ss >/dev/null 2>&1; then
      if ! ss -ltn | awk '{print $4}' | grep -q ":$p$"; then echo "$p"; return 0; fi
    else
      # Fallback: try to connect; if fails, assume free
      if ! (echo > /dev/tcp/127.0.0.1/$p) >/dev/null 2>&1; then echo "$p"; return 0; fi
    fi
  done
  echo "29999"
}

PORT=$(find_port)
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

base="http://127.0.0.1:$PORT"

# Wait until server is ready (expect a response from /me)
for i in {1..50}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/me" || true)
  if [[ "$code" != "000" ]]; then break; fi
  sleep 0.2
done

echo "Register user1"
resp=$(curl -s -D - -o /dev/null -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
code=$(echo "$resp" | awk 'NR==1{print $2}')
[[ "$code" == "201" ]] || { echo "Register failed ($code)"; exit 1; }

# Duplicate username
resp=$(curl -s -D - -o /dev/null -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
code=$(echo "$resp" | awk 'NR==1{print $2}')
[[ "$code" == "409" ]] || { echo "Duplicate username check failed ($code)"; exit 1; }

echo "Login"
resp=$(curl -i -s -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
echo "$resp" | grep -i '^Set-Cookie: session_id=' >/dev/null || { echo "Missing Set-Cookie"; echo "$resp"; exit 1; }
COOKIE=$(echo "$resp" | awk 'BEGIN{IGNORECASE=1} /^Set-Cookie:/{print $2; exit}' | tr -d '\r' | sed 's/;.*//')

# Auth required check
code=$(curl -s -o /dev/null -w '%{http_code}' "$base/me")
[[ "$code" == "401" ]] || { echo "Unauthenticated me should be 401 ($code)"; exit 1; }

# Me
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" "$base/me")
[[ "$code" == "200" ]] || { echo "Authenticated me failed ($code)"; exit 1; }

# Create todo
resp=$(curl -s -i -X POST "$base/todos" -H "Cookie: $COOKIE" -H 'Content-Type: application/json' -d '{"title":"First","description":"desc"}')
[[ $(echo "$resp" | awk 'NR==1{print $2}') == "201" ]] || { echo "Create todo failed"; exit 1; }

# List todos
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" "$base/todos")
[[ "$code" == "200" ]] || { echo "List todos failed ($code)"; exit 1; }

# Get todo id 1
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" "$base/todos/1")
[[ "$code" == "200" ]] || { echo "Get todo failed ($code)"; exit 1; }

# Update todo
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Cookie: $COOKIE" -H 'Content-Type: application/json' -d '{"completed":true}' "$base/todos/1")
[[ "$code" == "200" ]] || { echo "Update todo failed ($code)"; exit 1; }

# Delete todo
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Cookie: $COOKIE" "$base/todos/1")
[[ "$code" == "204" ]] || { echo "Delete todo failed ($code)"; exit 1; }

# Confirm 404 after delete
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" "$base/todos/1")
[[ "$code" == "404" ]] || { echo "Get after delete should 404 ($code)"; exit 1; }

# Change password
code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Cookie: $COOKIE" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword456"}' "$base/password")
[[ "$code" == "200" ]] || { echo "Change password failed ($code)"; exit 1; }

# Logout
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Cookie: $COOKIE" "$base/logout")
[[ "$code" == "200" ]] || { echo "Logout failed ($code)"; exit 1; }

# After logout, should be 401
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOKIE" "$base/me")
[[ "$code" == "401" ]] || { echo "Me after logout should 401 ($code)"; exit 1; }

echo "All tests passed"
