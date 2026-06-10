#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq..." >&2
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y jq >/dev/null 2>&1 || true
fi

PORT=18111
./run.sh --port "$PORT" >/tmp/scala-todo-server.log 2>&1 &
PID=$!
base="http://127.0.0.1:$PORT"

echo "Waiting for server to start on $base ..." >&2
for i in $(seq 1 180); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$base/me" || true)
  if [[ "$code" != "000" && -n "$code" ]]; then
    break
  fi
  sleep 1
  if ! kill -0 $PID 2>/dev/null; then
    echo "Server process exited unexpectedly. Log:" >&2
    sed -n '1,200p' /tmp/scala-todo-server.log || true
    exit 1
  fi
  if [[ $i -eq 180 ]]; then
    echo "Server did not start in time" >&2
    exit 1
  fi
done

pass() { echo "[OK] $*"; }
fail() { echo "[FAIL] $*"; kill $PID || true; exit 1; }
cleanup() { kill $PID || true; }
trap cleanup EXIT

# Helpers
req() { # method url data(optional) cookiejar(optional)
  local method="$1"; shift
  local url="$1"; shift
  local dataArg=()
  if [[ ${1-} != "" && ${1-} != "-" ]]; then dataArg=(--data "$1"); shift; else shift || true; fi
  local cj=()
  if [[ ${1-} != "" && ${1-} != "-" ]]; then cj=(--cookie "$1" --cookie-jar "$1"); shift; else shift || true; fi
  curl -s -S -i -X "$method" -H 'Content-Type: application/json' "${dataArg[@]}" "${cj[@]}" "$url"
}

get_status() { awk '/HTTP\//{code=$2} END{print code}' ; }
get_header() { awk -v key="$1" 'BEGIN{IGNORECASE=1} tolower($0) ~ tolower("^"key":"){sub("^"key": ",""); print; exit}' ; }
get_body() {
  awk 'BEGIN{hdr=1} {if(hdr && $0 ~ /^\r?$/){hdr=0; next} if(!hdr){print}}'
}

# 1. Register alice
resp=$(req POST "$base/register" '{"username":"alice_1","password":"password123"}')
status=$(printf "%s" "$resp" | get_status)
[[ "$status" == "201" ]] || fail "register alice status $status"
ct=$(printf "%s" "$resp" | get_header 'Content-Type')
[[ "$ct" == application/json* ]] || fail "register content-type $ct"

# 2. Register alice again -> 409
status=$(req POST "$base/register" '{"username":"alice_1","password":"password123"}' | get_status)
[[ "$status" == "409" ]] || fail "register duplicate status $status"

# 3. Login wrong password -> 401
status=$(req POST "$base/login" '{"username":"alice_1","password":"wrongpass"}' | get_status)
[[ "$status" == "401" ]] || fail "login wrong pass status $status"

# 4. Login correct -> 200, Set-Cookie
resp=$(req POST "$base/login" '{"username":"alice_1","password":"password123"}' alice.cookie)
status=$(printf "%s" "$resp" | get_status)
[[ "$status" == "200" ]] || fail "login alice status $status"
setcookie=$(printf "%s" "$resp" | get_header 'Set-Cookie')
[[ "$setcookie" == session_id=* ]] || fail "missing Set-Cookie session_id"
[[ "$setcookie" == *'Path=/'* ]] || fail "missing Path attribute"
[[ "$setcookie" == *'HttpOnly'* ]] || fail "missing HttpOnly attribute"

# 5. /me
status=$(req GET "$base/me" - alice.cookie | get_status)
[[ "$status" == "200" ]] || fail "/me status $status"

# Create bob and login
resp=$(req POST "$base/register" '{"username":"bob_2","password":"bobpassword"}')
[[ $(printf "%s" "$resp" | get_status) == "201" ]] || fail "register bob"
resp=$(req POST "$base/login" '{"username":"bob_2","password":"bobpassword"}' bob.cookie)
[[ $(printf "%s" "$resp" | get_status) == "200" ]] || fail "login bob"

# Bob creates a todo
resp=$(req POST "$base/todos" '{"title":"Bob Task","description":"bobdesc"}' bob.cookie)
[[ $(printf "%s" "$resp" | get_status) == "201" ]] || fail "bob create todo"
bob_todo_id=$(printf "%s" "$resp" | get_body | jq -r '.id')

