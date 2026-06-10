#!/bin/bash
set -e

PORT=8080
BASE="http://127.0.0.1:$PORT"

# Start server in background
echo "Starting server..."
cabal run todo-app -- --port $PORT > server.log 2>&1 &
SERVER_PID=$!
sleep 3

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "FAIL: Server failed to start"
    cat server.log
    exit 1
fi

cleanup() {
    echo "Cleaning up..."
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt bad_cookies.txt server.log
}
trap cleanup EXIT

echo "=== Testing Register ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '201'; then
  echo "FAIL: Register"
  exit 1
fi

echo "=== Testing Register Invalid Username ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '400'; then
  echo "FAIL: Invalid Username"
  exit 1
fi

echo "=== Testing Register Short Password ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '400'; then
  echo "FAIL: Short Password"
  exit 1
fi

echo "=== Testing Register Duplicate ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '409'; then
  echo "FAIL: Duplicate Username"
  exit 1
fi

echo "=== Testing Login ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '200'; then
  echo "FAIL: Login"
  exit 1
fi

echo "=== Testing Login Invalid Credentials ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpass"}' -c bad_cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '401'; then
  echo "FAIL: Invalid Credentials"
  exit 1
fi

echo "=== Testing Me ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -H "Content-Type: application/json" -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '200'; then
  echo "FAIL: Me"
  exit 1
fi

echo "=== Testing Me Unauthenticated ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -H "Content-Type: application/json")
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '401'; then
  echo "FAIL: Me Unauthenticated"
  exit 1
fi

echo "=== Testing Change Password ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}' -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '200'; then
  echo "FAIL: Change Password"
  exit 1
fi

echo "=== Testing Change Password Wrong Old ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" -H "Content-Type: application/json" -d '{"old_password": "wrong", "new_password": "newpassword123"}' -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '401'; then
  echo "FAIL: Change Password Wrong Old"
  exit 1
fi

echo "=== Testing Create Todo ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Do this"}' -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '201'; then
  echo "FAIL: Create Todo"
  exit 1
fi

echo "=== Testing Create Todo Empty Title ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -H "Content-Type: application/json" -d '{"title": "   ", "description": "Do this"}' -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '400'; then
  echo "FAIL: Create Todo Empty Title"
  exit 1
fi

echo "=== Testing Create Todo Missing Title ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -H "Content-Type: application/json" -d '{"description": "Do this"}' -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '400'; then
  echo "FAIL: Create Todo Missing Title"
  exit 1
fi

echo "=== Testing Get Todos ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos" -H "Content-Type: application/json" -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '200'; then
  echo "FAIL: Get Todos"
  exit 1
fi

echo "=== Testing Get Todo by ID ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/1" -H "Content-Type: application/json" -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '200'; then
  echo "FAIL: Get Todo by ID"
  exit 1
fi

echo "=== Testing Get Todo by ID Not Found ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/999" -H "Content-Type: application/json" -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '404'; then
  echo "FAIL: Get Todo by ID Not Found"
  exit 1
fi

echo "=== Testing Update Todo ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/1" -H "Content-Type: application/json" -d '{"title": "Updated Todo", "completed": true}' -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '200'; then
  echo "FAIL: Update Todo"
  exit 1
fi

echo "=== Testing Update Todo Empty Title ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/1" -H "Content-Type: application/json" -d '{"title": ""}' -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '400'; then
  echo "FAIL: Update Todo Empty Title"
  exit 1
fi

echo "=== Testing Delete Todo ==="
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/todos/1" -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '204'; then
  echo "FAIL: Delete Todo"
  exit 1
fi

echo "=== Testing Delete Todo Not Found ==="
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/todos/1" -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '404'; then
  echo "FAIL: Delete Todo Not Found"
  exit 1
fi

echo "=== Testing Logout ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/logout" -H "Content-Type: application/json" -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '200'; then
  echo "FAIL: Logout"
  exit 1
fi

echo "=== Testing Me After Logout ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -H "Content-Type: application/json" -b cookies.txt)
echo "$RES"
if ! echo "$RES" | tail -n1 | grep -q '401'; then
  echo "FAIL: Me After Logout"
  exit 1
fi

echo "=== ALL TESTS PASSED ==="
