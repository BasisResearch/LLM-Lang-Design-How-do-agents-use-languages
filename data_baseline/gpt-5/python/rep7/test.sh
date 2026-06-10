#!/bin/sh
set -euo pipefail

# Find a free port starting from 18080
find_free_port() {
  port=18080
  while :; do
    if python3 - "$port" <<'PY'
import socket, sys
s=socket.socket()
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
    raise SystemExit(0)
except OSError:
    raise SystemExit(1)
finally:
    try: s.close()
    except Exception: pass
PY
    then
      echo "$port"
      return 0
    fi
    port=$((port+1))
    if [ $port -gt 18999 ]; then
      echo "No free port found" >&2
      exit 1
    fi
  done
}

PORT=$(find_free_port)
./run.sh --port "$PORT" &
SERVER_PID=$!

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
HEADER_OUT=$(mktemp)
BODY_OUT=$(mktemp)

# Wait for server to be ready
for i in 1 2 3 4 5 6 7 8 9 10; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/me" 2>/dev/null || true)
  if [ "$CODE" != "000" ]; then
    break
  fi
  sleep 0.3
done
sleep 0.3

# Register
echo "Registering..."
RESP=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$BASE/register")
echo "$RESP" | grep '"id"' >/dev/null

# Duplicate register
echo "Duplicate register..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$BASE/register")
[ "$CODE" -eq 409 ]

# Login
echo "Logging in..."
CODE=$(curl -s -D "$HEADER_OUT" -o "$BODY_OUT" -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/login")
[ "$CODE" -eq 200 ]
grep -i '^Set-Cookie: session_id=' "$HEADER_OUT" >/dev/null

# /me
echo "/me..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X GET -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/me")
[ "$CODE" -eq 200 ]

# Create todos
echo "Creating todos..."
for i in 1 2 3; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d "{\"title\":\"Task $i\",\"description\":\"Desc $i\"}" -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/todos")
  [ "$CODE" -eq 201 ]
done

# List todos
echo "Listing todos..."
LIST=$(curl -s -X GET -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/todos")
echo "$LIST" | grep 'Task 1' >/dev/null

# Get todo 1
echo "Getting todo 1..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X GET -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/todos/1")
[ "$CODE" -eq 200 ]

# Update todo 1
echo "Updating todo 1..."
BODY=$(curl -s -X PUT -H 'Content-Type: application/json' -d '{"completed": true, "title": "Task 1 Updated"}' -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/todos/1")
echo "$BODY" | grep '"completed": true' >/dev/null

# Delete todo 2
echo "Deleting todo 2..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/todos/2")
[ "$CODE" -eq 204 ]

# Change password (fail)
echo "Changing password with wrong old..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"badpass","new_password":"newpassword123"}' -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/password")
[ "$CODE" -eq 401 ]

# Change password (success)
echo "Changing password successfully..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}' -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/password")
[ "$CODE" -eq 200 ]

# Logout
echo "Logging out..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/logout")
[ "$CODE" -eq 200 ]

# Login with old password should fail
echo "Login with old password should fail..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' "$BASE/login")
[ "$CODE" -eq 401 ]

# Login with new password should work
echo "Login with new password..."
CODE=$(curl -s -D "$HEADER_OUT" -o /dev/null -w "%{http_code}" -X POST -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpassword123"}' -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/login")
[ "$CODE" -eq 200 ]
grep -i '^Set-Cookie: session_id=' "$HEADER_OUT" >/dev/null

# After login again, verify access
echo "Verifying access after re-login..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X GET -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/me")
[ "$CODE" -eq 200 ]

# After logout should fail
echo "Logging out again..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/logout")
[ "$CODE" -eq 200 ]

echo "Checking auth after logout..."
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X GET -c "$COOKIE_JAR" -b "$COOKIE_JAR" "$BASE/me")
[ "$CODE" -eq 401 ]

echo "All tests passed"