#!/usr/bin/env bash
set -euo pipefail

PORT=8098
BASE="http://127.0.0.1:$PORT"
COOKIE_JAR=$(mktemp)
COOKIE_JAR2=$(mktemp)
HDR=$(mktemp)
HDR2=$(mktemp)

cleanup() {
  rm -f "$COOKIE_JAR" "$COOKIE_JAR2" "$HDR" "$HDR2"
  if [[ -f /tmp/server.pid ]]; then
    kill "$(cat /tmp/server.pid)" || true
    rm -f /tmp/server.pid
  fi
}
trap cleanup EXIT

# Start server
./run.sh --port "$PORT" >/tmp/server.log 2>&1 & echo $! > /tmp/server.pid

# Wait for readiness up to 180s
ready=0
for i in $(seq 1 180); do
  code=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/me" || true)
  if [[ "$code" =~ ^(200|401|404)$ ]]; then
    ready=1
    break
  fi
  sleep 1
  if ! kill -0 "$(cat /tmp/server.pid)" 2>/dev/null; then
    echo "Server process exited prematurely. Last log:" >&2
    tail -n 200 /tmp/server.log >&2 || true
    exit 1
  fi
done
if [[ $ready -ne 1 ]]; then
  echo "Server did not become ready in time" >&2
  tail -n 200 /tmp/server.log >&2 || true
  exit 1
fi

# 1. Register new user
status=$(curl -sS -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -D "$HDR" -X POST "$BASE/register" --data '{"username":"alice_1","password":"password123"}')
[[ "$status" == "201" ]] || { echo "Register failed: $status"; cat /tmp/body.json; exit 1; }
cat /tmp/body.json | jq -e '.id > 0 and .username == "alice_1"' >/dev/null
grep -i '^content-type: application/json' "$HDR" >/dev/null

# 1b. Register same username -> 409
status=$(curl -sS -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/register" --data '{"username":"alice_1","password":"password123"}')
[[ "$status" == "409" ]] || { echo "Expected 409 on duplicate username, got $status"; exit 1; }

# 1c. Register invalid username -> 400
status=$(curl -sS -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/register" --data '{"username":"bad name","password":"password123"}')
[[ "$status" == "400" ]] || { echo "Expected 400 invalid username, got $status"; exit 1; }

# 2. Login wrong -> 401
status=$(curl -sS -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" --data '{"username":"alice_1","password":"wrong"}')
[[ "$status" == "401" ]] || { echo "Expected 401 invalid creds, got $status"; exit 1; }

# 3. Login correct -> 200 with Set-Cookie
status=$(curl -sS -c "$COOKIE_JAR" -D "$HDR" -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" --data '{"username":"alice_1","password":"password123"}')
[[ "$status" == "200" ]] || { echo "Login failed: $status"; cat /tmp/body.json; exit 1; }
cat /tmp/body.json | jq -e '.username == "alice_1"' >/dev/null
grep -i '^set-cookie: session_id=' "$HDR" | grep -i 'Path=/;' | grep -i 'HttpOnly' >/dev/null

# 4. /me with cookie
status=$(curl -sS -b "$COOKIE_JAR" -D "$HDR" -o /tmp/body.json -w "%{http_code}" "$BASE/me")
[[ "$status" == "200" ]] || { echo "/me failed: $status"; cat /tmp/body.json; exit 1; }
cat /tmp/body.json | jq -e '.username == "alice_1"' >/dev/null
grep -i '^content-type: application/json' "$HDR" >/dev/null

# 5. Change password wrong old -> 401
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X PUT "$BASE/password" --data '{"old_password":"nope","new_password":"newpassword123"}')
[[ "$status" == "401" ]] || { echo "Expected 401 on wrong old password, got $status"; exit 1; }

# 5b. Change password too short -> 400
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X PUT "$BASE/password" --data '{"old_password":"password123","new_password":"short"}')
[[ "$status" == "400" ]] || { echo "Expected 400 on short new password, got $status"; exit 1; }

# 5c. Change password correct -> 200
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X PUT "$BASE/password" --data '{"old_password":"password123","new_password":"newpassword123"}')
[[ "$status" == "200" ]] || { echo "Password change failed: $status"; cat /tmp/body.json; exit 1; }

# 6. Logout -> 200 and invalidate session
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/body.json -w "%{http_code}" -X POST "$BASE/logout")
[[ "$status" == "200" ]] || { echo "Logout failed: $status"; cat /tmp/body.json; exit 1; }

# 6b. Using same cookie should now be 401
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/body.json -w "%{http_code}" "$BASE/me")
[[ "$status" == "401" ]] || { echo "Expected 401 after logout, got $status"; exit 1; }

