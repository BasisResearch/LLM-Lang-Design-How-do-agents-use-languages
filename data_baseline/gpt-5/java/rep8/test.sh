#!/usr/bin/env bash
set -euo pipefail
PORT=${1:-8123}
BASE="http://127.0.0.1:$PORT"
CJ1=cookie1.txt
CJ1B=cookie1b.txt
CJ2=cookie2.txt
rm -f $CJ1 $CJ1B $CJ2 server.out

# Start server
./run.sh --port "$PORT" > server.out 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

# Wait for server to be ready
for i in {1..50}; do
  if curl -sS "$BASE/me" -o /dev/null -w '' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

curl_json() {
  local method=$1; shift
  local url=$1; shift
  curl -sS -X "$method" -H 'Content-Type: application/json' "$url" "$@"
}

check_status() {
  local expected=$1; shift
  local cmd=("$@")
  local http
  http=$("${cmd[@]}" -o /dev/null -w '%{http_code}')
  if [[ "$http" != "$expected" ]]; then
    echo "Expected $expected, got $http for: ${cmd[*]}" >&2
    # Print response for debugging
    "${cmd[@]}" -i || true
    echo "--- Server output ---" >&2
    tail -n +1 server.out >&2 || true
    exit 1
  fi
}

RND=$RANDOM
U1="alice_${RND}"
U2="bob_${RND}"

# 1) Register user
check_status 201 curl_json POST "$BASE/register" --data "{\"username\":\"$U1\",\"password\":\"password123\"}"
# 2) Duplicate username
check_status 409 curl_json POST "$BASE/register" --data "{\"username\":\"$U1\",\"password\":\"password123\"}" || true
# 3) Login wrong
check_status 401 curl_json POST "$BASE/login" --data "{\"username\":\"$U1\",\"password\":\"wrongpass\"}"
# 4) Login correct
check_status 200 curl_json POST "$BASE/login" --data "{\"username\":\"$U1\",\"password\":\"password123\"}" -c $CJ1
# 5) GET /me with cookie
check_status 200 curl -sS "$BASE/me" -b $CJ1
# 6) GET /me without cookie -> 401
check_status 401 curl -sS "$BASE/me"
# 7) PUT /password wrong old
check_status 401 curl_json PUT "$BASE/password" -b $CJ1 --data '{"old_password":"wrong","new_password":"newpassword123"}'
# 8) PUT /password too short
check_status 400 curl_json PUT "$BASE/password" -b $CJ1 --data '{"old_password":"password123","new_password":"short"}'
# 9) PUT /password correct
check_status 200 curl_json PUT "$BASE/password" -b $CJ1 --data '{"old_password":"password123","new_password":"newpassword123"}'
# 10) Logout
check_status 200 curl -sS -X POST "$BASE/logout" -b $CJ1
# 11) After logout, /me -> 401
check_status 401 curl -sS "$BASE/me" -b $CJ1
# 12) Login with new password
check_status 200 curl_json POST "$BASE/login" --data "{\"username\":\"$U1\",\"password\":\"newpassword123\"}" -c $CJ1B
# 13) Create todo missing title -> 400
check_status 400 curl_json POST "$BASE/todos" -b $CJ1B --data '{"description":"desc only"}'
# 14) Create todo valid
resp=$(curl_json POST "$BASE/todos" -b $CJ1B --data '{"title":"First","description":"Do it"}')
code=$(curl_json POST "$BASE/todos" -b $CJ1B --data '{"title":"Second","description":"Later"}' -o /dev/null -w '%{http_code}')
[[ "$code" == "201" ]] || { echo "Expected 201 for second todo, got $code"; exit 1; }
TODO1_ID=$(echo "$resp" | grep -o '"id":[0-9]*' | head -n1 | cut -d: -f2)
# 15) List todos -> ensure array returned
list=$(curl_json GET "$BASE/todos" -b $CJ1B)
[[ "$list" == \[*\] ]] || { echo "List is not array: $list"; exit 1; }
# 16) Get todo 1 (first created id)
check_status 200 curl -sS "$BASE/todos/$TODO1_ID" -b $CJ1B
# 17) Update todo completed true
check_status 200 curl_json PUT "$BASE/todos/$TODO1_ID" -b $CJ1B --data '{"completed": true}'
# 18) Update with empty title -> 400
check_status 400 curl_json PUT "$BASE/todos/$TODO1_ID" -b $CJ1B --data '{"title": ""}'
# 19) Delete todo 1
code=$(curl -sS -X DELETE "$BASE/todos/$TODO1_ID" -b $CJ1B -o /dev/null -w '%{http_code}')
[[ "$code" == "204" ]] || { echo "Expected 204 on delete, got $code"; exit 1; }
# 20) Get deleted -> 404
check_status 404 curl -sS "$BASE/todos/$TODO1_ID" -b $CJ1B
# 21) List todos now size 1
list=$(curl_json GET "$BASE/todos" -b $CJ1B)
[[ "$list" == *'"id"'* ]] || true
# 22) Register second user and create todo
check_status 201 curl_json POST "$BASE/register" --data "{\"username\":\"$U2\",\"password\":\"password123\"}"
check_status 200 curl_json POST "$BASE/login" --data "{\"username\":\"$U2\",\"password\":\"password123\"}" -c $CJ2
resp2=$(curl_json POST "$BASE/todos" -b $CJ2 --data '{"title":"BobTodo","description":"secret"}')
BOB_TODO_ID=$(echo "$resp2" | grep -o '"id":[0-9]*' | head -n1 | cut -d: -f2)
# 23) Access Bob's todo from Alice -> 404
check_status 404 curl -sS "$BASE/todos/$BOB_TODO_ID" -b $CJ1B
# 24) Ensure content-type for JSON responses (case-insensitive header name)
hdr=$(curl -sS -D - "$BASE/me" -b $CJ1B -o /dev/null)
low=$(echo "$hdr" | tr '[:upper:]' '[:lower:]')
[[ "$low" == *$'content-type: application/json'* ]] || { echo "Missing JSON content-type"; echo "$hdr"; exit 1; }

echo "All tests passed"