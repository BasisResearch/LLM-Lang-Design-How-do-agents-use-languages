#!/bin/bash
set -euo pipefail
PORT=8130
./run.sh --port "$PORT" >/tmp/todo_server_test.log 2>&1 &
SPID=$!
sleep 0.2
cleanup(){ kill $SPID 2>/dev/null || true; }
trap cleanup EXIT

base="http://127.0.0.1:$PORT"

# wait for server ready
for i in {1..50}; do
  if curl -sS -o /dev/null "$base/doesnotexist"; then break; fi
  sleep 0.1
done


echo "1) Register invalid username -> 400"
out=$(mktemp)
headers=$(mktemp)
curl -sS -D "$headers" -o "$out" "$base/register" -H 'Content-Type: application/json' -d '{"username":"ab","password":"shortpass"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "400" ]]
grep -q 'Invalid username' "$out"

echo "2) Register valid user -> 201"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "201" ]]
grep -q '"id":1' "$out"
grep -q '"username":"user_one"' "$out"

echo "3) Duplicate username -> 409"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "409" ]]

echo "4) Login wrong password -> 401"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"wrong"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "401" ]]

echo "5) Login success -> 200 and Set-Cookie"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "200" ]]
COOKIE=$(grep -i '^Set-Cookie:' "$headers" | sed -E 's/.*session_id=([^;]+).*/\1/I')
[[ -n "$COOKIE" ]]

echo "6) /me with cookie -> 200"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/me" -H "Cookie: session_id=$COOKIE"
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "200" ]]


echo "7) PUT /password too short -> 400"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -d '{"old_password":"password123","new_password":"short"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "400" ]]

echo "8) PUT /password change -> 200"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X PUT "$base/password" -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -d '{"old_password":"password123","new_password":"newpassword123"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "200" ]]


echo "9) POST /logout -> 200 and invalidate"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X POST "$base/logout" -H "Cookie: session_id=$COOKIE"
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "200" ]]

echo "10) /me with old cookie -> 401"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/me" -H "Cookie: session_id=$COOKIE" || true
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "401" ]]


echo "11) Login with new password -> 200"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpassword123"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "200" ]]
COOKIE=$(grep -i '^Set-Cookie:' "$headers" | sed -E 's/.*session_id=([^;]+).*/\1/I')


echo "12) GET /todos without cookie -> 401"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/todos" || true
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "401" ]]


echo "13) GET /todos initially -> []"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/todos" -H "Cookie: session_id=$COOKIE"
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "200" ]]
# empty list check
grep -q '\[\]' "$out" || true


echo "14) POST /todos missing title -> 400"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -d '{"description":"desc"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "400" ]]


echo "15) POST /todos valid -> 201 id1"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -d '{"title":"Task 1","description":"First"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "201" ]]
id1=$(grep -o '"id":[0-9]*' "$out" | head -n1 | cut -d: -f2)


echo "16) POST second todo -> id2"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X POST "$base/todos" -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -d '{"title":"Task 2","description":"Second"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "201" ]]
id2=$(grep -o '"id":[0-9]*' "$out" | head -n1 | cut -d: -f2)


echo "17) GET /todos list 2 and ordered"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/todos" -H "Cookie: session_id=$COOKIE"
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "200" ]]
# rudimentary check order by searching id1 before id2
pos1=$(grep -b -o '"id":'"$id1" "$out" | head -n1 | cut -d: -f1 || echo 0)
pos2=$(grep -b -o '"id":'"$id2" "$out" | head -n1 | cut -d: -f1 || echo 1)
[[ "$pos1" -lt "$pos2" ]]


echo "18) GET /todos/:id -> 200"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/todos/$id1" -H "Cookie: session_id=$COOKIE"
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "200" ]]


echo "19) PUT /todos/:id set completed true -> 200"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X PUT "$base/todos/$id1" -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -d '{"completed":true}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "200" ]]
grep -q '"completed":true' "$out"


echo "20) PUT /todos/:id empty title -> 400"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X PUT "$base/todos/$id1" -H 'Content-Type: application/json' -H "Cookie: session_id=$COOKIE" -d '{"title":""}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "400" ]]


echo "21) Register second user and test 404 on foreign todo"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/register" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password123"}'
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "201" ]]
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/login" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password123"}'
COOKIE2=$(grep -i '^Set-Cookie:' "$headers" | sed -E 's/.*session_id=([^;]+).*/\1/I')
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/todos/$id1" -H "Cookie: session_id=$COOKIE2" || true
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "404" ]]
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X DELETE "$base/todos/$id1" -H "Cookie: session_id=$COOKIE2" || true
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "404" ]]


echo "22) DELETE /todos/:id by owner -> 204 and no body"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" -X DELETE "$base/todos/$id1" -H "Cookie: session_id=$COOKIE"
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "204" ]]
[[ ! -s "$out" ]]  # body empty


echo "23) GET deleted todo -> 404"
> "$out"; > "$headers"
curl -sS -D "$headers" -o "$out" "$base/todos/$id1" -H "Cookie: session_id=$COOKIE" || true
code=$(awk 'NR==1{print $2}' "$headers")
[[ "$code" == "404" ]]


echo "All tests passed."
