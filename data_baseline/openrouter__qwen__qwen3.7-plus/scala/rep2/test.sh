#!/bin/bash
set -e

# Ensure scala-cli is installed
if ! command -v scala-cli &> /dev/null; then
  echo "Installing scala-cli..."
  curl -sSLf https://scala-cli.virtuslab.org/get | bash
  export PATH="$HOME/.local/share/coursier/bin:$PATH"
fi

PORT=8082
echo "Starting server on port $PORT..."
scala-cli run Server.scala -- --port $PORT > server.log 2>&1 &
SERVER_PID=$!

# Wait for server to be ready
echo "Waiting for server to be ready..."
for i in {1..60}; do
  if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/me" | grep -q "401"; then
    echo "Server is ready!"
    break
  fi
  sleep 1
done

BASE="http://localhost:$PORT"

check() {
  local expected_code=$1
  local res=$2
  local msg=$3
  local code="${res: -3}"
  local body="${res%???}"
  if [ "$code" != "$expected_code" ]; then
    echo "FAIL: $msg - Expected $expected_code, got $code"
    echo "Body: $body"
    kill $SERVER_PID || true
    cat server.log
    exit 1
  fi
  echo "PASS: $msg"
}

echo "Testing /register..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
check 201 "$RES" "/register success"

echo "Testing /register duplicate..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
check 409 "$RES" "/register duplicate"

echo "Testing /register invalid username..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
check 400 "$RES" "/register invalid username"

echo "Testing /register short password..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
check 400 "$RES" "/register short password"

echo "Testing /login..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -b cookies.txt -c cookies.txt)
check 200 "$RES" "/login success"

echo "Testing /login invalid..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrong"}' -b cookies.txt -c cookies.txt)
check 401 "$RES" "/login invalid"

echo "Testing /me..."
RES=$(curl -s -w "%{http_code}" -X GET "$BASE/me" -b cookies.txt)
check 200 "$RES" "/me success"

echo "Testing /me without auth..."
RES=$(curl -s -w "%{http_code}" -X GET "$BASE/me")
check 401 "$RES" "/me without auth"

echo "Testing /password..."
RES=$(curl -s -w "%{http_code}" -X PUT "$BASE/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
check 200 "$RES" "/password success"

echo "Testing /password short new password..."
RES=$(curl -s -w "%{http_code}" -X PUT "$BASE/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "newpassword123", "new_password": "short"}')
check 400 "$RES" "/password short new password"

echo "Testing /todos (empty)..."
RES=$(curl -s -w "%{http_code}" -X GET "$BASE/todos" -b cookies.txt)
check 200 "$RES" "/todos empty"

echo "Testing POST /todos..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "My Todo", "description": "Do this"}')
check 201 "$RES" "POST /todos success"
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | grep -o '[0-9]*' | head -n1)
echo "Created Todo ID: $TODO_ID"

echo "Testing POST /todos missing title..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description": "Do this"}')
check 400 "$RES" "POST /todos missing title"

echo "Testing POST /todos empty title..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
check 400 "$RES" "POST /todos empty title"

echo "Testing GET /todos/:id..."
RES=$(curl -s -w "%{http_code}" -X GET "$BASE/todos/$TODO_ID" -b cookies.txt)
check 200 "$RES" "GET /todos/:id success"

echo "Testing GET /todos/:id not found..."
RES=$(curl -s -w "%{http_code}" -X GET "$BASE/todos/9999" -b cookies.txt)
check 404 "$RES" "GET /todos/:id not found"

echo "Testing PUT /todos/:id..."
RES=$(curl -s -w "%{http_code}" -X PUT "$BASE/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}')
check 200 "$RES" "PUT /todos/:id success"
if ! echo "$RES" | grep -q '"completed":true'; then
  echo "FAIL: completed should be true"
  kill $SERVER_PID || true
  cat server.log
  exit 1
fi

echo "Testing PUT /todos/:id empty title..."
RES=$(curl -s -w "%{http_code}" -X PUT "$BASE/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
check 400 "$RES" "PUT /todos/:id empty title"

echo "Testing DELETE /todos/:id..."
RES=$(curl -s -w "%{http_code}" -X DELETE "$BASE/todos/$TODO_ID" -b cookies.txt)
check 204 "$RES" "DELETE /todos/:id success"

echo "Testing DELETE /todos/:id not found..."
RES=$(curl -s -w "%{http_code}" -X DELETE "$BASE/todos/$TODO_ID" -b cookies.txt)
check 404 "$RES" "DELETE /todos/:id not found"

echo "Testing /logout..."
RES=$(curl -s -w "%{http_code}" -X POST "$BASE/logout" -b cookies.txt)
check 200 "$RES" "/logout success"

echo "Testing /me after logout..."
RES=$(curl -s -w "%{http_code}" -X GET "$BASE/me" -b cookies.txt)
check 401 "$RES" "/me after logout"

echo "All tests passed!"
kill $SERVER_PID || true
rm -f cookies.txt server.log