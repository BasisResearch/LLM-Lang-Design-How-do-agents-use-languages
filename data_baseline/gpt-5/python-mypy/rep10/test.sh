#!/bin/sh
set -euxo pipefail

find_free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

PORT=$(find_free_port)
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

echo "Starting server on port $PORT (PID $SERVER_PID)"

# Wait for server to be ready (up to 10 seconds)
base="http://127.0.0.1:$PORT"
for i in $(seq 1 100); do
  if curl -sS --connect-timeout 2 -m 5 -o /dev/null "$base/me"; then
    break
  fi
  sleep 0.1
done

echo "Server should be up"

do_curl() {
  url="$1"; shift
  curl -sS --connect-timeout 2 -m 10 -D /tmp/headers.txt -o /tmp/body.txt -w "%{http_code}" "$url" "$@"
}

echo "1 Register"
status=$(do_curl "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[ "$status" = "201" ] || { echo "Register failed: $status"; cat /tmp/body.txt; exit 1; }
cat /tmp/body.txt | grep '"username"\s*:\s*"alice_1"' >/dev/null


echo "1b Duplicate register"
status=$(do_curl "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[ "$status" = "409" ] || { echo "Duplicate register expected 409: $status"; cat /tmp/body.txt; exit 1; }


echo "2 Login"
status=$(do_curl "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[ "$status" = "200" ] || { echo "Login failed: $status"; cat /tmp/body.txt; exit 1; }
SESSION=$(grep -i '^set-cookie:' /tmp/headers.txt | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r\n')
[ -n "$SESSION" ] || { echo "No session cookie"; exit 1; }
COOKIE="Cookie: session_id=$SESSION"


echo "3 /me"
status=$(do_curl "$base/me" -H "$COOKIE")
[ "$status" = "200" ] || { echo "/me failed: $status"; cat /tmp/body.txt; exit 1; }


echo "4 Create todo (missing title)"
status=$(do_curl "$base/todos" -H 'Content-Type: application/json' -H "$COOKIE" -d '{"description":"desc"}')
[ "$status" = "400" ] || { echo "Create todo missing title expected 400: $status"; exit 1; }


echo "5 Create todo (valid)"
status=$(do_curl "$base/todos" -H 'Content-Type: application/json' -H "$COOKIE" -d '{"title":"Task 1","description":"desc"}')
[ "$status" = "201" ] || { echo "Create todo failed: $status"; cat /tmp/body.txt; exit 1; }
TODO1=$(python3 - <<'PY'
import json
print(json.load(open('/tmp/body.txt'))['id'])
PY
)


echo "6 List todos"
status=$(do_curl "$base/todos" -H "$COOKIE")
[ "$status" = "200" ] || { echo "List todos failed: $status"; cat /tmp/body.txt; exit 1; }


echo "7 Get todo by id"
status=$(do_curl "$base/todos/$TODO1" -H "$COOKIE")
[ "$status" = "200" ] || { echo "Get todo failed: $status"; cat /tmp/body.txt; exit 1; }


echo "8 Update todo (partial)"
status=$(do_curl "$base/todos/$TODO1" -X PUT -H 'Content-Type: application/json' -H "$COOKIE" -d '{"completed": true}')
[ "$status" = "200" ] || { echo "Update todo failed: $status"; cat /tmp/body.txt; exit 1; }


echo "9 Delete todo"
status=$(do_curl "$base/todos/$TODO1" -X DELETE -H "$COOKIE")
[ "$status" = "204" ] || { echo "Delete todo failed: $status"; cat /tmp/body.txt; exit 1; }


echo "10 Logout"
status=$(do_curl "$base/logout" -X POST -H "$COOKIE")
[ "$status" = "200" ] || { echo "Logout failed: $status"; cat /tmp/body.txt; exit 1; }


echo "11 Auth required after logout"
status=$(do_curl "$base/me")
[ "$status" = "401" ] || { echo "Post-logout /me should be 401: $status"; exit 1; }


echo "12 Change password path: relogin and change"
status=$(do_curl "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[ "$status" = "200" ] || { echo "Re-login failed: $status"; cat /tmp/body.txt; exit 1; }
SESSION=$(grep -i '^set-cookie:' /tmp/headers.txt | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r\n')
COOKIE="Cookie: session_id=$SESSION"
status=$(do_curl "$base/password" -X PUT -H 'Content-Type: application/json' -H "$COOKIE" -d '{"old_password":"password123","new_password":"newpass890"}')
[ "$status" = "200" ] || { echo "Change password failed: $status"; cat /tmp/body.txt; exit 1; }


echo "13 Login with old password should fail"
status=$(do_curl "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"password123"}')
[ "$status" = "401" ] || { echo "Old password login should 401: $status"; cat /tmp/body.txt; exit 1; }


echo "14 Login with new password should succeed"
status=$(do_curl "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice_1","password":"newpass890"}')
[ "$status" = "200" ] || { echo "New password login failed: $status"; cat /tmp/body.txt; exit 1; }

kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true

echo "All tests passed"