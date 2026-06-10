#!/usr/bin/env bash
set -euo pipefail
# choose a random free-ish port
PORT=$(( (RANDOM % 20000) + 30000 ))
BASE=http://127.0.0.1:$PORT
# Build release
( cd todo_server && cargo build --release >/dev/null 2>&1 || cargo build --release )
# Start server
./run.sh --port "$PORT" &
PID=$!
trap 'kill $PID; wait $PID 2>/dev/null || true' EXIT
# Wait a bit for the server to start
for i in {1..40}; do
  if curl -s -o /dev/null "$BASE/register"; then break; fi
  sleep 0.25
done

check_json_ct() {
  local hdr="$1"
  echo "$hdr" | awk 'BEGIN{IGNORECASE=1} /^content-type:/ {print tolower($0)}' | grep -q 'application/json'
}

# 1. Register
cat >/tmp/reg.json <<'JSON'
{"username":"user_1","password":"password123"}
JSON
hdr=$(curl -s -i -X POST "$BASE/register" -H 'Content-Type: application/json' --data-binary @/tmp/reg.json)
echo "$hdr" | grep -q " 201 "; check_json_ct "$hdr"

# 1b. Register duplicate -> 409
hdr=$(curl -s -i -X POST "$BASE/register" -H 'Content-Type: application/json' --data-binary @/tmp/reg.json)
echo "$hdr" | grep -q " 409 "; check_json_ct "$hdr"

# 2. Login
cat >/tmp/login.json <<'JSON'
{"username":"user_1","password":"password123"}
JSON
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt -X POST "$BASE/login" -H 'Content-Type: application/json' --data-binary @/tmp/login.json)
echo "$hdr" | grep -q " 200 "; echo "$hdr" | awk 'BEGIN{IGNORECASE=1} /^set-cookie:/ {print}' | grep -qi 'session_id='; check_json_ct "$hdr"

# 3. /me
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt "$BASE/me")
echo "$hdr" | grep -q " 200 "; check_json_ct "$hdr"

# 4. Create todo
cat >/tmp/t1.json <<'JSON'
{"title":"First","description":"desc"}
JSON
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt -X POST "$BASE/todos" -H 'Content-Type: application/json' --data-binary @/tmp/t1.json)
echo "$hdr" | grep -q " 201 "; check_json_ct "$hdr"
id=$(echo "$hdr" | tail -n1 | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
[ -n "$id" ] || { echo "Failed to parse todo id"; exit 1; }

# 5. List todos
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt "$BASE/todos")
echo "$hdr" | grep -q " 200 "; check_json_ct "$hdr"

# 6. Get todo
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt "$BASE/todos/$id")
echo "$hdr" | grep -q " 200 "; check_json_ct "$hdr"

# 7. Update todo partial
cat >/tmp/upd.json <<'JSON'
{"completed":true}
JSON
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt -X PUT "$BASE/todos/$id" -H 'Content-Type: application/json' --data-binary @/tmp/upd.json)
echo "$hdr" | grep -q " 200 "; check_json_ct "$hdr"

# 8. Delete todo
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt -X DELETE "$BASE/todos/$id")
echo "$hdr" | grep -q " 204 "; ! echo "$hdr" | awk 'BEGIN{IGNORECASE=1} /^content-type:/ {print}' | grep -qi .

# 9. Ensure 404 after delete
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt "$BASE/todos/$id")
echo "$hdr" | grep -q " 404 "; check_json_ct "$hdr"

# 10. Change password
cat >/tmp/pw.json <<'JSON'
{"old_password":"password123","new_password":"password456"}
JSON
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt -X PUT "$BASE/password" -H 'Content-Type: application/json' --data-binary @/tmp/pw.json)
echo "$hdr" | grep -q " 200 "; check_json_ct "$hdr"

# 11. Logout
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt -X POST "$BASE/logout")
echo "$hdr" | grep -q " 200 "; check_json_ct "$hdr"

# 12. Ensure session invalidated
hdr=$(curl -s -i -c /tmp/jar.txt -b /tmp/jar.txt "$BASE/me")
echo "$hdr" | grep -q " 401 "; check_json_ct "$hdr"

# 13. Login with new password works
cat >/tmp/login2.json <<'JSON'
{"username":"user_1","password":"password456"}
JSON
hdr=$(curl -s -i -c /tmp/jar2.txt -b /tmp/jar2.txt -X POST "$BASE/login" -H 'Content-Type: application/json' --data-binary @/tmp/login2.json)
echo "$hdr" | grep -q " 200 "; echo "$hdr" | awk 'BEGIN{IGNORECASE=1} /^set-cookie:/ {print}' | grep -qi 'session_id='; check_json_ct "$hdr"

kill $PID; wait $PID 2>/dev/null || true
trap - EXIT
