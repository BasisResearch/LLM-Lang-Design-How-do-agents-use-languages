#!/bin/bash
set -e

PORT=9999
URL="http://localhost:$PORT"

echo "Starting server on port $PORT..."
./run.sh --port $PORT > server.log 2>&1 &
SERVER_PID=$!
sleep 12

cleanup() {
  echo "Cleaning up..."
  kill $SERVER_PID 2>/dev/null || true
  rm -f cookies.txt cookies2.txt
}
trap cleanup EXIT

req() {
  curl -s -w "\n%{http_code}" "$@"
}

echo "=== Testing Register ==="
RES=$(req -X POST "$URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "201" ]; then echo "Register failed: $RES"; exit 1; fi
echo "Register OK ($CODE)"

echo "=== Testing Duplicate Register ==="
RES=$(req -X POST "$URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "409" ]; then echo "Duplicate register failed (expected 409): $RES"; exit 1; fi
echo "Duplicate register OK ($CODE)"

echo "=== Testing Login ==="
RES=$(req -X POST "$URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Login failed: $RES"; exit 1; fi
echo "Login OK ($CODE)"

echo "=== Testing Me ==="
RES=$(req -X GET "$URL/me" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Me failed: $RES"; exit 1; fi
echo "Me OK ($CODE)"

echo "=== Testing Create Todo ==="
RES=$(req -X POST "$URL/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title": "My first todo", "description": "desc"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "201" ]; then echo "Create todo failed: $RES"; exit 1; fi
echo "Create todo OK ($CODE)"

echo "=== Testing Get Todos ==="
RES=$(req -X GET "$URL/todos" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Get todos failed: $RES"; exit 1; fi
echo "Get todos OK ($CODE)"

echo "=== Testing Update Todo ==="
RES=$(req -X PUT "$URL/todos/1" -b cookies.txt -H "Content-Type: application/json" -d '{"completed": true}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Update todo failed: $RES"; exit 1; fi
echo "Update todo OK ($CODE)"

echo "=== Testing Delete Todo ==="
RES=$(req -X DELETE "$URL/todos/1" -b cookies.txt -w "%{http_code}")
if [ "$RES" != "204" ]; then echo "Delete todo failed (expected 204): $RES"; exit 1; fi
echo "Delete todo OK ($RES)"

echo "=== Testing Change Password ==="
RES=$(req -X PUT "$URL/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword1"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Change password failed: $RES"; exit 1; fi
echo "Change password OK ($CODE)"

echo "=== Testing Logout ==="
RES=$(req -X POST "$URL/logout" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Logout failed: $RES"; exit 1; fi
echo "Logout OK ($CODE)"

echo "=== Testing Me After Logout ==="
RES=$(req -X GET "$URL/me" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "401" ]; then echo "Me after logout failed (expected 401): $RES"; exit 1; fi
echo "Me after logout OK ($CODE)"

echo "=== Testing Invalid Username Register ==="
RES=$(req -X POST "$URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then echo "Invalid username register failed (expected 400): $RES"; exit 1; fi
echo "Invalid username register OK ($CODE)"

echo "=== Testing Short Password Register ==="
RES=$(req -X POST "$URL/register" -H "Content-Type: application/json" -d '{"username": "user3", "password": "short"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then echo "Short password register failed (expected 400): $RES"; exit 1; fi
echo "Short password register OK ($CODE)"

echo "=== Testing Invalid Credentials Login ==="
RES=$(req -X POST "$URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "401" ]; then echo "Invalid credentials login failed (expected 401): $RES"; exit 1; fi
echo "Invalid credentials login OK ($CODE)"

echo "=== Testing Todo Not Found (Other User) ==="
RES=$(req -X POST "$URL/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}')
RES=$(req -X POST "$URL/login" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' -c cookies2.txt)
RES=$(req -X GET "$URL/todos/1" -b cookies2.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "404" ]; then echo "Todo not found (other user) failed (expected 404): $RES"; exit 1; fi
echo "Todo not found (other user) OK ($CODE)"
rm -f cookies2.txt

echo "=== All tests passed! ==="