#!/usr/bin/env bash
set -euo pipefail
PORT=8099
./run.sh --port $PORT &
SERVER_PID=$!
cleanup(){ kill $SERVER_PID 2>/dev/null || true; }
trap cleanup EXIT
base="http://127.0.0.1:$PORT"

# Wait for server up to 15s
for i in {1..150}; do
  if curl -s -o /dev/null -m 0.5 "$base/"; then break; fi
  sleep 0.1
  if [[ $i -eq 150 ]]; then echo "Server failed to start"; exit 1; fi
done

hdr='-H Content-Type:application/json'

# 1. Register
resp=$(curl -sS -X POST $hdr -d '{"username":"alice","password":"password123"}' $base/register)
echo "$resp" | grep '"username":"alice"' >/dev/null

# 2. Login
headers_file=$(mktemp)
resp=$(curl -sS -D $headers_file -X POST $hdr -d '{"username":"alice","password":"password123"}' $base/login)
echo "$resp" | grep '"username":"alice"' >/dev/null
cookie=$(grep -i '^Set-Cookie:' $headers_file | sed -n 's/.*session_id=\([^;]*\).*/\1/p' | tr -d '\r\n')
if [[ -z "$cookie" ]]; then echo "No cookie"; exit 1; fi
cookie_hdr=("-H" "Cookie: session_id=$cookie")

# 3. /me
curl -sS "${cookie_hdr[@]}" $base/me | grep '"username":"alice"' >/dev/null

# 4. Create todo
resp=$(curl -sS -X POST $hdr "${cookie_hdr[@]}" -d '{"title":"Task1","description":"Desc"}' $base/todos)
echo "$resp" | grep '"id":1' >/dev/null

# 5. List todos
curl -sS "${cookie_hdr[@]}" $base/todos | grep '"id":1' >/dev/null

# 6. Get todo 1
curl -sS "${cookie_hdr[@]}" $base/todos/1 | grep '"id":1' >/dev/null

# 7. Update todo 1
resp=$(curl -sS -X PUT $hdr "${cookie_hdr[@]}" -d '{"completed":true}' $base/todos/1)
echo "$resp" | grep '"completed":true' >/dev/null

# 8. Delete todo 1
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "${cookie_hdr[@]}" $base/todos/1)
[[ "$code" == "204" ]]

# 9. Logout
curl -sS -X POST "${cookie_hdr[@]}" $base/logout >/dev/null

# 10. Access after logout should be 401
code=$(curl -s -o /dev/null -w '%{http_code}' "${cookie_hdr[@]}" $base/me)
[[ "$code" == "401" ]]

echo "All tests passed"
