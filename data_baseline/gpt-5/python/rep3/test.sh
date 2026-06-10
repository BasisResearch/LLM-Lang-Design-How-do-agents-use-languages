#!/bin/sh
set -eu
# Pick a random available port
PORT=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(("127.0.0.1",0))
print(s.getsockname()[1])
s.close()
PY
)
./run.sh --port "$PORT" &
PID=$!
cleanup() {
  kill $PID 2>/dev/null || true
}
trap cleanup EXIT INT TERM
# Wait for server to respond
base="http://127.0.0.1:$PORT"
for i in 1 2 3 4 5; do
  if curl -s -o /dev/null "$base/unknown"; then
    break
  fi
  sleep 0.5
done

echo "Register user"
curl -sS -H 'Content-Type: application/json' -X POST "$base/register" -d '{"username":"user_one","password":"password123"}'
echo

# Duplicate username should 409
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$base/register" -d '{"username":"user_one","password":"password123"}')
[ "$code" = "409" ] || { echo "Expected 409 duplicate username, got $code"; exit 1; }

# Login
login_resp=$(curl -i -sS -H 'Content-Type: application/json' -X POST "$base/login" -d '{"username":"user_one","password":"password123"}')
echo "$login_resp"
# Extract cookie
cookie=$(printf "%s" "$login_resp" | awk '/^Set-Cookie:/ {print $2}' | tr -d '\r' | cut -d';' -f1)
[ -n "$cookie" ] || { echo "No session cookie"; exit 1; }

# /me
me=$(curl -sS -H "Cookie: $cookie" "$base/me")
echo "$me" | grep -E '"username" *: *"user_one"' >/dev/null || { echo "/me failed"; exit 1; }

# Create todo
todo1=$(curl -sS -H 'Content-Type: application/json' -H "Cookie: $cookie" -X POST "$base/todos" -d '{"title":"Task 1","description":"First"}')
echo "$todo1"
# List todos
list=$(curl -sS -H "Cookie: $cookie" "$base/todos")
echo "$list"
# Get by id 1
get1=$(curl -sS -H "Cookie: $cookie" "$base/todos/1")
echo "$get1" | grep -E '"title" *: *"Task 1"' >/dev/null || { echo "Get todo 1 failed"; exit 1; }

# Update todo
upd=$(curl -sS -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/todos/1" -d '{"completed":true}')
echo "$upd" | grep -E '"completed" *: *true' >/dev/null || { echo "Update failed"; exit 1; }

# Delete todo
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" -X DELETE "$base/todos/1")
[ "$code" = "204" ] || { echo "Expected 204 on delete, got $code"; exit 1; }

# Ensure 404 on get deleted
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" "$base/todos/1")
[ "$code" = "404" ] || { echo "Expected 404 on get deleted, got $code"; exit 1; }

# Password change wrong old should 401
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/password" -d '{"old_password":"wrong","new_password":"newpassword123"}')
[ "$code" = "401" ] || { echo "Expected 401 wrong old password, got $code"; exit 1; }

# Correct password change
code=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/password" -d '{"old_password":"password123","new_password":"newpassword123"}')
[ "$code" = "200" ] || { echo "Expected 200 on password change, got $code"; exit 1; }

# Logout
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" -X POST "$base/logout")
[ "$code" = "200" ] || { echo "Expected 200 on logout, got $code"; exit 1; }

# After logout, /me should 401
code=$(curl -s -o /dev/null -w "%{http_code}" -H "Cookie: $cookie" "$base/me")
[ "$code" = "401" ] || { echo "Expected 401 after logout, got $code"; exit 1; }

echo "All tests passed"