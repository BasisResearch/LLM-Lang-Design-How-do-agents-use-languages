#!/usr/bin/env bash
set -euo pipefail

# Pick a free TCP port
PORT=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)

./run.sh --port "$PORT" &
PID=$!
cleanup(){
  kill $PID >/dev/null 2>&1 || true
  rm -f "$HEAD" "$BODY"
}
trap cleanup EXIT
sleep 0.5

base=http://127.0.0.1:$PORT

HEAD=$(mktemp)
BODY=$(mktemp)

# Helper to perform request and capture headers/body
curl_json(){
  : > "$HEAD"; : > "$BODY"
  curl -sS -D "$HEAD" -H 'Content-Type: application/json' "$@" -o "$BODY"
}

json_get(){
  python3 - "$BODY" "$@" <<'PY'
import json,sys
path=sys.argv[2:]
with open(sys.argv[1],'rb') as f:
    j=json.load(f)
val=j
for k in path:
    if isinstance(val,list) and k.isdigit():
        val=val[int(k)]
    else:
        val=val[k]
if isinstance(val,(dict,list)):
    import json as _j; print(_j.dumps(val, separators=(',',':')))
else:
    print(val)
PY
}

# Register
curl_json -X POST "$base/register" --data '{"username":"alice_1","password":"password123"}'
[[ "$(json_get username)" == "alice_1" ]]
[[ "$(grep -i '^Content-Type:' "$HEAD" | tr -d '\r' | awk '{print $2}')" == "application/json" ]]

# Duplicate register should 409
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/register" --data '{"username":"alice_1","password":"password123"}')
[[ "$code" == "409" ]]

# Login
curl_json -X POST "$base/login" --data '{"username":"alice_1","password":"password123"}'
sid=$(grep -i '^Set-Cookie:' "$HEAD" | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | head -n1)
[[ -n "$sid" ]]

cookie="session_id=$sid"

# /me
curl_json -H "Cookie: $cookie" "$base/me"

# Change password wrong old -> 401
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/password" --data '{"old_password":"bad","new_password":"newpassword"}')
[[ "$code" == "401" ]]

# Change password ok
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H "Cookie: $cookie" -X PUT "$base/password" --data '{"old_password":"password123","new_password":"newpassword"}')
[[ "$code" == "200" ]]

# Create todos
curl_json -H "Cookie: $cookie" -X POST "$base/todos" --data '{"title":"Task 1","description":"Desc"}'
curl_json -H "Cookie: $cookie" -X POST "$base/todos" --data '{"title":"Task 2"}'

# List todos
curl_json -H "Cookie: $cookie" "$base/todos"
count=$(python3 - "$BODY" <<'PY'
import json,sys
print(len(json.load(open(sys.argv[1],'rb'))))
PY
)
[[ "$count" -ge 2 ]]

# Get first id
first_id=$(python3 - "$BODY" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],'rb'))[0]['id'])
PY
)

# Get todo by id
curl_json -H "Cookie: $cookie" "$base/todos/$first_id"

# Update todo
curl_json -H "Cookie: $cookie" -X PUT "$base/todos/$first_id" --data '{"completed":true}'

# Delete todo
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" -X DELETE "$base/todos/$first_id")
[[ "$code" == "204" ]]

# Logout
curl_json -H "Cookie: $cookie" -X POST "$base/logout"

# Requests after logout should 401
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Cookie: $cookie" "$base/me")
[[ "$code" == "401" ]]

echo "All tests passed"