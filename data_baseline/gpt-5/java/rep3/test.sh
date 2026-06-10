#!/usr/bin/env bash
set -euo pipefail
PORT=8095
./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT
sleep 1
base=http://127.0.0.1:$PORT
CT='Content-Type: application/json'

RND=$RANDOM$RANDOM
USER1="user_${RND}"
PASS1="password123"
USER2="user_${RND}_b"
PASS2="password456"

req() {
  method=$1; url=$2; data=${3-}
  if [ -n "${data}" ]; then
    curl -s -D headers.txt -o body.txt -w "%{http_code}" -X "$method" "$url" -H "$CT" ${COOKIE:+-H "Cookie: $COOKIE"} -d "$data"
  else
    curl -s -D headers.txt -o body.txt -w "%{http_code}" -X "$method" "$url" -H "$CT" ${COOKIE:+-H "Cookie: $COOKIE"}
  fi
}

get() {
  curl -s -D headers.txt -o body.txt -w "%{http_code}" "$1" ${COOKIE:+-H "Cookie: $COOKIE"}
}

expect_code() {
  got=$1; want=$2; msg=$3
  if [ "$got" != "$want" ]; then
    echo "Expected $want got $got: $msg" >&2
    echo "--- headers.txt ---"; cat headers.txt; echo "--- body.txt ---"; cat body.txt; exit 1
  fi
}

contains() {
  substr=$1
  if ! grep -F -q "$substr" body.txt; then
    echo "Body does not contain: $substr"; cat body.txt; exit 1
  fi
}

extract_json_field() {
  # crude extractor for top-level fields: key must be string or number/bool
  key=$1
  sed -n "s/.*\"$key\"\s*:\s*\([^,}]*\).*/\1/p" body.txt | head -n1 | tr -d '"' | tr -d '\r' | tr -d '\n'
}

# Unauthorized access check
code=$(curl -s -D headers.txt -o body.txt -w "%{http_code}" "$base/me")
expect_code "$code" 401 unauth-me
contains 'Authentication required'

# Register user 1
code=$(req POST "$base/register" "{\"username\":\"$USER1\",\"password\":\"$PASS1\"}")
expect_code "$code" 201 register1
contains "\"username\":\"$USER1\""

# Login user 1
code=$(req POST "$base/login" "{\"username\":\"$USER1\",\"password\":\"$PASS1\"}")
expect_code "$code" 200 login1
COOKIE=$(grep -i '^Set-Cookie:' headers.txt | sed -n 's/^[Ss]et-[Cc]ookie: \(session_id=[^;]*\).*/\1/p' | tr -d '\r' | tail -n1)
[ -n "${COOKIE:-}" ] || { echo "No session cookie"; cat headers.txt; exit 1; }

# /me
code=$(get "$base/me")
expect_code "$code" 200 me1
contains "\"username\":\"$USER1\""

# password change wrong old
code=$(req PUT "$base/password" '{"old_password":"bad","new_password":"newpassword"}')
expect_code "$code" 401 bad-old-password

# password change success
code=$(req PUT "$base/password" '{"old_password":"password123","new_password":"newpassword"}')
expect_code "$code" 200 change-password

# create todo missing title
code=$(req POST "$base/todos" '{"description":"desc"}')
expect_code "$code" 400 todo-missing-title

# create todo ok
code=$(req POST "$base/todos" '{"title":"T1","description":"D1"}')
expect_code "$code" 201 create-todo1
contains '"title":"T1"'
TODO_ID=$(extract_json_field id)
[ -n "$TODO_ID" ] || { echo "Failed to extract TODO_ID"; cat body.txt; exit 1; }

# list todos (should contain the new todo)
code=$(get "$base/todos")
expect_code "$code" 200 list-todos1
contains '['
contains '"title":"T1"'

# get todo by id
code=$(get "$base/todos/$TODO_ID")
expect_code "$code" 200 get-todo1
contains '"title":"T1"'

# update todo with empty title (should fail)
code=$(req PUT "$base/todos/$TODO_ID" '{"title":""}')
expect_code "$code" 400 update-empty-title

# update todo
code=$(req PUT "$base/todos/$TODO_ID" '{"completed":true,"title":"T1x"}')
expect_code "$code" 200 update-todo1
contains '"completed":true'
contains '"title":"T1x"'

# Register and login user 2
COOKIE2=
code=$(req POST "$base/register" "{\"username\":\"$USER2\",\"password\":\"$PASS2\"}")
expect_code "$code" 201 register2
code=$(req POST "$base/login" "{\"username\":\"$USER2\",\"password\":\"$PASS2\"}")
expect_code "$code" 200 login2
COOKIE2=$(grep -i '^Set-Cookie:' headers.txt | sed -n 's/^[Ss]et-[Cc]ookie: \(session_id=[^;]*\).*/\1/p' | tr -d '\r' | tail -n1)

# user2 tries to access user1's todo -> 404
code=$(curl -s -D headers.txt -o body.txt -w "%{http_code}" -H "$CT" -H "Cookie: $COOKIE2" "$base/todos/$TODO_ID")
expect_code "$code" 404 user2-get-user1-todo
contains 'Todo not found'

# user2 tries to delete user1's todo -> 404
code=$(curl -s -D headers.txt -o /dev/null -w "%{http_code}" -H "$CT" -H "Cookie: $COOKIE2" -X DELETE "$base/todos/$TODO_ID")
expect_code "$code" 404 user2-delete-user1-todo

# delete todo by user1
code=$(curl -s -D headers.txt -o /dev/null -w "%{http_code}" -H "$CT" -H "Cookie: $COOKIE" -X DELETE "$base/todos/$TODO_ID")
expect_code "$code" 204 delete-todo1

# logout user1
code=$(curl -s -D headers.txt -o body.txt -w "%{http_code}" -H "$CT" -H "Cookie: $COOKIE" -X POST "$base/logout")
expect_code "$code" 200 logout1

# verify session invalidated for user1
code=$(curl -s -D headers.txt -o /dev/null -w "%{http_code}" -H "$CT" -H "Cookie: $COOKIE" "$base/me")
expect_code "$code" 401 me-after-logout1

echo ALL TESTS PASSED
