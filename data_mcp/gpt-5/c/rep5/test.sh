#!/usr/bin/env bash
set -euo pipefail
PORT=18080
if [[ $# -ge 1 ]]; then PORT=$1; fi
./run.sh --port "$PORT" &
PID=$!
jar=$(mktemp)
cleanup(){ kill $PID || true; wait $PID || true; rm -f "$jar"; }
trap cleanup EXIT

base="http://127.0.0.1:$PORT"

# wait for server to be ready
for i in $(seq 1 120); do
  if curl -s -o /dev/null -w '%{http_code}' "$base/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if ! kill -0 $PID 2>/dev/null; then echo "Server process died"; exit 1; fi
  if [[ $i -eq 120 ]]; then echo "Timeout waiting for server"; exit 1; fi
done

# helper
req(){
  method=$1; path=$2; shift 2
  curl -s -S -D >(cat >&2) -b "$jar" -c "$jar" -H 'Content-Type: application/json' -X "$method" "$base$path" "$@"
}

# Register
echo 'Registering user1'
reg=$(req POST /register -d '{"username":"user1","password":"password123"}')
echo "$reg"

# Duplicate username should 409
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST "$base/register" -d '{"username":"user1","password":"password123"}')
[ "$code" = "409" ]

# Login
login=$(req POST /login -d '{"username":"user1","password":"password123"}')
echo "$login" | grep '"username":"user1"' >/dev/null

# /me
me=$(req GET /me)
echo "$me" | grep '"username":"user1"' >/dev/null

# Change password wrong old -> 401
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" -H 'Content-Type: application/json' -X PUT "$base/password" -d '{"old_password":"wrong","new_password":"newpassword123"}')
[ "$code" = "401" ]

# Change password good -> 200
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" -H 'Content-Type: application/json' -X PUT "$base/password" -d '{"old_password":"password123","new_password":"newpassword123"}')
[ "$code" = "200" ]

# Create todos
req POST /todos -d '{"title":"T1","description":"D1"}' | tee /dev/stderr
req POST /todos -d '{"title":"T2"}' | tee /dev/stderr

# List todos
list=$(req GET /todos)
echo "$list" | grep '"title":"T1"' >/dev/null

# Get todo 1
get1=$(req GET /todos/1)
echo "$get1" | grep '"id":1' >/dev/null

# Update todo 1
upd=$(req PUT /todos/1 -d '{"completed":true, "description":"D1x"}')
echo "$upd" | grep '"completed":true' >/dev/null

# Delete todo 2
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" -X DELETE "$base/todos/2")
[ "$code" = "204" ]

# Ensure 404 for deleted
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" "$base/todos/2")
[ "$code" = "404" ]

# Logout
req POST /logout -d '' | tee /dev/stderr

# after logout, requests should 401
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" -c "$jar" "$base/me")
[ "$code" = "401" ]

echo 'All tests passed.'