# 7. Login with old password should fail
status=$(curl -sS -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" --data '{"username":"alice_1","password":"password123"}')
[[ "$status" == "401" ]] || { echo "Expected 401 on old password, got $status"; exit 1; }

# 7b. Login with new password ok
status=$(curl -sS -c "$COOKIE_JAR" -o /tmp/body.json -D "$HDR" -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" --data '{"username":"alice_1","password":"newpassword123"}')
[[ "$status" == "200" ]] || { echo "Login with new password failed: $status"; cat /tmp/body.json; exit 1; }

# 8. Todos: list empty
status=$(curl -sS -b "$COOKIE_JAR" -D "$HDR" -o /tmp/body.json -w "%{http_code}" "$BASE/todos")
[[ "$status" == "200" ]] || { echo "List todos failed: $status"; exit 1; }
cat /tmp/body.json | jq -e 'type == "array" and length == 0' >/dev/null

# 9. Create todo missing title -> 400
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/todos" --data '{"title":""}')
[[ "$status" == "400" ]] || { echo "Expected 400 on empty title, got $status"; exit 1; }

# 10. Create valid todos
status=$(curl -sS -b "$COOKIE_JAR" -D "$HDR" -o /tmp/todo1.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/todos" --data '{"title":"Task A","description":"First"}')
[[ "$status" == "201" ]] || { echo "Create todo1 failed: $status"; cat /tmp/todo1.json; exit 1; }
ID1=$(jq -r '.id' /tmp/todo1.json)

status=$(curl -sS -b "$COOKIE_JAR" -D "$HDR" -o /tmp/todo2.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/todos" --data '{"title":"Task B"}')
[[ "$status" == "201" ]] || { echo "Create todo2 failed: $status"; cat /tmp/todo2.json; exit 1; }
ID2=$(jq -r '.id' /tmp/todo2.json)

# 11. Get todo by id
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/body.json -w "%{http_code}" "$BASE/todos/$ID1")
[[ "$status" == "200" ]] || { echo "Get todo by id failed: $status"; exit 1; }

# 12. Update todo partial: completed true
created_at=$(jq -r '.created_at' /tmp/todo1.json)
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/updated.json -w "%{http_code}" -H 'Content-Type: application/json' -X PUT "$BASE/todos/$ID1" --data '{"completed":true}')
[[ "$status" == "200" ]] || { echo "Update todo failed: $status"; cat /tmp/updated.json; exit 1; }
updated_at=$(jq -r '.updated_at' /tmp/updated.json)
[[ "$updated_at" != "$created_at" ]] || { echo "updated_at should change"; exit 1; }

# 12b. Update todo with empty title -> 400
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X PUT "$BASE/todos/$ID1" --data '{"title":""}')
[[ "$status" == "400" ]] || { echo "Expected 400 on empty title update, got $status"; exit 1; }

# 13. Delete todo2
status=$(curl -sS -b "$COOKIE_JAR" -D "$HDR" -o /tmp/body.json -w "%{http_code}" -X DELETE "$BASE/todos/$ID2")
[[ "$status" == "204" ]] || { echo "Expected 204 on delete, got $status"; exit 1; }

# 14. List todos and check ordering by id ascending
status=$(curl -sS -b "$COOKIE_JAR" -o /tmp/list.json -w "%{http_code}" "$BASE/todos")
[[ "$status" == "200" ]] || { echo "List after delete failed: $status"; exit 1; }
first_id=$(jq -r '.[0].id' /tmp/list.json)
[[ "$first_id" == "$ID1" ]] || { echo "Expected remaining todo to be ID $ID1, got $first_id"; exit 1; }

# 15. Auth required test: /me without cookie
status=$(curl -sS -o /tmp/body.json -w "%{http_code}" "$BASE/me")
[[ "$status" == "401" ]] || { echo "Expected 401 without auth on /me, got $status"; exit 1; }

# 16. Create second user and ensure 404 on accessing other's todo
status=$(curl -sS -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/register" --data '{"username":"bob_2","password":"password123"}')
[[ "$status" == "201" ]] || { echo "Register bob failed: $status"; exit 1; }
status=$(curl -sS -c "$COOKIE_JAR2" -o /tmp/body.json -w "%{http_code}" -H 'Content-Type: application/json' -X POST "$BASE/login" --data '{"username":"bob_2","password":"password123"}')
[[ "$status" == "200" ]] || { echo "Login bob failed: $status"; exit 1; }
status=$(curl -sS -b "$COOKIE_JAR2" -o /tmp/body.json -w "%{http_code}" "$BASE/todos/$ID1")
[[ "$status" == "404" ]] || { echo "Expected 404 when accessing other's todo, got $status"; exit 1; }

# 17. Content-Type application/json for non-DELETE
status=$(curl -sS -b "$COOKIE_JAR" -D "$HDR" -o /tmp/body.json -w "%{http_code}" "$BASE/todos")
[[ "$status" == "200" ]]
grep -i '^content-type: application/json' "$HDR" >/dev/null

# 18. DELETE should have no body (status 204 already checked)

echo "All tests passed."