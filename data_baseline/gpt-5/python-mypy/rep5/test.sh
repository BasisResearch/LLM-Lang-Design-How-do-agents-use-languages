#!/bin/sh
set -euo pipefail

# Find a free port
PORT=$(python3 - <<'PY'
import socket
s=socket.socket()
s.bind(('127.0.0.1',0))
print(s.getsockname()[1])
s.close()
PY
)

echo "Using port $PORT" >&2
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

# wait for server and ensure our process is alive
for i in `seq 1 100`; do
  if kill -0 $SERVER_PID 2>/dev/null; then
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/does-not-exist"; then
      break
    fi
  else
    echo "Server process exited unexpectedly" >&2
    exit 1
  fi
  sleep 0.1
done

base="http://127.0.0.1:$PORT"

# 1. Register
curl -s -D /tmp/headers1 -H 'Content-Type: application/json' -X POST "$base/register" -d '{"username":"alice_1","password":"password123"}' | jq . > /tmp/reg.json
if [ "$(jq -r .username /tmp/reg.json)" != "alice_1" ]; then echo register failed; cat /tmp/reg.json; exit 1; fi

# 2. Login
curl -s -i -H 'Content-Type: application/json' -X POST "$base/login" -d '{"username":"alice_1","password":"password123"}' > /tmp/login.out
SESSION=$(grep -i '^Set-Cookie:' /tmp/login.out | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r\n')
if [ -z "$SESSION" ]; then echo login failed; cat /tmp/login.out; exit 1; fi

cookie="session_id=$SESSION"

# 3. Me
curl -s -H "Cookie: $cookie" "$base/me" | jq . > /tmp/me.json
if [ "$(jq -r .username /tmp/me.json)" != "alice_1" ]; then echo me failed; exit 1; fi

# 4. Change password
curl -s -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/password" -d '{"old_password":"password123","new_password":"newpassword456"}' | jq . > /tmp/pw.json

# 5. Create todo
curl -s -H 'Content-Type: application/json' -H "Cookie: $cookie" -X POST "$base/todos" -d '{"title":"Task 1","description":"Do something"}' | jq . > /tmp/t1.json
TID=$(jq -r .id /tmp/t1.json)

# 6. List todos
curl -s -H "Cookie: $cookie" "$base/todos" | jq . > /tmp/list.json

# 7. Get todo by id
curl -s -H "Cookie: $cookie" "$base/todos/$TID" | jq . > /tmp/get1.json

# 8. Update todo
curl -s -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/todos/$TID" -d '{"completed":true}' | jq . > /tmp/upd.json

# 9. Delete todo
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" -X DELETE "$base/todos/$TID")
if [ "$code" != "204" ]; then echo delete failed; exit 1; fi

# 10. Logout
curl -s -H "Cookie: $cookie" -X POST "$base/logout" | jq . > /tmp/logout.json

# 11. Access after logout should 401
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" "$base/me")
if [ "$code" != "401" ]; then echo post-logout auth failed; exit 1; fi

echo OK
