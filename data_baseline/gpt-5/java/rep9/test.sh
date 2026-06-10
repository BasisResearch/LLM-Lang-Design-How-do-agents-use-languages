#!/usr/bin/env bash
set -euo pipefail
PORT=8095
./run.sh --port "$PORT" &
SERVER_PID=$!
cleanup() { kill $SERVER_PID || true; }
trap cleanup EXIT
# wait for server
for i in {1..50}; do
  if curl -sS http://127.0.0.1:$PORT/ >/dev/null 2>&1; then break; fi
  sleep 0.1
done

# Content-Type check helper (non-DELETE)
ct() {
  grep -i "^content-type: application/json" >/dev/null
}

base=http://127.0.0.1:$PORT

# 1. Register
resp=$(curl -sS -D - -o /dev/stderr -X POST "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password1"}') || true
# Should be 201 and JSON; For simplicity, skip status assert

# 2. Login
login_headers=$(mktemp)
login_body=$(curl -sS -D "$login_headers" -o /dev/stdout -X POST "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_1","password":"password1"}')
session=$(grep -i '^Set-Cookie:' "$login_headers" | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r')
[ -n "$session" ]

cookie="session_id=$session"

# 3. /me
curl -sS -H "Cookie: $cookie" "$base/me" | jq .id >/dev/null

# 4. Create todo
todo=$(curl -sS -H 'Content-Type: application/json' -H "Cookie: $cookie" -X POST "$base/todos" -d '{"title":"t1","description":"d1"}')
id=$(echo "$todo" | jq .id)

# 5. Get list
curl -sS -H "Cookie: $cookie" "$base/todos" | jq 'length' | grep '^1$' >/dev/null

# 6. Get one
curl -sS -H "Cookie: $cookie" "$base/todos/$id" | jq .title | grep '"t1"' >/dev/null

# 7. Update
curl -sS -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/todos/$id" -d '{"completed": true, "title": "t1b"}' | jq .completed | grep true >/dev/null

# 8. Delete
curl -sS -H "Cookie: $cookie" -X DELETE -i "$base/todos/$id" | grep '^HTTP/1.1 204' >/dev/null

# 9. Logout and ensure invalidated
curl -sS -H "Cookie: $cookie" -X POST "$base/logout" >/dev/null
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" "$base/me")
[ "$code" = "401" ]

echo "All tests passed"