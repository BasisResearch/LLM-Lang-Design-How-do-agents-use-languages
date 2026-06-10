#!/bin/sh
set -eu

# Find a free port
PORT=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(('',0))
print(s.getsockname()[1])
s.close()
PY
)

./run.sh --port "$PORT" &
SERVER_PID=$!

echo "Started server PID $SERVER_PID on port $PORT"

# Trap to ensure cleanup
cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
HDR=$(mktemp)
BODY=$(mktemp)

wait_for_server() {
  i=0
  until curl -sS "$BASE/me" -o /dev/null -w "%{http_code}" | grep -qE '^(401|200)$'; do
    i=$((i+1))
    if [ $i -gt 50 ]; then
      echo "Server did not start in time" >&2
      exit 1
    fi
    sleep 0.1
  done
}
wait_for_server

check_code() {
  expected="$1"; shift
  code="$1"; shift
  if [ "$code" != "$expected" ]; then
    echo "Expected HTTP $expected but got $code" >&2
    echo "Headers:" >&2; cat "$HDR" >&2 || true
    echo "Body:" >&2; cat "$BODY" >&2 || true
    exit 1
  fi
}

curl_json() {
  method="$1"; shift
  url="$1"; shift
  data="${1-}"
  if [ -n "${data}" ]; then
    curl -sS -X "$method" "$url" -H 'Content-Type: application/json' -d "$data" -D "$HDR" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -o "$BODY" -w "%{http_code}"
  else
    curl -sS -X "$method" "$url" -D "$HDR" -b "$COOKIE_JAR" -c "$COOKIE_JAR" -o "$BODY" -w "%{http_code}"
  fi
}

# 1) Register user
code=$(curl_json POST "$BASE/register" '{"username":"alice","password":"password123"}')
check_code 201 "$code"

grep -q 'application/json' "$HDR"

grep -q '"username"\s*:\s*"alice"' "$BODY"

# 1b) Register duplicate
code=$(curl_json POST "$BASE/register" '{"username":"alice","password":"password123"}')
check_code 409 "$code"

grep -q '"error"' "$BODY"

# 2) Bad login
code=$(curl_json POST "$BASE/login" '{"username":"alice","password":"wrongpass"}')
check_code 401 "$code"

# 3) Login ok
code=$(curl_json POST "$BASE/login" '{"username":"alice","password":"password123"}')
check_code 200 "$code"

grep -qi '^Set-Cookie: session_id=' "$HDR"

# 4) /me
code=$(curl_json GET "$BASE/me" '')
check_code 200 "$code"

grep -q '"username"\s*:\s*"alice"' "$BODY"

# 5) Change password wrong old
code=$(curl_json PUT "$BASE/password" '{"old_password":"nope","new_password":"newpassword123"}')
check_code 401 "$code"

# 6) Change password too short
code=$(curl_json PUT "$BASE/password" '{"old_password":"password123","new_password":"short"}')
check_code 400 "$code"

# 7) Change password success
code=$(curl_json PUT "$BASE/password" '{"old_password":"password123","new_password":"newpassword123"}')
check_code 200 "$code"

grep -q '{}' "$BODY"

# 8) Logout
code=$(curl_json POST "$BASE/logout" '')
check_code 200 "$code"

# 9) Auth required after logout
code=$(curl_json GET "$BASE/me" '')
check_code 401 "$code"

# 10) Login with new password
code=$(curl_json POST "$BASE/login" '{"username":"alice","password":"newpassword123"}')
check_code 200 "$code"

# 11) GET empty todos
code=$(curl_json GET "$BASE/todos" '')
check_code 200 "$code"

grep -qE '^\s*\[\s*\]\s*$' "$BODY" || true

# 12) Create todo missing title
code=$(curl_json POST "$BASE/todos" '{"description":"desc"}')
check_code 400 "$code"

# 13) Create todo success
code=$(curl_json POST "$BASE/todos" '{"title":"Task 1","description":"First task"}')
check_code 201 "$code"

a_todo_id=$(cat "$BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

# 14) Get todo
code=$(curl_json GET "$BASE/todos/$a_todo_id" '')
check_code 200 "$code"

grep -q '"title"\s*:\s*"Task 1"' "$BODY"

a_created=$(cat "$BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["updated_at"])')

# 15) Update todo
code=$(curl_json PUT "$BASE/todos/$a_todo_id" '{"title":"Task 1 updated","completed": true}')
check_code 200 "$code"

grep -q '"completed"\s*:\s*true' "$BODY"

a_updated=$(cat "$BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["updated_at"])')

[ "$a_updated" != "$a_created" ] || { echo "updated_at did not change" >&2; exit 1; }

# 16) Delete todo
code=$(curl_json DELETE "$BASE/todos/$a_todo_id" '')
check_code 204 "$code"

! grep -qi '^Content-Type:' "$HDR" || { echo "DELETE should not return Content-Type" >&2; exit 1; }

# 17) Get deleted -> 404
code=$(curl_json GET "$BASE/todos/$a_todo_id" '')
check_code 404 "$code"

# 18) Register second user and create a todo
code=$(curl_json POST "$BASE/register" '{"username":"bob","password":"password456"}')
check_code 201 "$code"

code=$(curl_json POST "$BASE/login" '{"username":"bob","password":"password456"}')
check_code 200 "$code"

code=$(curl_json POST "$BASE/todos" '{"title":"Bobs Task","description":"Secret"}')
check_code 201 "$code"

bob_todo_id=$(cat "$BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')

# 19) Switch back to alice, attempt to access bob's todo -> 404
# Re-login as alice
code=$(curl_json POST "$BASE/login" '{"username":"alice","password":"newpassword123"}')
check_code 200 "$code"

code=$(curl_json GET "$BASE/todos/$bob_todo_id" '')
check_code 404 "$code"

# 20) List todos for alice (should be empty)
code=$(curl_json GET "$BASE/todos" '')
check_code 200 "$code"

echo "All tests passed."
