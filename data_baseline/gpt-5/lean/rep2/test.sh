#!/usr/bin/env bash
set -euo pipefail
PORT=8124
./run.sh --port "$PORT" >/tmp/todo_lean.out 2>&1 &
PID=$!
sleep 2
base="http://127.0.0.1:$PORT"
# Register
curl -sS -D /tmp/h -o /tmp/r1 -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}'
cat /tmp/r1; echo
# Login
curl -sS -D /tmp/h2 -o /tmp/r2 -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"alice","password":"password123"}'
cat /tmp/r2; echo
cookie=$(grep -i '^Set-Cookie:' /tmp/h2 | sed -E 's/.*session_id=([^;]+).*/\1/i' | tr -d '\r\n')
# Me unauthorized check
curl -sS -D /tmp/hu -o /tmp/ru "$base/me" || true
# Me authorized
curl -sS -b "session_id=$cookie" -o /tmp/me "$base/me"; cat /tmp/me; echo
# Create todo
curl -sS -b "session_id=$cookie" -H 'Content-Type: application/json' -d '{"title":"t1","description":"d"}' -o /tmp/tc "$base/todos"; cat /tmp/tc; echo
id=$(jq -r '.id' /tmp/tc 2>/dev/null || grep -o '"id":[0-9]*' /tmp/tc | head -n1 | tr -dc '0-9')
# Get todo
curl -sS -b "session_id=$cookie" -o /tmp/tg "$base/todos/$id"; cat /tmp/tg; echo
# List todos
curl -sS -b "session_id=$cookie" -o /tmp/tl "$base/todos"; cat /tmp/tl; echo
# Update todo
curl -sS -b "session_id=$cookie" -H 'Content-Type: application/json' -d '{"completed":true}' -o /tmp/tu -X PUT "$base/todos/$id"; cat /tmp/tu; echo
# Delete todo
curl -sS -b "session_id=$cookie" -X DELETE -D /tmp/hd "$base/todos/$id" -o /tmp/td; echo DONE
kill $PID || true
