#!/bin/bash
set -e

PORT=8099
BASE="http://localhost:$PORT"

echo "Starting server..."
cabal run todo-server -- --port $PORT > server.log 2>&1 &
SERVER_PID=$!
sleep 5

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
  echo "Server failed to start!"
  cat server.log
  exit 1
fi

cleanup() {
  echo "Stopping server..."
  kill $SERVER_PID 2>/dev/null || true
  rm -f cookies.txt cookies2.txt response.txt server.log
}
trap cleanup EXIT

assert_eq() {
  if [ "$1" != "$2" ]; then
    echo "FAIL: Expected $1, got $2"
    cat response.txt
    exit 1
  fi
}

echo "1. Register user"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
assert_eq "201" "$CODE"
echo "PASS"

echo "2. Register duplicate"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
assert_eq "409" "$CODE"
echo "PASS"

echo "3. Login"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
assert_eq "200" "$CODE"
echo "PASS"

echo "4. Get /me"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X GET "$BASE/me" -b cookies.txt)
assert_eq "200" "$CODE"
echo "PASS"

echo "5. Invalid auth"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X GET "$BASE/me")
assert_eq "401" "$CODE"
echo "PASS"

echo "6. Change password"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X PUT "$BASE/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password":"password123","new_password":"newpassword123"}')
assert_eq "200" "$CODE"
echo "PASS"

echo "7. Login with new password"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' -c cookies.txt)
assert_eq "200" "$CODE"
echo "PASS"

echo "8. Create todo"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X POST "$BASE/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title":"My Todo","description":"Do this"}')
assert_eq "201" "$CODE"
echo "PASS"

echo "9. List todos"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X GET "$BASE/todos" -b cookies.txt)
assert_eq "200" "$CODE"
echo "PASS"

echo "10. Get specific todo"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X GET "$BASE/todos/1" -b cookies.txt)
assert_eq "200" "$CODE"
echo "PASS"

echo "11. Update todo"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X PUT "$BASE/todos/1" -b cookies.txt -H "Content-Type: application/json" -d '{"completed":true}')
assert_eq "200" "$CODE"
echo "PASS"

echo "12. Update todo with empty title"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X PUT "$BASE/todos/1" -b cookies.txt -H "Content-Type: application/json" -d '{"title":""}')
assert_eq "400" "$CODE"
echo "PASS"

echo "13. Get another user's todo (should be 404)"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser2","password":"password123"}')
assert_eq "201" "$CODE"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username":"testuser2","password":"password123"}' -c cookies2.txt)
assert_eq "200" "$CODE"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X GET "$BASE/todos/1" -b cookies2.txt)
assert_eq "404" "$CODE"
echo "PASS"

echo "14. Delete todo"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X DELETE "$BASE/todos/1" -b cookies.txt)
assert_eq "204" "$CODE"
echo "PASS"

echo "15. Get deleted todo"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X GET "$BASE/todos/1" -b cookies.txt)
assert_eq "404" "$CODE"
echo "PASS"

echo "16. Logout"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X POST "$BASE/logout" -b cookies.txt)
assert_eq "200" "$CODE"
echo "PASS"

echo "17. Access /me after logout"
CODE=$(curl -s -w "%{http_code}" -o response.txt -X GET "$BASE/me" -b cookies.txt)
assert_eq "401" "$CODE"
echo "PASS"

echo "All tests passed!"
