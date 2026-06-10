#!/usr/bin/env bash
set -euo pipefail
PORT=5005
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() {
  kill $SERVER_PID >/dev/null 2>&1 || true
}
trap cleanup EXIT
# Wait for server
for i in {1..50}; do
  if curl -sS http://127.0.0.1:$PORT/me -H 'Accept: application/json' -b 'session_id=invalid' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

base="http://127.0.0.1:$PORT"

# 1. Register
resp=$(curl -sS -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
echo "register: $resp"
# 2. Login
login_resp=$(curl -i -sS -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}')
echo "$login_resp" | sed -n '1,5p'
session=$(echo "$login_resp" | awk -F '[:; ]+' '/Set-Cookie:/{for(i=1;i<=NF;i++){if($i ~ /^session_id=/){print substr($i,12); exit}}}')
if [[ -z "$session" ]]; then
  echo "Failed to capture session cookie" >&2; exit 1
fi
echo "session=$session"
# 3. /me
me=$(curl -sS "$base/me" -b "session_id=$session")
echo "me: $me"
# 4. Create todo
created=$(curl -sS -X POST "$base/todos" -H 'Content-Type: application/json' -b "session_id=$session" -d '{"title":"Task 1","description":"Demo"}')
echo "created: $created"
id=$(echo "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
# 5. List todos
list=$(curl -sS "$base/todos" -b "session_id=$session")
echo "list: $list"
# 6. Get todo
one=$(curl -sS "$base/todos/$id" -b "session_id=$session")
echo "one: $one"
# 7. Update todo
upd=$(curl -sS -X PUT "$base/todos/$id" -H 'Content-Type: application/json' -b "session_id=$session" -d '{"completed": true, "title": "Task 1 updated"}')
echo "upd: $upd"
# 8. Delete todo
code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE "$base/todos/$id" -b "session_id=$session")
echo "delete code: $code"
# 9. Logout
logout=$(curl -sS -X POST "$base/logout" -b "session_id=$session")
echo "logout: $logout"
# 10. Ensure session invalidated
post_logout_code=$(curl -sS -o /dev/null -w "%{http_code}" "$base/me" -b "session_id=$session")
echo "post logout /me code: $post_logout_code"
