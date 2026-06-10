#!/bin/sh
set -eu

# Find a free port
PORT=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(('127.0.0.1',0))
print(s.getsockname()[1])
s.close()
PY
)

./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

base="http://127.0.0.1:$PORT"

# Wait for server to be ready
for i in 1 2 3 4 5 6 7 8 9 10; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$base/me" || true)
  if [ "$code" != "000" ]; then
    break
  fi
  sleep 0.2
done

# Unique username
USER="user_$(date +%s)_$$"
PASS="password123"
NEWPASS="newpassword123"

# 1. Register
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$base/register" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}")
[ "$code" = "201" ]

# 1b. Duplicate register
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$base/register" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}")
[ "$code" = "409" ]

# 2. Login and capture cookie
login_headers=$(mktemp)
code=$(curl -s -D "$login_headers" -o /dev/null -w "%{http_code}" -X POST "$base/login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}")
[ "$code" = "200" ]
SESSION=$(grep -i '^Set-Cookie:' "$login_headers" | tr -d '\r' | sed -n 's/^Set-Cookie: *session_id=\([^;]*\).*/\1/p')
rm -f "$login_headers"
[ -n "$SESSION" ]
COOK="Cookie: session_id=$SESSION"

# 3. GET /me
code=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOK" "$base/me")
[ "$code" = "200" ]

# 4. Create todos
code=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOK" -H 'Content-Type: application/json' \
  -d '{"title":"Task A","description":"First"}' "$base/todos" )
[ "$code" = "201" ]
code=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOK" -H 'Content-Type: application/json' \
  -d '{"title":"Task B"}' "$base/todos" )
[ "$code" = "201" ]

# 5. List todos
todos=$(curl -s -H "$COOK" "$base/todos")
count=$(echo "$todos" | python3 -c 'import sys, json; print(len(json.load(sys.stdin)))')
[ "$count" = "2" ]

# 6. Get by id
code=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOK" "$base/todos/1")
[ "$code" = "200" ]

# 7. Update todo
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "$COOK" -H 'Content-Type: application/json' \
  -d '{"completed":true, "title":"Task A+"}' "$base/todos/1")
[ "$code" = "200" ]

# 8. Delete todo
code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -H "$COOK" "$base/todos/2")
[ "$code" = "204" ]

# 9. Password change with wrong old password
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "$COOK" -H 'Content-Type: application/json' \
  -d '{"old_password":"wrong","new_password":"newpassword123"}' "$base/password")
[ "$code" = "401" ]

# 10. Password change correct
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H "$COOK" -H 'Content-Type: application/json' \
  -d "{\"old_password\":\"$PASS\",\"new_password\":\"$NEWPASS\"}" "$base/password")
[ "$code" = "200" ]

# 11. Logout
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "$COOK" "$base/logout")
[ "$code" = "200" ]

# 12. Ensure session invalidated
code=$(curl -s -o /dev/null -w "%{http_code}" -H "$COOK" "$base/me")
[ "$code" = "401" ]

echo "All tests passed"
