#!/usr/bin/env bash
set -euo pipefail
PORT=19090
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://127.0.0.1:$PORT"
# Wait for server (code should not be 000)
for i in {1..60}; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/me" || true)
  if [[ "$code" != "000" ]]; then break; fi
  sleep 1
done

echo "Server responded with $code"

if [[ "$code" == "000" ]]; then
  echo "Server did not start in time" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
C1="$tmpdir/cookies1.txt"
C2="$tmpdir/cookies2.txt"

request() {
  local method=$1; shift
  local path=$1; shift
  local data=${1-}
  local cookiejar=${2-}
  local cookiefile=${3-}
  if [[ -n "$data" ]]; then
    extra=( -H 'Content-Type: application/json' -d "$data" )
  else
    extra=()
  fi
  if [[ -n "${cookiejar}" ]]; then cj=( -c "$cookiejar" ); else cj=(); fi
  if [[ -n "${cookiefile}" ]]; then cf=( -b "$cookiefile" ); else cf=(); fi
  curl -sS -D "$tmpdir/headers.txt" -o "$tmpdir/body.txt" -X "$method" "${BASE}${path}" "${extra[@]}" -H 'Accept: application/json' "${cj[@]}" "${cf[@]}" -w "%{http_code}"
}

assert_status() {
  local expected=$1; shift
  local got=$1; shift
  if [[ "$got" != "$expected" ]]; then
    echo "Expected status $expected, got $got"
    echo "Headers:"; cat "$tmpdir/headers.txt" || true
    echo "Body:"; cat "$tmpdir/body.txt" || true
    exit 1
  fi
}

assert_body_contains() {
  local needle=$1
  if ! grep -q "$needle" "$tmpdir/body.txt"; then
    echo "Body does not contain: $needle"
    cat "$tmpdir/body.txt" || true
    exit 1
  fi
}

assert_header_contains() {
  local needle=$1
  if ! grep -qi "$needle" "$tmpdir/headers.txt"; then
    echo "Headers do not contain: $needle"
    cat "$tmpdir/headers.txt" || true
    exit 1
  fi
}

# 1. Register invalid username
code=$(request POST /register '{"username":"ab","password":"password123"}')
assert_status 400 "$code"
assert_body_contains 'Invalid username'

echo 1 OK

# 2. Register short password
code=$(request POST /register '{"username":"user_one","password":"short"}')
assert_status 400 "$code"
assert_body_contains 'Password too short'

echo 2 OK

# 3. Register valid
code=$(request POST /register '{"username":"user_one","password":"password123"}')
assert_status 201 "$code"
assert_body_contains '"id":1'
assert_body_contains '"username":"user_one"'

echo 3 OK

# 4. Duplicate
code=$(request POST /register '{"username":"user_one","password":"anotherpass"}')
assert_status 409 "$code"
assert_body_contains 'Username already exists'

echo 4 OK

# 5. Login wrong
code=$(request POST /login '{"username":"user_one","password":"badpass"}' "$C1")
assert_status 401 "$code"
assert_body_contains 'Invalid credentials'

echo 5 OK

# 6. Login correct
code=$(request POST /login '{"username":"user_one","password":"password123"}' "$C1")
assert_status 200 "$code"
assert_body_contains '"id":1'
assert_header_contains '^Set-Cookie: session_id='

# Use cookie for auth
code=$(request GET /me '' '' "$C1")
assert_status 200 "$code"
assert_body_contains '"username":"user_one"'

echo 6 OK

# 7. Create todo invalid title
code=$(request POST /todos '{"title":"","description":"desc"}' '' "$C1")
assert_status 400 "$code"
assert_body_contains 'Title is required'

echo 7 OK

# 8. Create todo valid
code=$(request POST /todos '{"title":"Task A","description":"First"}' '' "$C1")
assert_status 201 "$code"
assert_body_contains '"completed":false'
assert_body_contains '"id":1'

echo 8 OK

# 9. List todos
code=$(request GET /todos '' '' "$C1")
assert_status 200 "$code"
assert_body_contains '"id":1'

echo 9 OK

# 10. Get todo by id
code=$(request GET /todos/1 '' '' "$C1")
assert_status 200 "$code"
assert_body_contains '"title":"Task A"'

echo 10 OK

# 11. Update with empty title -> 400
code=$(request PUT /todos/1 '{"title":""}' '' "$C1")
assert_status 400 "$code"
assert_body_contains 'Title is required'

echo 11 OK

# 12. Partial update completed
code=$(request PUT /todos/1 '{"completed":true}' '' "$C1")
assert_status 200 "$code"
assert_body_contains '"completed":true'

echo 12 OK

# 13. Delete non-existent -> 404
code=$(request DELETE /todos/999 '' '' "$C1")
assert_status 404 "$code"
assert_body_contains 'Todo not found'

echo 13 OK

# 14. Delete existing -> 204 and no body
code=$(request DELETE /todos/1 '' '' "$C1")
assert_status 204 "$code"
if grep -qi '^Content-Type:.*application/json' "$tmpdir/headers.txt"; then echo 'DELETE should not have JSON content-type'; cat "$tmpdir/headers.txt"; exit 1; fi

# 15. List empty
code=$(request GET /todos '' '' "$C1")
assert_status 200 "$code"
if [[ "$(cat $tmpdir/body.txt)" != '[]' ]]; then echo 'Expected empty todos array'; cat "$tmpdir/body.txt"; exit 1; fi

echo 14-15 OK

# 16. Logout and ensure 401 afterwards
code=$(request POST /logout '' '' "$C1")
assert_status 200 "$code"
assert_header_contains '^Content-Type: application/json'

code=$(request GET /me '' '' "$C1")
assert_status 401 "$code"
assert_body_contains 'Authentication required'

echo 16 OK

# 17. Login again and change password
code=$(request POST /login '{"username":"user_one","password":"password123"}' "$C1")
assert_status 200 "$code"
code=$(request PUT /password '{"old_password":"wrong","new_password":"newpassword1"}' '' "$C1")
assert_status 401 "$code"
assert_body_contains 'Invalid credentials'

code=$(request PUT /password '{"old_password":"password123","new_password":"newpassword1"}' '' "$C1")
assert_status 200 "$code"

# 18. Logout and verify login old fails, new works
code=$(request POST /logout '' '' "$C1")
assert_status 200 "$code"
code=$(request POST /login '{"username":"user_one","password":"password123"}' "$C1")
assert_status 401 "$code"
code=$(request POST /login '{"username":"user_one","password":"newpassword1"}' "$C1")
assert_status 200 "$code"

echo 17-18 OK

# 19. User scoping check
code=$(request POST /register '{"username":"user_two","password":"passwordXYZ"}')
assert_status 201 "$code"
code=$(request POST /login '{"username":"user_two","password":"passwordXYZ"}' "$C2")
assert_status 200 "$code"
# user1 create two todos
code=$(request POST /todos '{"title":"U1-A"}' '' "$C1")
assert_status 201 "$code"
code=$(request POST /todos '{"title":"U1-B"}' '' "$C1")
assert_status 201 "$code"
# user2 tries to access a user1 todo ID that should not belong to them
code=$(request GET /todos/2 '' '' "$C2")
assert_status 404 "$code"

# cleanup
rm -rf "$tmpdir"

echo "All tests passed."