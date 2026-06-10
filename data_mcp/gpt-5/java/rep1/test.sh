#!/usr/bin/env bash
set -euo pipefail
PORT=${PORT:-8090}
./run.sh --port "$PORT" >/tmp/server.log 2>&1 &
SERVER_PID=$!
sleep 1
cleanup() { kill $SERVER_PID || true; }
trap cleanup EXIT
base=localhost:$PORT
cookiejar=$(mktemp)
TMPH=$(mktemp)
TMPB=$(mktemp)
fail() { echo "TEST FAILED: $1"; echo "--- server log ---"; tail -n +1 /tmp/server.log; exit 1; }

do_req() {
  # args: method url [data]
  : >"$TMPH"; : >"$TMPB"
  local method="$1"; shift
  local url="$1"; shift || true
  local dataflag=()
  if [[ ${1-} != "" ]]; then
    dataflag=(-H 'Content-Type: application/json' --data "$1")
  fi
  curl -sS -D "$TMPH" -o "$TMPB" -X "$method" -b "$cookiejar" -c "$cookiejar" "$url" ${dataflag[@]} || true
}

status_code() { awk 'NR==1{print $2}' "$TMPH"; }
headers_has() { grep -iq "$1" "$TMPH"; }
body_contains() { grep -q "$1" "$TMPB"; }

# 1. Register
do_req POST http://$base/register '{"username":"user_one","password":"password123"}'
sc=$(status_code)
[[ "$sc" == "201" ]] || fail "register status $sc body=$(cat "$TMPB")"
headers_has '^Content-Type: application/json' || fail "register CT"
body_contains '"id":1' && body_contains '"username":"user_one"' || fail "register body $(cat "$TMPB")"

# 1b. Duplicate username
do_req POST http://$base/register '{"username":"user_one","password":"password123"}'
[[ "$(status_code)" == "409" ]] || fail "duplicate username status $(status_code)"

# 2. Login
: >"$cookiejar"
do_req POST http://$base/login '{"username":"user_one","password":"password123"}'
[[ "$(status_code)" == "200" ]] || fail "login status $(status_code) body=$(cat "$TMPB")"
headers_has '^Set-Cookie: session_id=' || fail "missing Set-Cookie"

# 3. /me
do_req GET http://$base/me
[[ "$(status_code)" == "200" ]] || fail "/me status $(status_code)"
body_contains '"username":"user_one"' || fail "/me body $(cat "$TMPB")"

# 4. Create todo (missing title)
do_req POST http://$base/todos '{"description":"desc"}'
[[ "$(status_code)" == "400" ]] || fail "todo missing title $(status_code)"

# 5. Create todo ok
do_req POST http://$base/todos '{"title":"t1","description":"d1"}'
[[ "$(status_code)" == "201" ]] || fail "create todo status $(status_code)"
body_contains '"id":1' && body_contains '"completed":false' || fail "create todo body $(cat "$TMPB")"

# 6. List todos
do_req GET http://$base/todos
[[ "$(status_code)" == "200" ]] || fail "list todos status $(status_code)"
body_contains '"id":1' || fail "list body $(cat "$TMPB")"

# 7. Get by id
do_req GET http://$base/todos/1
[[ "$(status_code)" == "200" ]] || fail "get todo status $(status_code)"

# 8. Update todo partial
do_req PUT http://$base/todos/1 '{"completed":true}'
[[ "$(status_code)" == "200" ]] || fail "update todo status $(status_code)"
body_contains '"completed":true' || fail "update body $(cat "$TMPB")"

# 9. Delete todo
: >"$TMPH"; : >"$TMPB"
curl -sS -D "$TMPH" -o "$TMPB" -X DELETE -b "$cookiejar" http://$base/todos/1 || true
[[ "$(status_code)" == "204" ]] || fail "delete todo status $(status_code)"
[[ ! -s "$TMPB" ]] || fail "delete todo should have empty body"

# 10. Get deleted -> 404
do_req GET http://$base/todos/1
[[ "$(status_code)" == "404" ]] || fail "get deleted 404 $(status_code)"

# 11. Password change wrong old
do_req PUT http://$base/password '{"old_password":"bad","new_password":"newpassword"}'
[[ "$(status_code)" == "401" ]] || fail "password change wrong old $(status_code)"

# 12. Password change ok
do_req PUT http://$base/password '{"old_password":"password123","new_password":"newpassword"}'
[[ "$(status_code)" == "200" ]] || fail "password change ok $(status_code)"

# 13. Logout
do_req POST http://$base/logout
[[ "$(status_code)" == "200" ]] || fail "logout $(status_code)"

# 14. Auth required after logout
do_req GET http://$base/me
[[ "$(status_code)" == "401" ]] || fail "/me after logout $(status_code)"

# 15. Unauthorized access to /todos
: >"$cookiejar"
do_req GET http://$base/todos
[[ "$(status_code)" == "401" ]] || fail "unauth todos $(status_code)"

echo "ALL TESTS PASSED"
