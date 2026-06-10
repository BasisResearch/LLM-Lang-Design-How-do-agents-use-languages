#!/usr/bin/env bash
set -euo pipefail
PORT=${1:-9097}
BASE="http://127.0.0.1:$PORT"
jar_curl(){
  curl -s -D /tmp/headers.$$ -o /tmp/body.$$ -w "%{http_code}" "$@"
}
get_cookie(){
  grep -i '^Set-Cookie:' /tmp/headers.$$ | sed -n 's/Set-Cookie: //Ip' | tr -d '\r' | head -n1 | cut -d';' -f1
}

pass(){ echo "[PASS] $1"; }
fail(){ echo "[FAIL] $1"; echo "Headers:"; cat /tmp/headers.$$; echo "Body:"; cat /tmp/body.$$; exit 1; }

# 1. Register
code=$(jar_curl -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
[[ "$code" == "201" ]] || fail "register expected 201"

# 1b. Duplicate username
code=$(jar_curl -X POST "$BASE/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
[[ "$code" == "409" ]] || fail "duplicate register expected 409"

# 2. Login
code=$(jar_curl -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
[[ "$code" == "200" ]] || fail "login expected 200"
cookie=$(get_cookie)
[[ "$cookie" == session_id=* ]] || fail "login missing Set-Cookie"

# 3. Get /me with auth
code=$(jar_curl -X GET "$BASE/me" -H "Cookie: $cookie")
[[ "$code" == "200" ]] || fail "/me expected 200"

# 4. Change password wrong old
code=$(jar_curl -X PUT "$BASE/password" -H "Cookie: $cookie" -H 'Content-Type: application/json' -d '{"old_password":"wrong","new_password":"newpassword123"}')
[[ "$code" == "401" ]] || fail "password change wrong old expected 401"

# 5. Change password correct
code=$(jar_curl -X PUT "$BASE/password" -H "Cookie: $cookie" -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$code" == "200" ]] || fail "password change expected 200"

# 6. Logout
code=$(jar_curl -X POST "$BASE/logout" -H "Cookie: $cookie")
[[ "$code" == "200" ]] || fail "logout expected 200"

# 7. Access after logout should be 401
code=$(jar_curl -X GET "$BASE/me" -H "Cookie: $cookie")
[[ "$code" == "401" ]] || fail "me after logout expected 401"

# 8. Login with new password
code=$(jar_curl -X POST "$BASE/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"newpassword123"}')
[[ "$code" == "200" ]] || fail "login 2 expected 200"
cookie=$(get_cookie)

# 9. Create todo missing title
code=$(jar_curl -X POST "$BASE/todos" -H "Cookie: $cookie" -H 'Content-Type: application/json' -d '{"description":"desc"}')
[[ "$code" == "400" ]] || fail "create todo missing title expected 400"

# 10. Create todo
code=$(jar_curl -X POST "$BASE/todos" -H "Cookie: $cookie" -H 'Content-Type: application/json' -d '{"title":"Task 1","description":"desc"}')
[[ "$code" == "201" ]] || fail "create todo expected 201"

# 11. List todos
code=$(jar_curl -X GET "$BASE/todos" -H "Cookie: $cookie")
[[ "$code" == "200" ]] || fail "list todos expected 200"

# 12. Get todo 1
code=$(jar_curl -X GET "$BASE/todos/1" -H "Cookie: $cookie")
[[ "$code" == "200" ]] || fail "get todo expected 200"

# 13. Update todo partially
code=$(jar_curl -X PUT "$BASE/todos/1" -H "Cookie: $cookie" -H 'Content-Type: application/json' -d '{"completed":true}')
[[ "$code" == "200" ]] || fail "update todo expected 200"

# 14. Delete todo
code=$(jar_curl -X DELETE "$BASE/todos/1" -H "Cookie: $cookie")
[[ "$code" == "204" ]] || fail "delete todo expected 204"

# 15. Get deleted todo
code=$(jar_curl -X GET "$BASE/todos/1" -H "Cookie: $cookie")
[[ "$code" == "404" ]] || fail "get deleted todo expected 404"

# 16. Auth required checks
code=$(jar_curl -X GET "$BASE/todos")
[[ "$code" == "401" ]] || fail "list without auth expected 401"

pass "All tests passed"