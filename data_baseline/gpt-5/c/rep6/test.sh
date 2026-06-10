#!/bin/bash
set -euo pipefail
PORT=${PORT:-8095}
# Clean up any previous server
if [[ -f server.pid ]]; then
  kill $(cat server.pid) 2>/dev/null || true
  rm -f server.pid
  sleep 0.2
fi
pkill -x server 2>/dev/null || true
sleep 0.2

rm -f cookie_alice.txt cookie_bob.txt
chmod +x run.sh
./run.sh --port "$PORT" >/tmp/server_test.log 2>&1 & echo $! > server.pid
base="http://127.0.0.1:$PORT"

# Wait until server responds
for i in {1..50}; do
  if curl -s -o /dev/null -w "%{http_code}" "$base/me" | grep -qE '^(400|401|404|405)$'; then
    break
  fi
  sleep 0.1
  if [[ $i -eq 50 ]]; then echo "Server failed to start"; exit 1; fi
done

status() { echo "-- $1"; }
req() { # method url data cookiejar
  local method="$1" url="$2" data="${3-}" jar="${4-}"
  if [[ -n "$data" ]]; then
    curl -sS -i -X "$method" -H 'Content-Type: application/json' ${jar:+-b "$jar" -c "$jar"} --data "$data" "$url"
  else
    curl -sS -i -X "$method" ${jar:+-b "$jar" -c "$jar"} "$url"
  fi
}

get_code() { grep -m1 -oE "HTTP/1\.[01] [0-9]{3}" | awk '{print $2}'; }
get_body() { awk 'BEGIN{p=0} { if(p){print} else if ($0 ~ /^\r?$/){p=1} }'; }

trap 'kill $(cat server.pid) 2>/dev/null || true; rm -f server.pid cookie_alice.txt cookie_bob.txt' EXIT

# Register alice
status "Register alice"
resp=$(req POST "$base/register" '{"username":"alice","password":"pass1234"}')
code=$(echo "$resp" | get_code)
[[ "$code" == "201" ]] || { echo "$resp"; exit 1; }

# Register duplicate
status "Register duplicate"
resp=$(req POST "$base/register" '{"username":"alice","password":"pass1234"}')
code=$(echo "$resp" | get_code)
[[ "$code" == "409" ]] || { echo "$resp"; exit 1; }

# Login wrong
status "Login wrong"
resp=$(req POST "$base/login" '{"username":"alice","password":"wrongpass"}' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "401" ]] || { echo "$resp"; exit 1; }

# Login correct
status "Login correct"
resp=$(req POST "$base/login" '{"username":"alice","password":"pass1234"}' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "200" ]] || { echo "$resp"; exit 1; }

# Me
status "GET /me"
resp=$(req GET "$base/me" '' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "200" ]] || { echo "$resp"; exit 1; }

# Change password wrong old
status "PUT /password wrong old"
resp=$(req PUT "$base/password" '{"old_password":"bad","new_password":"newpass12"}' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "401" ]] || { echo "$resp"; exit 1; }

# Change password correct
status "PUT /password correct"
resp=$(req PUT "$base/password" '{"old_password":"pass1234","new_password":"newpass12"}' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "200" ]] || { echo "$resp"; exit 1; }

# Logout
status "POST /logout"
resp=$(req POST "$base/logout" '' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "200" ]] || { echo "$resp"; exit 1; }

# Me after logout -> 401
status "GET /me after logout"
resp=$(req GET "$base/me" '' cookie_alice.txt || true)
code=$(echo "$resp" | get_code || true)
[[ "$code" == "401" ]] || { echo "$resp"; exit 1; }

# Login again with new password
status "Login again"
resp=$(req POST "$base/login" '{"username":"alice","password":"newpass12"}' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "200" ]] || { echo "$resp"; exit 1; }

# Todos empty
status "GET /todos empty"
resp=$(req GET "$base/todos" '' cookie_alice.txt)
code=$(echo "$resp" | get_code)
body=$(echo "$resp" | get_body)
[[ "$code" == "200" && "$body" == "[]" ]] || { echo "$resp"; exit 1; }

