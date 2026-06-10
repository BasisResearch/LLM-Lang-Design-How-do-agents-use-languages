#!/bin/sh
set -eu
PORT=31337
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT INT TERM
# wait for server
for i in $(seq 1 50); do
  if curl -s "http://127.0.0.1:$PORT/me" -o /dev/null; then
    break
  fi
  sleep 0.1
done

base="http://127.0.0.1:$PORT"

echo "1. Register user"
resp=$(curl -s -w "\n%{http_code}" -H "Content-Type: application/json" -X POST "$base/register" -d '{"username":"alice","password":"password123"}')
body=$(printf "%s" "$resp" | head -n1)
code=$(printf "%s" "$resp" | tail -n1)
[ "$code" = "201" ] || { echo "Register failed: $resp"; exit 1; }

# duplicate register should 409
resp=$(curl -s -w "\n%{http_code}" -H "Content-Type: application/json" -X POST "$base/register" -d '{"username":"alice","password":"password123"}')
code=$(printf "%s" "$resp" | tail -n1)
[ "$code" = "409" ] || { echo "Duplicate register should 409: $resp"; exit 1; }

echo "2. Login"
resp=$(curl -i -s -H "Content-Type: application/json" -X POST "$base/login" -d '{"username":"alice","password":"password123"}')
code=$(printf "%s" "$resp" | awk 'NR==1{print $2}')
[ "$code" = "200" ] || { echo "Login failed: $resp"; exit 1; }
cookie=$(printf "%s" "$resp" | awk '/^Set-Cookie: /{print $2; exit}' | tr -d '\r' | sed 's/;.*$//')
[ -n "$cookie" ] || { echo "No Set-Cookie in login"; exit 1; }

cookie_header="-H"; cookie_value="Cookie: $cookie"

echo "3. /me requires auth"
code=$(curl -s -o /dev/null -w "%{http_code}" "$base/me")
[ "$code" = "401" ] || { echo "/me without cookie should 401"; exit 1; }

resp=$(curl -s $cookie_header "$cookie_value" "$base/me")
[ -n "$resp" ] || { echo "/me with cookie failed"; exit 1; }

echo "4. Create todo"
resp=$(curl -s -w "\n%{http_code}" $cookie_header "$cookie_value" -H "Content-Type: application/json" -X POST "$base/todos" -d '{"title":"Task 1","description":"First"}')
body=$(printf "%s" "$resp" | head -n1)
code=$(printf "%s" "$resp" | tail -n1)
[ "$code" = "201" ] || { echo "Create todo failed: $resp"; exit 1; }
id1=$(echo "$body" | sed -n 's/.*"id":[ ]*\([0-9][0-9]*\).*/\1/p')

resp=$(curl -s -w "\n%{http_code}" $cookie_header "$cookie_value" -H "Content-Type: application/json" -X POST "$base/todos" -d '{"title":"Task 2"}')
code=$(printf "%s" "$resp" | tail -n1)
[ "$code" = "201" ] || { echo "Create 2 failed: $resp"; exit 1; }


echo "5. List todos"
code=$(curl -s -o /dev/null -w "%{http_code}" $cookie_header "$cookie_value" "$base/todos")
[ "$code" = "200" ] || { echo "List failed"; exit 1; }


echo "6. Get todo by id"
code=$(curl -s -o /dev/null -w "%{http_code}" $cookie_header "$cookie_value" "$base/todos/$id1")
[ "$code" = "200" ] || { echo "Get todo failed"; exit 1; }


echo "7. Update todo"
code=$(curl -s -o /dev/null -w "%{http_code}" $cookie_header "$cookie_value" -H "Content-Type: application/json" -X PUT "$base/todos/$id1" -d '{"completed":true}')
[ "$code" = "200" ] || { echo "Update failed"; exit 1; }


echo "8. Delete todo"
code=$(curl -s -o /dev/null -w "%{http_code}" $cookie_header "$cookie_value" -X DELETE "$base/todos/$id1")
[ "$code" = "204" ] || { echo "Delete failed"; exit 1; }


echo "9. Password change"
code=$(curl -s -o /dev/null -w "%{http_code}" $cookie_header "$cookie_value" -H "Content-Type: application/json" -X PUT "$base/password" -d '{"old_password":"password123","new_password":"newpassword456"}')
[ "$code" = "200" ] || { echo "Password change failed"; exit 1; }

# logout
code=$(curl -s -o /dev/null -w "%{http_code}" $cookie_header "$cookie_value" -X POST "$base/logout")
[ "$code" = "200" ] || { echo "Logout failed"; exit 1; }

# old cookie should now 401
code=$(curl -s -o /dev/null -w "%{http_code}" $cookie_header "$cookie_value" "$base/me")
[ "$code" = "401" ] || { echo "Old cookie should be invalid after logout"; exit 1; }

echo "All tests passed"