# Alice cannot access Bob's todo -> 404
status=$(req GET "$base/todos/$bob_todo_id" - alice.cookie | get_status)
[[ "$status" == "404" ]] || fail "alice should get 404 on bob's todo"

# 6. Change password wrong old -> 401
status=$(req PUT "$base/password" '{"old_password":"nope","new_password":"newpassword1"}' alice.cookie | get_status)
[[ "$status" == "401" ]] || fail "password wrong old status $status"

# 7. Change password correct -> 200
status=$(req PUT "$base/password" '{"old_password":"password123","new_password":"newpassword1"}' alice.cookie | get_status)
[[ "$status" == "200" ]] || fail "password change status $status"

# 8. Login with old -> 401
status=$(req POST "$base/login" '{"username":"alice_1","password":"password123"}' | get_status)
[[ "$status" == "401" ]] || fail "old password should fail"

# 8b. Login with new -> 200
resp=$(req POST "$base/login" '{"username":"alice_1","password":"newpassword1"}' alice.cookie)
[[ $(printf "%s" "$resp" | get_status) == "200" ]] || fail "login with new password"

# 9. GET /todos empty -> []
body=$(req GET "$base/todos" - alice.cookie | get_body)
[[ "$body" == "[]" ]] || fail "todos should be empty, got $body"

# 10. POST /todos empty title -> 400
status=$(req POST "$base/todos" '{"title":"   ","description":"x"}' alice.cookie | get_status)
[[ "$status" == "400" ]] || fail "empty title should 400"

# 11. POST /todos valid -> 201
resp=$(req POST "$base/todos" '{"title":"Task1","description":"desc1"}' alice.cookie)
[[ $(printf "%s" "$resp" | get_status) == "201" ]] || fail "create todo"
a_id=$(printf "%s" "$resp" | get_body | jq -r '.id')
a_updated=$(printf "%s" "$resp" | get_body | jq -r '.updated_at')

# 12. GET /todos -> list with item
count=$(req GET "$base/todos" - alice.cookie | get_body | jq 'length')
[[ "$count" -eq 1 ]] || fail "expected 1 todo, got $count"

# 13. GET /todos/:id -> 200
status=$(req GET "$base/todos/$a_id" - alice.cookie | get_status)
[[ "$status" == "200" ]] || fail "get todo by id"

# 14. PUT /todos/:id partial -> 200 and updated_at changes
resp=$(req PUT "$base/todos/$a_id" '{"completed":true}' alice.cookie)
[[ $(printf "%s" "$resp" | get_status) == "200" ]] || fail "update todo"
a_updated2=$(printf "%s" "$resp" | get_body | jq -r '.updated_at')
[[ "$a_updated2" != "$a_updated" ]] || fail "updated_at should change"

# 15. PUT /todos/:id empty title -> 400
status=$(req PUT "$base/todos/$a_id" '{"title":""}' alice.cookie | get_status)
[[ "$status" == "400" ]] || fail "empty title on update"

# 16. DELETE /todos/:id -> 204 and no body
resp=$(req DELETE "$base/todos/$a_id" - alice.cookie)
status=$(printf "%s" "$resp" | get_status)
[[ "$status" == "204" ]] || fail "delete todo"
body=$(printf "%s" "$resp" | get_body)
[[ -z "$body" ]] || fail "DELETE should have no body, got: $body"

# 17. GET after delete -> 404
status=$(req GET "$base/todos/$a_id" - alice.cookie | get_status)
[[ "$status" == "404" ]] || fail "get deleted should 404"

# 18. Auth required: no cookie -> 401
status=$(req GET "$base/todos" - - | get_status)
[[ "$status" == "401" ]] || fail "auth required for /todos"

# 19. Logout -> 200 and invalidate
status=$(req POST "$base/logout" - alice.cookie | get_status)
[[ "$status" == "200" ]] || fail "logout status"
status=$(req GET "$base/me" - alice.cookie | get_status)
[[ "$status" == "401" ]] || fail "session should be invalid after logout"

pass "All tests passed"
