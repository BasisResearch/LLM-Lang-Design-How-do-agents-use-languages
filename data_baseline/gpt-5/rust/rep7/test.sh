#!/usr/bin/env bash
set -euo pipefail

PORT=$(( 12000 + (RANDOM % 2000) ))
BASE="http://127.0.0.1:$PORT"

./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true' EXIT

# Wait for readiness by expecting non-000 http code on /me
for i in {1..100}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X GET "$BASE/me" || true)
  if [[ "$code" != "000" ]]; then
    break
  fi
  sleep 0.1
done

fail() { echo "TEST FAILED: $1"; exit 1; }

# Register
out=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H 'Content-Type: application/json' --data '{"username":"user_1","password":"password123"}')
body=$(echo "$out" | head -n1)
code=$(echo "$out" | tail -n1)
[[ "$code" == "201" ]] || fail "register code $code body $body"

# Duplicate register
out=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H 'Content-Type: application/json' --data '{"username":"user_1","password":"password123"}')
code=$(echo "$out" | tail -n1)
[[ "$code" == "409" ]] || fail "dup register code $code"

# Login
hdr=$(mktemp)
code=$(curl -s -o /dev/null -w '%{http_code}' -D "$hdr" -X POST "$BASE/login" -H 'Content-Type: application/json' --data '{"username":"user_1","password":"password123"}')
[[ "$code" == "200" ]] || { echo "Headers:"; cat "$hdr"; fail "login code $code"; }
cookie=$(grep -i '^Set-Cookie:' "$hdr" | sed -E 's/.*session_id=([^;]+).*/\1/i' | tr -d '\r')
rm -f "$hdr"
[[ -n "$cookie" ]] || fail "no session cookie"

# /me
out=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -H "Cookie: session_id=$cookie")
code=$(echo "$out" | tail -n1)
[[ "$code" == "200" ]] || fail "/me code $code"

# Change password wrong old
out=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' -H "Cookie: session_id=$cookie" --data '{"old_password":"wrong","new_password":"newpassword1"}')
code=$(echo "$out" | tail -n1)
[[ "$code" == "401" ]] || fail "password change wrong old $code"

# Change password good
out=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" -H 'Content-Type: application/json' -H "Cookie: session_id=$cookie" --data '{"old_password":"password123","new_password":"newpassword1"}')
code=$(echo "$out" | tail -n1)
[[ "$code" == "200" ]] || fail "password change $code"

# Logout
out=$(curl -s -w "\n%{http_code}" -X POST "$BASE/logout" -H "Cookie: session_id=$cookie")
code=$(echo "$out" | tail -n1)
[[ "$code" == "200" ]] || fail "logout $code"

# /me should be 401 after logout
out=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me")
code=$(echo "$out" | tail -n1)
[[ "$code" == "401" ]] || fail "/me after logout $code"

# Login again with new password
hdr=$(mktemp)
code=$(curl -s -o /dev/null -w '%{http_code}' -D "$hdr" -X POST "$BASE/login" -H 'Content-Type: application/json' --data '{"username":"user_1","password":"newpassword1"}')
[[ "$code" == "200" ]] || { echo "Headers2:"; cat "$hdr"; fail "login2 code $code"; }
cookie=$(grep -i '^Set-Cookie:' "$hdr" | sed -E 's/.*session_id=([^;]+).*/\1/i' | tr -d '\r')
rm -f "$hdr"

# Create todos
out=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -H 'Content-Type: application/json' -H "Cookie: session_id=$cookie" --data '{"title":"First","description":"A"}')
code=$(echo "$out" | tail -n1)
[[ "$code" == "201" ]] || fail "create todo1 $code"

out=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -H 'Content-Type: application/json' -H "Cookie: session_id=$cookie" --data '{"title":"Second","description":"B"}')
code=$(echo "$out" | tail -n1)
[[ "$code" == "201" ]] || fail "create todo2 $code"

# List
out=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos" -H "Cookie: session_id=$cookie")
code=$(echo "$out" | tail -n1)
[[ "$code" == "200" ]] || fail "list $code"

# Get one
out=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/1" -H "Cookie: session_id=$cookie")
code=$(echo "$out" | tail -n1)
[[ "$code" == "200" ]] || fail "get 1 $code"

# Update
out=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/1" -H 'Content-Type: application/json' -H "Cookie: session_id=$cookie" --data '{"completed":true}')
code=$(echo "$out" | tail -n1)
[[ "$code" == "200" ]] || fail "update 1 $code"

# Delete
out=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/todos/2" -H "Cookie: session_id=$cookie")
code=$(echo "$out" | tail -n1)
[[ "$code" == "204" ]] || fail "delete 2 $code"

# Get deleted should 404
out=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/2" -H "Cookie: session_id=$cookie")
code=$(echo "$out" | tail -n1)
[[ "$code" == "404" ]] || fail "get deleted $code"

# Ensure content-type is application/json for non-DELETE
ct=$(curl -sI -X GET "$BASE/me" -H "Cookie: session_id=$cookie" | tr -d '\r' | grep -i '^Content-Type:' | head -n1 | cut -d':' -f2- | tr -d ' ')
[[ "$ct" == "application/json" ]] || fail "content type wrong: $ct"

echo "All tests passed"