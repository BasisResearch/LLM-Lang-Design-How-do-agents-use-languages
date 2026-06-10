#!/usr/bin/env bash
set -euo pipefail
PORT=4567
# kill anything on that port
if command -v fuser >/dev/null 2>&1; then
  fuser -k ${PORT}/tcp >/dev/null 2>&1 || true
fi
pkill -f "todo-app.*--port ${PORT}" >/dev/null 2>&1 || true

./run.sh --port $PORT > /tmp/todo-server.log 2>&1 &
PID=$!
cleanup() { kill $PID >/dev/null 2>&1 || true; }
trap cleanup EXIT
# wait for server to be up
for i in {1..50}; do
  if curl -s -o /dev/null http://localhost:$PORT/me; then break; fi
  sleep 0.1
done
base=localhost:$PORT
# Proper array for headers
HDRS=(-H "Content-Type: application/json" -s -S)

# Helper to run a curl and capture
req() {
  method=$1; shift
  url=$1; shift
  curl -w "%{http_code}" -D /tmp/hdrs -o /tmp/body -X "$method" "$@" http://$base"$url" > /tmp/code 2>/tmp/err || true
  code=$(tail -c 3 /tmp/code 2>/dev/null || echo 000)
  echo "$code"
}

expect_code() {
  local got=$1; local want=$2; local ctx=$3
  if [[ "$got" != "$want" ]]; then
    echo "$ctx failed ($got)"
    echo "STDERR:"; cat /tmp/err || true; echo
    echo "Response headers:"; cat /tmp/hdrs || true; echo
    echo "Body:"; cat /tmp/body || true; echo
    exit 1
  fi
}

# Register
code=$(req POST /register ${HDRS[@]} --data '{"username":"user_one","password":"password123"}')
expect_code "$code" 201 "Register"

# Duplicate register should 409
code=$(req POST /register ${HDRS[@]} --data '{"username":"user_one","password":"password123"}')
expect_code "$code" 409 "Duplicate register"

# Login
code=$(req POST /login ${HDRS[@]} --data '{"username":"user_one","password":"password123"}')
expect_code "$code" 200 "Login"
cookie=$(grep -i '^Set-Cookie:' /tmp/hdrs | sed -n 's/Set-Cookie: session_id=\([^;]*\).*/session_id=\1/p' | tr -d '\r')
if [[ -z "${cookie}" ]]; then echo "No cookie from login"; exit 1; fi

# Verify Content-Type is application/json
ctype=$(grep -i '^Content-Type:' /tmp/hdrs | tr -d '\r' | awk '{print $2}')
[[ "$ctype" == "application/json" ]] || { echo "Wrong Content-Type $ctype"; exit 1; }

# /me
code=$(req GET /me -H "Cookie: $cookie")
expect_code "$code" 200 "/me"

# Change password with wrong old should 401
code=$(req PUT /password ${HDRS[@]} -H "Cookie: $cookie" --data '{"old_password":"wrong","new_password":"newpassword123"}')
expect_code "$code" 401 "password wrong old"

# Change password ok
code=$(req PUT /password ${HDRS[@]} -H "Cookie: $cookie" --data '{"old_password":"password123","new_password":"newpassword123"}')
expect_code "$code" 200 "password change"

# Create todo
code=$(req POST /todos ${HDRS[@]} -H "Cookie: $cookie" --data '{"title":"Task A","description":"desc"}')
expect_code "$code" 201 "create todo"

# List todos
code=$(req GET /todos -H "Cookie: $cookie")
expect_code "$code" 200 "list todos"

# Get todo id 1
code=$(req GET /todos/1 -H "Cookie: $cookie")
expect_code "$code" 200 "get todo"

# Update todo
code=$(req PUT /todos/1 ${HDRS[@]} -H "Cookie: $cookie" --data '{"completed":true}')
expect_code "$code" 200 "update todo"

# Delete todo
code=$(req DELETE /todos/1 -H "Cookie: $cookie")
expect_code "$code" 204 "delete todo"
if [[ -s /tmp/body ]]; then echo "DELETE returned body"; exit 1; fi

# Logout
code=$(req POST /logout -H "Cookie: $cookie")
expect_code "$code" 200 "logout"

# Auth should now fail
code=$(req GET /me -H "Cookie: $cookie")
expect_code "$code" 401 "session invalidated"

echo "All tests passed."
