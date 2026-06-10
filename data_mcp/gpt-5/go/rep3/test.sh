#!/usr/bin/env bash
set -euo pipefail
PORT=8090
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR1="/tmp/todo_cookie1.txt"
COOKIE_JAR2="/tmp/todo_cookie2.txt"
rm -f "$COOKIE_JAR1" "$COOKIE_JAR2"

./run.sh --port "$PORT" &
SRV_PID=$!
cleanup() {
  kill $SRV_PID 2>/dev/null || true
  wait $SRV_PID 2>/dev/null || true
}
trap cleanup EXIT

# wait for server ready
for i in {1..50}; do
  if curl -s -o /dev/null "$BASE/me"; then
    break
  fi
  sleep 0.1
  if [[ $i -eq 50 ]]; then
    echo "Server did not start in time" >&2
    exit 1
  fi
done

echo "Testing register user1..."
code=$(curl -s -o /tmp/resp1.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/register" -d '{"username":"user_one","password":"password123"}')
[[ "$code" == "201" ]] || { echo "Register failed code=$code"; cat /tmp/resp1.json; exit 1; }

echo "Testing duplicate username..."
code=$(curl -s -o /tmp/respdup.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/register" -d '{"username":"user_one","password":"anotherpass"}')
[[ "$code" == "409" ]] || { echo "Expected 409, got $code"; cat /tmp/respdup.json; exit 1; }

echo "Testing login wrong password..."
code=$(curl -s -o /tmp/login_wrong.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" -d '{"username":"user_one","password":"wrong"}')
[[ "$code" == "401" ]] || { echo "Expected 401, got $code"; cat /tmp/login_wrong.json; exit 1; }

echo "Testing login user1..."
code=$(curl -s -c "$COOKIE_JAR1" -o /tmp/login1.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" -d '{"username":"user_one","password":"password123"}')
[[ "$code" == "200" ]] || { echo "Login failed code=$code"; cat /tmp/login1.json; exit 1; }

echo "Testing /me..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/me1.json -w "%{http_code}" "$BASE/me")
[[ "$code" == "200" ]] || { echo "/me failed code=$code"; cat /tmp/me1.json; exit 1; }

echo "Testing create todo missing title..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/todo_missing.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/todos" -d '{"description":"desc"}')
[[ "$code" == "400" ]] || { echo "Expected 400, got $code"; cat /tmp/todo_missing.json; exit 1; }

echo "Testing create todo 1..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/todo1.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/todos" -d '{"title":"Task 1","description":"First"}')
[[ "$code" == "201" ]] || { echo "Create todo failed code=$code"; cat /tmp/todo1.json; exit 1; }

echo "Testing list todos..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/todos.json -w "%{http_code}" "$BASE/todos")
[[ "$code" == "200" ]] || { echo "List todos failed code=$code"; cat /tmp/todos.json; exit 1; }

echo "Testing get todo 1..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/todo_get1.json -w "%{http_code}" "$BASE/todos/1")
[[ "$code" == "200" ]] || { echo "Get todo 1 failed code=$code"; cat /tmp/todo_get1.json; exit 1; }

echo "Testing update todo 1 (completed=true)..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/todo_upd1.json -w "%{http_code}" -H 'Content-Type: application/json' -X PUT "$BASE/todos/1" -d '{"completed":true}')
[[ "$code" == "200" ]] || { echo "Update todo failed code=$code"; cat /tmp/todo_upd1.json; exit 1; }

echo "Testing update todo 1 with empty title (expect 400)..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/todo_upd_bad.json -w "%{http_code}" -H 'Content-Type: application/json' -X PUT "$BASE/todos/1" -d '{"title":""}')
[[ "$code" == "400" ]] || { echo "Expected 400, got $code"; cat /tmp/todo_upd_bad.json; exit 1; }

echo "Testing delete todo 1..."
# Capture body length to ensure no body
body=$(mktemp)
code=$(curl -s -b "$COOKIE_JAR1" -o "$body" -w "%{http_code}" -X DELETE "$BASE/todos/1")
[[ "$code" == "204" ]] || { echo "Delete todo failed code=$code"; cat "$body"; exit 1; }
if [[ -s "$body" ]]; then echo "DELETE response should have no body"; cat "$body"; exit 1; fi
rm -f "$body"

echo "Testing get deleted todo (expect 404)..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/todo_get_deleted.json -w "%{http_code}" "$BASE/todos/1")
[[ "$code" == "404" ]] || { echo "Expected 404, got $code"; cat /tmp/todo_get_deleted.json; exit 1; }

echo "Testing logout..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/logout.json -w "%{http_code}" -X POST "$BASE/logout")
[[ "$code" == "200" ]] || { echo "Logout failed code=$code"; cat /tmp/logout.json; exit 1; }

echo "Testing /me after logout (expect 401)..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/me_post_logout.json -w "%{http_code}" "$BASE/me")
[[ "$code" == "401" ]] || { echo "Expected 401, got $code"; cat /tmp/me_post_logout.json; exit 1; }

echo "Testing login again for password change..."
code=$(curl -s -c "$COOKIE_JAR1" -o /tmp/login_again.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" -d '{"username":"user_one","password":"password123"}')
[[ "$code" == "200" ]] || { echo "Re-login failed code=$code"; cat /tmp/login_again.json; exit 1; }

echo "Testing change password..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/pwchange.json -w "%{http_code}" -H 'Content-Type: application/json' -X PUT "$BASE/password" -d '{"old_password":"password123","new_password":"newpass456"}')
[[ "$code" == "200" ]] || { echo "Password change failed code=$code"; cat /tmp/pwchange.json; exit 1; }

echo "Logout after password change..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/logout2.json -w "%{http_code}" -X POST "$BASE/logout")
[[ "$code" == "200" ]] || { echo "Logout2 failed code=$code"; cat /tmp/logout2.json; exit 1; }

echo "Login with old password should fail..."
code=$(curl -s -o /tmp/login_oldpw.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" -d '{"username":"user_one","password":"password123"}')
[[ "$code" == "401" ]] || { echo "Expected 401, got $code"; cat /tmp/login_oldpw.json; exit 1; }

echo "Login with new password should succeed..."
code=$(curl -s -c "$COOKIE_JAR1" -o /tmp/login_newpw.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" -d '{"username":"user_one","password":"newpass456"}')
[[ "$code" == "200" ]] || { echo "Login with new password failed code=$code"; cat /tmp/login_newpw.json; exit 1; }

echo "Create user2 and todo..."
code=$(curl -s -o /tmp/reg2.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/register" -d '{"username":"user_two","password":"password234"}')
[[ "$code" == "201" ]] || { echo "Register user2 failed code=$code"; cat /tmp/reg2.json; exit 1; }
code=$(curl -s -c "$COOKIE_JAR2" -o /tmp/login2.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" -d '{"username":"user_two","password":"password234"}')
[[ "$code" == "200" ]] || { echo "Login user2 failed code=$code"; cat /tmp/login2.json; exit 1; }
code=$(curl -s -b "$COOKIE_JAR2" -o /tmp/todo2.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/todos" -d '{"title":"U2 Task","description":"Second user"}')
[[ "$code" == "201" ]] || { echo "Create user2 todo failed code=$code"; cat /tmp/todo2.json; exit 1; }

echo "Try to access user2's todo with user1 session (should 404)..."
code=$(curl -s -b "$COOKIE_JAR1" -o /tmp/u2_by_u1.json -w "%{http_code}" "$BASE/todos/2")
[[ "$code" == "404" ]] || { echo "Expected 404, got $code"; cat /tmp/u2_by_u1.json; exit 1; }

echo "All tests passed"
