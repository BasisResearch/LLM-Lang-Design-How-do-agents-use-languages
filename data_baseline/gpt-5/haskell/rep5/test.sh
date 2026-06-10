#!/usr/bin/env bash
set -euo pipefail
PORT=8109
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID' EXIT
BASE="http://127.0.0.1:$PORT"
J='-H Content-Type: application/json'

# wait for server
for i in {1..60}; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/me" || true)
  if [[ "$code" =~ ^(200|401|400|404)$ ]]; then break; fi
  sleep 0.5
  if [[ $i -eq 60 ]]; then echo "Server failed to start"; exit 1; fi
done

# Global vars for req
body=""
code=0

# Helper to request and capture code and body
req() {
  local method=$1
  local url=$2
  shift 2 || true
  local tmpb
  tmpb=$(mktemp)
  local raw
  raw=$(curl -s -o "$tmpb" -w '%{http_code}' -X "$method" "$url" "$@") || true
  body=$(cat "$tmpb")
  rm -f "$tmpb"
  code=$(echo -n "$raw" | head -c 3)
  echo "$code"
}

# register
code=$(req POST "$BASE/register" $J -d '{"username":"alice_1","password":"secretpass"}')
[[ "$code" == "201" ]] || { echo "register failed: $code $body"; exit 1; }

# duplicate register
code=$(req POST "$BASE/register" $J -d '{"username":"alice_1","password":"secretpass"}')
[[ "$code" == "409" ]] || { echo "dup register failed: $code $body"; exit 1; }

# login
tmp=$(mktemp)
curl -i -s $J -X POST "$BASE/login" -d '{"username":"alice_1","password":"secretpass"}' > "$tmp"
COOKIE=$(awk '/Set-Cookie/ {print $2}' "$tmp" | tr -d '\r')
rm -f "$tmp"
[[ -n "$COOKIE" ]] || { echo "no cookie from login"; exit 1; }

# me
code=$(req GET "$BASE/me" -H "Cookie: $COOKIE")
[[ "$code" == "200" ]] || { echo "/me failed: $code $body"; exit 1; }

# create todo
code=$(req POST "$BASE/todos" -H "Cookie: $COOKIE" $J -d '{"title":"First","description":"Desc"}')
[[ "$code" == "201" ]] || { echo "create todo failed: $code $body"; exit 1; }
ID=$(echo "$body" | jq -r .id)

# list todos
code=$(req GET "$BASE/todos" -H "Cookie: $COOKIE")
[[ "$code" == "200" ]] || { echo "list todos failed: $code $body"; exit 1; }
echo "$body" | jq -e 'length==1' >/dev/null

# get todo
code=$(req GET "$BASE/todos/$ID" -H "Cookie: $COOKIE")
[[ "$code" == "200" ]] || { echo "get todo failed: $code $body"; exit 1; }
echo "$body" | jq -e ".id==$ID" >/dev/null

# update todo
code=$(req PUT "$BASE/todos/$ID" -H "Cookie: $COOKIE" $J -d '{"completed":true}')
[[ "$code" == "200" ]] || { echo "update todo failed: $code $body"; exit 1; }
echo "$body" | jq -e '.completed==true' >/dev/null

# delete todo
code=$(req DELETE "$BASE/todos/$ID" -H "Cookie: $COOKIE")
[[ "$code" == "204" ]] || { echo "delete todo failed: $code $body"; exit 1; }

# confirm deletion
code=$(req GET "$BASE/todos/$ID" -H "Cookie: $COOKIE")
[[ "$code" == "404" ]] || { echo "get after delete failed: $code $body"; exit 1; }

# change password
code=$(req PUT "$BASE/password" -H "Cookie: $COOKIE" $J -d '{"old_password":"secretpass","new_password":"newsecret"}')
[[ "$code" == "200" ]] || { echo "password change failed: $code $body"; exit 1; }

# logout
code=$(req POST "$BASE/logout" -H "Cookie: $COOKIE")
[[ "$code" == "200" ]] || { echo "logout failed: $code $body"; exit 1; }

# use old session should fail
code=$(req GET "$BASE/me" -H "Cookie: $COOKIE")
[[ "$code" == "401" ]] || { echo "/me after logout failed: $code $body"; exit 1; }

echo "All tests passed"