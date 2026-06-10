#!/usr/bin/env bash
set -euo pipefail
PORT=8095
if [[ ${1-} == "--port" && -n ${2-} ]]; then PORT=$2; fi
BASE="http://127.0.0.1:$PORT"

# Build server
go build -o server .

# Clean prior servers on this port
pkill -f "\./server --port $PORT" 2>/dev/null || true
sleep 0.1

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$COOKIEJAR" 2>/dev/null || true
}
trap cleanup EXIT

./server --port "$PORT" >/tmp/server.$PORT.log 2>&1 &
SERVER_PID=$!
# Wait for boot
for i in {1..100}; do
  if curl -sS -o /dev/null "$BASE/register"; then break; fi
  sleep 0.1
  if [[ $i -eq 100 ]]; then echo "Server failed to start"; tail -n +1 /tmp/server.$PORT.log; exit 1; fi
done

COOKIEJAR=$(mktemp)
H=/tmp/headers.$PORT.txt
B=/tmp/body.$PORT.txt

# request METHOD PATH [DATA_FILE] [EXTRA_CURL_ARGS...]
request() {
  local method=$1; shift
  local path=$1; shift || true
  local datafile="${1-}"; shift || true
  : >"$H"; : >"$B"
  local args=( -sS -D "$H" -o "$B" -X "$method" "$BASE$path" )
  if [[ -n "${datafile:-}" ]]; then
    args+=( -H 'Content-Type: application/json' --data-binary @"$datafile" )
  fi
  args+=( "$@" )
  curl "${args[@]}"
  STATUS=$(awk 'NR==1{print $2}' "$H")
  CT=$(awk -F ': ' 'tolower($1)=="content-type"{print tolower($2)}' "$H" | tr -d '\r' | tail -n1)
}

mkjson() { printf '%s' "$2" > "$1"; }
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Register
mkjson "$TMPDIR/reg1.json" '{"username":"user_1","password":"password123"}'
request POST /register "$TMPDIR/reg1.json"
[[ "$STATUS" == "201" ]] || { echo "Register failed $STATUS"; cat "$B"; exit 1; }
[[ "$CT" == application/json* ]] || { echo "Missing JSON content-type"; exit 1; }

# Login and store cookie
mkjson "$TMPDIR/login1.json" '{"username":"user_1","password":"password123"}'
request POST /login "$TMPDIR/login1.json" -c "$COOKIEJAR"
[[ "$STATUS" == "200" ]] || { echo "Login failed $STATUS"; cat "$B"; exit 1; }

# /me with cookie
request GET /me '' -b "$COOKIEJAR"
[[ "$STATUS" == "200" ]] || { echo "/me failed $STATUS"; exit 1; }

# Password change checks
mkjson "$TMPDIR/pw_wrong.json" '{"old_password":"wrong","new_password":"newpassword123"}'
request PUT /password "$TMPDIR/pw_wrong.json" -b "$COOKIEJAR"
[[ "$STATUS" == "401" ]] || { echo "old password check should 401"; exit 1; }
mkjson "$TMPDIR/pw_short.json" '{"old_password":"password123","new_password":"short"}'
request PUT /password "$TMPDIR/pw_short.json" -b "$COOKIEJAR"
[[ "$STATUS" == "400" ]] || { echo "new password too short should 400"; exit 1; }
mkjson "$TMPDIR/pw_ok.json" '{"old_password":"password123","new_password":"newpassword123"}'
request PUT /password "$TMPDIR/pw_ok.json" -b "$COOKIEJAR"
[[ "$STATUS" == "200" ]] || { echo "password change failed"; exit 1; }

# Create todos
mkjson "$TMPDIR/todo_bad.json" '{"description":"x"}'
request POST /todos "$TMPDIR/todo_bad.json" -b "$COOKIEJAR"
[[ "$STATUS" == "400" ]] || { echo "missing title should 400"; exit 1; }
mkjson "$TMPDIR/todo1.json" '{"title":"Task 1","description":"desc"}'
request POST /todos "$TMPDIR/todo1.json" -b "$COOKIEJAR"
[[ "$STATUS" == "201" ]] || { echo "create todo failed"; exit 1; }
TID=$(sed -n 's/.*"id"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p' "$B")
[[ "$TID" == "1" ]] || { echo "unexpected todo id $TID"; exit 1; }

# List
request GET /todos '' -b "$COOKIEJAR"
[[ "$STATUS" == "200" ]] || { echo "list failed"; exit 1; }

# Get by id
request GET /todos/$TID '' -b "$COOKIEJAR"
[[ "$STATUS" == "200" ]] || { echo "get by id failed"; exit 1; }

# Update
mkjson "$TMPDIR/patch1.json" '{"completed":true}'
request PUT /todos/$TID "$TMPDIR/patch1.json" -b "$COOKIEJAR"
[[ "$STATUS" == "200" ]] || { echo "update failed"; exit 1; }

# Delete
request DELETE /todos/$TID '' -b "$COOKIEJAR"
[[ "$STATUS" == "204" ]] || { echo "delete failed"; exit 1; }
[[ ! -s "$B" ]] || { echo "delete should return no body"; exit 1; }

# Ensure 404 after delete
request GET /todos/$TID '' -b "$COOKIEJAR"
[[ "$STATUS" == "404" ]] || { echo "expected 404 after delete"; exit 1; }

# Logout invalidates cookie
request POST /logout '' -b "$COOKIEJAR"
[[ "$STATUS" == "200" ]] || { echo "logout failed"; exit 1; }
request GET /me '' -b "$COOKIEJAR"
[[ "$STATUS" == "401" ]] || { echo "me after logout should 401"; exit 1; }

# Second user and 404 for cross-user
mkjson "$TMPDIR/reg2.json" '{"username":"user_2","password":"passwordZZZ"}'
request POST /register "$TMPDIR/reg2.json"
[[ "$STATUS" == "201" ]] || { echo "reg user2 failed"; exit 1; }
mkjson "$TMPDIR/login_u1.json" '{"username":"user_1","password":"newpassword123"}'
request POST /login "$TMPDIR/login_u1.json" -c "$COOKIEJAR"
[[ "$STATUS" == "200" ]] || { echo "login user1 again failed"; exit 1; }
mkjson "$TMPDIR/todo2.json" '{"title":"Task 2"}'
request POST /todos "$TMPDIR/todo2.json" -b "$COOKIEJAR"
TID2=$(sed -n 's/.*"id"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p' "$B")
mkjson "$TMPDIR/login_u2.json" '{"username":"user_2","password":"passwordZZZ"}'
request POST /login "$TMPDIR/login_u2.json" -c "$COOKIEJAR"
request GET /todos/$TID2 '' -b "$COOKIEJAR"
[[ "$STATUS" == "404" ]] || { echo "cross-user should 404"; exit 1; }

echo "All tests passed"