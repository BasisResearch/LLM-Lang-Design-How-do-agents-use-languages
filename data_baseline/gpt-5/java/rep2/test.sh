#!/usr/bin/env bash
set -euo pipefail

pick_port() {
  # pick a random high port
  while true; do
    p=$(( (RANDOM % 20000) + 30000 ))
    # try to connect; if fails, assume free
    if ! (echo > /dev/tcp/127.0.0.1/$p) >/dev/null 2>&1; then
      echo $p
      return
    fi
  done
}

PORT=$(pick_port)
./run.sh --port $PORT &
SERVER_PID=$!
cleanup() { kill $SERVER_PID 2>/dev/null || true; wait $SERVER_PID 2>/dev/null || true; rm -f cj.txt cj2.txt >/dev/null 2>&1 || true; }
trap cleanup EXIT
# wait for server
ok=false
for i in {1..100}; do
  if curl -sS http://127.0.0.1:$PORT/ >/dev/null 2>&1; then ok=true; break; fi
  if ! kill -0 $SERVER_PID 2>/dev/null; then echo "Server process died"; exit 1; fi
  sleep 0.05
done
$ok || { echo "Server did not start on port $PORT"; exit 1; }

echo "Testing unauthorized access..."
code=$(curl -s -o /tmp/body -w "%{http_code}" http://127.0.0.1:$PORT/me)
[[ "$code" == "401" ]] || { echo "Expected 401 for /me, got $code"; cat /tmp/body; exit 1; }

echo "Testing register validations..."
code=$(curl -s -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"ab","password":"12345678"}' http://127.0.0.1:$PORT/register)
[[ "$code" == "400" ]] || { echo "Expected 400 invalid username, got $code"; cat /tmp/body; exit 1; }
code=$(curl -s -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"short"}' http://127.0.0.1:$PORT/register)
[[ "$code" == "400" ]] || { echo "Expected 400 password too short, got $code"; cat /tmp/body; exit 1; }

echo "Registering user1..."
body=$(curl -s -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' -D /tmp/h -o - http://127.0.0.1:$PORT/register)
[[ $(echo "$body" | grep -o '"id":' | wc -l) -ge 1 ]] || { echo "Register failed: $body"; exit 1; }

echo "Registering duplicate should 409..."
code=$(curl -s -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' http://127.0.0.1:$PORT/register)
[[ "$code" == "409" ]] || { echo "Expected 409 duplicate, got $code"; cat /tmp/body; exit 1; }

# Second user
body=$(curl -s -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password456"}' -D /tmp/h -o - http://127.0.0.1:$PORT/register)

echo "Login with wrong creds should 401..."
code=$(curl -s -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"wrongpass"}' http://127.0.0.1:$PORT/login)
[[ "$code" == "401" ]] || { echo "Expected 401 invalid creds, got $code"; cat /tmp/body; exit 1; }

echo "Login user1..."
rm -f cj.txt
body=$(curl -s -c cj.txt -b cj.txt -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' -o - -w '' http://127.0.0.1:$PORT/login)
[[ $(cat cj.txt | grep session_id | wc -l) -ge 1 ]] || { echo "No session cookie set"; exit 1; }

echo "GET /me..."
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" http://127.0.0.1:$PORT/me)
[[ "$code" == "200" ]] || { echo "Expected 200 me, got $code"; cat /tmp/body; exit 1; }

echo "Change password invalid old should 401..."
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"bad","new_password":"newpassword1"}' http://127.0.0.1:$PORT/password)
[[ "$code" == "401" ]] || { echo "Expected 401 bad old password, got $code"; cat /tmp/body; exit 1; }

echo "Change password too short should 400..."
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"short"}' http://127.0.0.1:$PORT/password)
[[ "$code" == "400" ]] || { echo "Expected 400 short new password, got $code"; cat /tmp/body; exit 1; }

echo "Change password success..."
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"old_password":"password123","new_password":"newpassword1"}' http://127.0.0.1:$PORT/password)
[[ "$code" == "200" ]] || { echo "Expected 200 change password, got $code"; cat /tmp/body; exit 1; }

# logout
echo "Logout..."
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" -X POST http://127.0.0.1:$PORT/logout)
[[ "$code" == "200" ]] || { echo "Expected 200 logout, got $code"; cat /tmp/body; exit 1; }

# After logout, me should 401
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" http://127.0.0.1:$PORT/me)
[[ "$code" == "401" ]] || { echo "Expected 401 after logout, got $code"; cat /tmp/body; exit 1; }

# Login with old password should fail
code=$(curl -s -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"password123"}' http://127.0.0.1:$PORT/login)
[[ "$code" == "401" ]] || { echo "Expected 401 old password fails, got $code"; cat /tmp/body; exit 1; }

# Login with new password
rm -f cj.txt
code=$(curl -s -c cj.txt -b cj.txt -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_one","password":"newpassword1"}' http://127.0.0.1:$PORT/login)
[[ "$code" == "200" ]] || { echo "Expected 200 login with new password, got $code"; cat /tmp/body; exit 1; }

# Create todo (user1)
echo "Create todo..."
body=$(curl -s -b cj.txt -H 'Content-Type: application/json' -d '{"title":"Task A","description":"First task"}' -o - http://127.0.0.1:$PORT/todos)
id=$(echo "$body" | sed -n 's/.*"id":\([0-9]\+\).*/\1/p')
[[ -n "$id" ]] || { echo "Failed to parse todo id: $body"; exit 1; }

# List should include
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" http://127.0.0.1:$PORT/todos)
[[ "$code" == "200" ]] || { echo "Expected 200 list, got $code"; cat /tmp/body; exit 1; }
[[ $(cat /tmp/body | grep -o 'Task A' | wc -l) -ge 1 ]] || { echo "List missing todo"; cat /tmp/body; exit 1; }

# Get by id
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" http://127.0.0.1:$PORT/todos/$id)
[[ "$code" == "200" ]] || { echo "Expected 200 get by id, got $code"; cat /tmp/body; exit 1; }

# Update partial
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" -X PUT -H 'Content-Type: application/json' -d '{"completed":true}' http://127.0.0.1:$PORT/todos/$id)
[[ "$code" == "200" ]] || { echo "Expected 200 update, got $code"; cat /tmp/body; exit 1; }
[[ $(cat /tmp/body | grep -o '"completed":true' | wc -l) -ge 1 ]] || { echo "Update did not set completed true"; cat /tmp/body; exit 1; }

# Second user login
rm -f cj2.txt
code=$(curl -s -c cj2.txt -b cj2.txt -o /tmp/body -w "%{http_code}" -H 'Content-Type: application/json' -d '{"username":"user_two","password":"password456"}' http://127.0.0.1:$PORT/login)
[[ "$code" == "200" ]] || { echo "Expected 200 login user2, got $code"; cat /tmp/body; exit 1; }

# User2 should not access user1's todo
code=$(curl -s -b cj2.txt -o /tmp/body -w "%{http_code}" http://127.0.0.1:$PORT/todos/$id)
[[ "$code" == "404" ]] || { echo "Expected 404 cross-user get, got $code"; cat /tmp/body; exit 1; }

# Delete as user1
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" -X DELETE http://127.0.0.1:$PORT/todos/$id)
[[ "$code" == "204" ]] || { echo "Expected 204 delete, got $code"; cat /tmp/body; exit 1; }

# Confirm deleted
code=$(curl -s -b cj.txt -o /tmp/body -w "%{http_code}" http://127.0.0.1:$PORT/todos/$id)
[[ "$code" == "404" ]] || { echo "Expected 404 after delete, got $code"; cat /tmp/body; exit 1; }

echo "All tests passed."
