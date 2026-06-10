#!/bin/sh
set -eu
PORT=34567
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT INT TERM
# Wait for server to start
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sS http://127.0.0.1:$PORT/ >/dev/null; then
    break
  fi
  sleep 0.2
done

base=http://127.0.0.1:$PORT

fail() { echo "TEST FAILED: $1" >&2; exit 1; }

# 1) Register
resp=$(curl -sS -D - -o /tmp/body1.txt -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
STATUS=$(printf %s "$resp" | awk 'NR==1{print $2}')
[ "$STATUS" = "201" ] || { cat /tmp/body1.txt; fail "register status"; }

# 2) Login
resp=$(curl -sS -D - -o /tmp/body2.txt -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}')
STATUS=$(printf %s "$resp" | awk 'NR==1{print $2}')
COOKIE=$(printf %s "$resp" | awk '/^Set-Cookie:/{print $2}' | tr -d '\r')
[ "$STATUS" = "200" ] || { cat /tmp/body2.txt; fail "login status"; }
[ -n "$COOKIE" ] || fail "no set-cookie"

cookie_header="Cookie: ${COOKIE%%;*}"

# 3) /me
curl -sS -D - -o /tmp/body3.txt -H "$cookie_header" "$base/me" >/tmp/headers3.txt
STATUS=$(head -1 /tmp/headers3.txt | awk '{print $2}')
[ "$STATUS" = "200" ] || { cat /tmp/body3.txt; fail "/me status"; }

# 4) Create todo
resp=$(curl -sS -D - -o /tmp/body4.txt -X POST "$base/todos" -H 'Content-Type: application/json' -H "$cookie_header" -d '{"title":"Buy milk","description":"2%"}')
STATUS=$(printf %s "$resp" | awk 'NR==1{print $2}')
[ "$STATUS" = "201" ] || { cat /tmp/body4.txt; fail "create todo status"; }
ID=$(sed -n 's/.*"id":\([0-9]*\).*/\1/p' /tmp/body4.txt)
[ -n "$ID" ] || fail "todo id missing"

# 5) Get all todos
curl -sS -D - -o /tmp/body5.txt -H "$cookie_header" "$base/todos" >/tmp/headers5.txt
STATUS=$(head -1 /tmp/headers5.txt | awk '{print $2}')
[ "$STATUS" = "200" ] || { cat /tmp/body5.txt; fail "list todos status"; }

# 6) Get one todo
curl -sS -D - -o /tmp/body6.txt -H "$cookie_header" "$base/todos/$ID" >/tmp/headers6.txt
STATUS=$(head -1 /tmp/headers6.txt | awk '{print $2}')
[ "$STATUS" = "200" ] || { cat /tmp/body6.txt; fail "get todo status"; }

# 7) Update todo
curl -sS -D - -o /tmp/body7.txt -X PUT -H 'Content-Type: application/json' -H "$cookie_header" "$base/todos/$ID" -d '{"completed":true}' >/tmp/headers7.txt
STATUS=$(head -1 /tmp/headers7.txt | awk '{print $2}')
[ "$STATUS" = "200" ] || { cat /tmp/body7.txt; fail "update todo status"; }

# 8) Delete todo
curl -sS -D - -o /tmp/body8.txt -X DELETE -H "$cookie_header" "$base/todos/$ID" >/tmp/headers8.txt || true
STATUS=$(head -1 /tmp/headers8.txt | awk '{print $2}')
[ "$STATUS" = "204" ] || { cat /tmp/body8.txt; fail "delete todo status"; }

# 9) Get deleted todo should 404
curl -sS -D - -o /tmp/body9.txt -H "$cookie_header" "$base/todos/$ID" >/tmp/headers9.txt || true
STATUS=$(head -1 /tmp/headers9.txt | awk '{print $2}')
[ "$STATUS" = "404" ] || { cat /tmp/body9.txt; fail "get deleted todo should 404"; }

# 10) Change password
curl -sS -D - -o /tmp/body10.txt -X PUT -H 'Content-Type: application/json' -H "$cookie_header" "$base/password" -d '{"old_password":"password123","new_password":"newpass456"}' >/tmp/headers10.txt
STATUS=$(head -1 /tmp/headers10.txt | awk '{print $2}')
[ "$STATUS" = "200" ] || { cat /tmp/body10.txt; fail "password change status"; }

# 11) Logout
curl -sS -D - -o /tmp/body11.txt -X POST -H "$cookie_header" "$base/logout" >/tmp/headers11.txt
STATUS=$(head -1 /tmp/headers11.txt | awk '{print $2}')
[ "$STATUS" = "200" ] || { cat /tmp/body11.txt; fail "logout status"; }

# 12) Login with old password should fail
curl -sS -D - -o /tmp/body12.txt -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' >/tmp/headers12.txt || true
STATUS=$(head -1 /tmp/headers12.txt | awk '{print $2}')
[ "$STATUS" = "401" ] || { cat /tmp/body12.txt; fail "login old password should fail"; }

# 13) Login with new password should succeed
resp=$(curl -sS -D - -o /tmp/body13.txt -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpass456"}')
STATUS=$(printf %s "$resp" | awk 'NR==1{print $2}')
COOKIE2=$(printf %s "$resp" | awk '/^Set-Cookie:/{print $2}' | tr -d '\r')
[ "$STATUS" = "200" ] || { cat /tmp/body13.txt; fail "login new password status"; }
[ -n "$COOKIE2" ] || fail "no set-cookie 2"

cookie_header2="Cookie: ${COOKIE2%%;*}"

# 14) /me with new session works
curl -sS -D - -o /tmp/body14.txt -H "$cookie_header2" "$base/me" >/tmp/headers14.txt
STATUS=$(head -1 /tmp/headers14.txt | awk '{print $2}')
[ "$STATUS" = "200" ] || { cat /tmp/body14.txt; fail "/me new session status"; }

echo "All tests passed"