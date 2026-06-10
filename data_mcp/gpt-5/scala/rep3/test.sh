#!/usr/bin/env bash
set -euo pipefail
PORT=18180
HOST=127.0.0.1
ROOT=http://$HOST:$PORT

# Ensure python3 is available
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required for tests" >&2
  exit 1
fi

# Start server
./run.sh --port "$PORT" >/tmp/server.log 2>&1 &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Wait for server to be up
for i in {1..60}; do
  if curl -s -o /dev/null "$ROOT/me"; then break; fi
  sleep 0.5
done

echo "1) Register user alice"
status=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' "$ROOT/register")
[ "$status" = "201" ] || { echo "Register failed: $status"; exit 1; }

echo "2) Register duplicate alice -> 409"
status=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' "$ROOT/register")
[ "$status" = "409" ] || { echo "Duplicate username not 409: $status"; exit 1; }

echo "3) Login alice"
resp=$(curl -s -c /tmp/cookies-alice.txt -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}' "$ROOT/login")
username=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["username"])')
[ "$username" = "alice" ] || { echo "Login response username mismatch: $username"; exit 1; }


echo "4) GET /me with auth"
resp=$(curl -s -b /tmp/cookies-alice.txt "$ROOT/me")
username=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["username"])')
[ "$username" = "alice" ] || { echo "GET /me username mismatch"; exit 1; }

echo "5) Change password wrong old -> 401"
status=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/cookies-alice.txt -H 'Content-Type: application/json' -X PUT -d '{"old_password":"wrong","new_password":"newpassword"}' "$ROOT/password")
[ "$status" = "401" ] || { echo "Expected 401 on wrong old password, got $status"; exit 1; }

echo "6) Change password correct -> 200 {}"
resp=$(curl -s -b /tmp/cookies-alice.txt -H 'Content-Type: application/json' -X PUT -d '{"old_password":"password123","new_password":"newpassword"}' "$ROOT/password")
empty=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(1 if d=={} else 0)')
[ "$empty" = "1" ] || { echo "Password change response not {}: $resp"; exit 1; }

echo "7) Logout"
resp=$(curl -s -b /tmp/cookies-alice.txt -X POST "$ROOT/logout")
empty=$(echo "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(1 if d=={} else 0)')
[ "$empty" = "1" ] || { echo "Logout response not {}"; exit 1; }

echo "8) Access after logout -> 401"
status=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/cookies-alice.txt "$ROOT/me")
[ "$status" = "401" ] || { echo "Expected 401 after logout, got $status"; exit 1; }

echo "9) Login with new password"
resp=$(curl -s -c /tmp/cookies-alice.txt -H 'Content-Type: application/json' -d '{"username":"alice","password":"newpassword"}' "$ROOT/login")
username=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["username"])')
[ "$username" = "alice" ] || { echo "Relogin failed"; exit 1; }

echo "10) Unauthorized GET /todos -> 401"
status=$(curl -s -o /dev/null -w "%{http_code}" "$ROOT/todos")
[ "$status" = "401" ] || { echo "Expected 401 on unauthenticated todos, got $status"; exit 1; }

echo "11) Create todo without title -> 400"
status=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/cookies-alice.txt -H 'Content-Type: application/json' -d '{"title":""}' "$ROOT/todos")
[ "$status" = "400" ] || { echo "Expected 400 on empty title, got $status"; exit 1; }

echo "12) Create todo"
resp=$(curl -s -b /tmp/cookies-alice.txt -H 'Content-Type: application/json' -d '{"title":"Buy milk","description":"2L"}' "$ROOT/todos")
TODO_ID=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
TITLE=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["title"])')
DESC=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["description"])')
COMP=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["completed"])')
CRE=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["created_at"])')
UPD=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["updated_at"])')
[ "$TITLE" = "Buy milk" ] || { echo "Bad title: $TITLE"; exit 1; }
[ "$DESC" = "2L" ] || { echo "Bad description: $DESC"; exit 1; }
[ "$COMP" = "False" -o "$COMP" = "false" ] || { echo "completed not false: $COMP"; exit 1; }
[ "$CRE" = "$UPD" ] || { echo "created_at and updated_at mismatch"; exit 1; }

echo "13) List todos"
resp=$(curl -s -b /tmp/cookies-alice.txt "$ROOT/todos")
count=$(echo "$resp" | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))')
[ "$count" = "1" ] || { echo "Expected 1 todo, got $count"; exit 1; }


echo "14) Get todo by id"
resp=$(curl -s -b /tmp/cookies-alice.txt "$ROOT/todos/$TODO_ID")
get_id=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
[ "$get_id" = "$TODO_ID" ] || { echo "GET /todos/:id id mismatch"; exit 1; }


echo "15) Partial update completed=true"
resp=$(curl -s -b /tmp/cookies-alice.txt -H 'Content-Type: application/json' -X PUT -d '{"completed":true}' "$ROOT/todos/$TODO_ID")
comp=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["completed"])')
upd2=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["updated_at"])')
[ "$comp" = "True" -o "$comp" = "true" ] || { echo "completed not true"; exit 1; }
[ "$upd2" != "$UPD" ] || { echo "updated_at did not change on update"; exit 1; }
UPD=$upd2


echo "16) Update with empty title -> 400"
status=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/cookies-alice.txt -H 'Content-Type: application/json' -X PUT -d '{"title":""}' "$ROOT/todos/$TODO_ID")
[ "$status" = "400" ] || { echo "Expected 400 for empty title update, got $status"; exit 1; }


echo "17) Update title and description"
resp=$(curl -s -b /tmp/cookies-alice.txt -H 'Content-Type: application/json' -X PUT -d '{"title":"Buy oat milk","description":"1L"}' "$ROOT/todos/$TODO_ID")
newTitle=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["title"])')
newDesc=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["description"])')
upd3=$(echo "$resp" | python3 -c 'import sys,json; print(json.load(sys.stdin)["updated_at"])')
[ "$newTitle" = "Buy oat milk" ] || { echo "Title not updated"; exit 1; }
[ "$newDesc" = "1L" ] || { echo "Description not updated"; exit 1; }
[ "$upd3" != "$UPD" ] || { echo "updated_at did not change on second update"; exit 1; }


echo "18) Create and login bob; he should not access alice's todo"
status=$(curl -s -o /dev/null -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"bob","password":"password123"}' "$ROOT/register" || true)
# allow 201 or 409 if rerun
if [ "$status" != "201" ] && [ "$status" != "409" ]; then echo "Register bob failed: $status"; exit 1; fi
curl -s -c /tmp/cookies-bob.txt -H 'Content-Type: application/json' -d '{"username":"bob","password":"password123"}' "$ROOT/login" >/dev/null
status=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/cookies-bob.txt "$ROOT/todos/$TODO_ID")
[ "$status" = "404" ] || { echo "Bob should get 404 on Alice's todo, got $status"; exit 1; }


echo "19) Delete todo as alice"
# relogin alice (ensure cookie valid)
curl -s -c /tmp/cookies-alice.txt -H 'Content-Type: application/json' -d '{"username":"alice","password":"newpassword"}' "$ROOT/login" >/dev/null
status=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/cookies-alice.txt -X DELETE "$ROOT/todos/$TODO_ID")
[ "$status" = "204" ] || { echo "Delete failed: $status"; exit 1; }


echo "20) Get deleted todo -> 404"
status=$(curl -s -o /dev/null -w "%{http_code}" -b /tmp/cookies-alice.txt "$ROOT/todos/$TODO_ID")
[ "$status" = "404" ] || { echo "Expected 404 after delete, got $status"; exit 1; }


echo "All tests passed."