# Create todo invalid
status "POST /todos invalid"
resp=$(req POST "$base/todos" '{"title":""}' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "400" ]] || { echo "$resp"; exit 1; }

# Create todo valid
status "POST /todos valid"
resp=$(req POST "$base/todos" '{"title":"Task1","description":"Desc"}' cookie_alice.txt)
code=$(echo "$resp" | get_code)
body=$(echo "$resp" | get_body)
[[ "$code" == "201" ]] || { echo "$resp"; exit 1; }
id1=$(echo "$body" | sed -n 's/.*"id": \([0-9][0-9]*\).*/\1/p')
[[ -n "$id1" ]] || { echo "No id"; echo "$resp"; exit 1; }

# Get todos length 1
status "GET /todos length 1"
resp=$(req GET "$base/todos" '' cookie_alice.txt)
code=$(echo "$resp" | get_code)
body=$(echo "$resp" | get_body)
[[ "$code" == "200" ]] || { echo "$resp"; exit 1; }
len=$(echo "$body" | grep -o '"id"[[:space:]]*:' | wc -l | tr -d ' ')
[[ "$len" == "1" ]] || { echo "$resp"; exit 1; }

# Get todo by id
status "GET /todos/$id1"
resp=$(req GET "$base/todos/$id1" '' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "200" ]] || { echo "$resp"; exit 1; }

# Update completed true
status "PUT /todos/$id1 completed"
resp=$(req PUT "$base/todos/$id1" '{"completed": true}' cookie_alice.txt)
code=$(echo "$resp" | get_code)
body=$(echo "$resp" | get_body)
[[ "$code" == "200" && "$body" == *'"completed": true'* ]] || { echo "$resp"; exit 1; }

# Update title
status "PUT /todos/$id1 title"
resp=$(req PUT "$base/todos/$id1" '{"title": "NewTitle"}' cookie_alice.txt)
code=$(echo "$resp" | get_code)
body=$(echo "$resp" | get_body)
[[ "$code" == "200" && "$body" == *'"title": "NewTitle"'* ]] || { echo "$resp"; exit 1; }

# Delete todo
status "DELETE /todos/$id1"
resp=$(req DELETE "$base/todos/$id1" '' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "204" ]] || { echo "$resp"; exit 1; }

# Get deleted -> 404
status "GET /todos/$id1 after delete"
resp=$(req GET "$base/todos/$id1" '' cookie_alice.txt)
code=$(echo "$resp" | get_code)
[[ "$code" == "404" ]] || { echo "$resp"; exit 1; }

# Create two todos
status "Create t2 t3"
resp=$(req POST "$base/todos" '{"title":"A"}' cookie_alice.txt)
[[ $(echo "$resp" | get_code) == "201" ]] || { echo "$resp"; exit 1; }
resp=$(req POST "$base/todos" '{"title":"B"}' cookie_alice.txt)
[[ $(echo "$resp" | get_code) == "201" ]] || { echo "$resp"; exit 1; }

# Register bob and login
status "Register bob"
resp=$(req POST "$base/register" '{"username":"bob","password":"secret123"}')
[[ $(echo "$resp" | get_code) == "201" ]] || { echo "$resp"; exit 1; }
status "Login bob"
resp=$(req POST "$base/login" '{"username":"bob","password":"secret123"}' cookie_bob.txt)
[[ $(echo "$resp" | get_code) == "200" ]] || { echo "$resp"; exit 1; }

# Bob sees no todos
status "Bob GET /todos"
resp=$(req GET "$base/todos" '' cookie_bob.txt)
code=$(echo "$resp" | get_code)
body=$(echo "$resp" | get_body)
[[ "$code" == "200" && "$body" == "[]" ]] || { echo "$resp"; exit 1; }

# Bob cannot access Alice's todo id 2
status "Bob GET /todos/2 -> 404"
resp=$(req GET "$base/todos/2" '' cookie_bob.txt)
[[ $(echo "$resp" | get_code) == "404" ]] || { echo "$resp"; exit 1; }

# Done
status "All tests passed"