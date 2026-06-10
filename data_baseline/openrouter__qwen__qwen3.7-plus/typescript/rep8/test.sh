#!/bin/bash

PORT=48912
echo "Starting server on port $PORT..."
node dist/server.js --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 2

FAIL=0

register() {
  local res=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "201" ]; then
    echo "FAIL: POST /register expected 201, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: POST /register"
  fi
}

login() {
  local res=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "200" ]; then
    echo "FAIL: POST /login expected 200, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: POST /login"
  fi
}

get_me() {
  local res=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:$PORT/me)
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "200" ]; then
    echo "FAIL: GET /me expected 200, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: GET /me"
  fi
}

put_password() {
  local res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:$PORT/password -H "Content-Type: application/json" -d '{"old_password":"password123","new_password":"newpassword123"}')
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "200" ]; then
    echo "FAIL: PUT /password expected 200, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: PUT /password"
  fi
}

post_todo() {
  local res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST http://localhost:$PORT/todos -H "Content-Type: application/json" -d '{"title":"Test Todo","description":"A test"}')
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "201" ]; then
    echo "FAIL: POST /todos expected 201, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: POST /todos"
  fi
}

get_todos() {
  local res=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:$PORT/todos)
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "200" ]; then
    echo "FAIL: GET /todos expected 200, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: GET /todos"
  fi
}

get_todo() {
  local res=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:$PORT/todos/1)
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "200" ]; then
    echo "FAIL: GET /todos/1 expected 200, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: GET /todos/1"
  fi
}

put_todo() {
  local res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:$PORT/todos/1 -H "Content-Type: application/json" -d '{"completed":true}')
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "200" ]; then
    echo "FAIL: PUT /todos/1 expected 200, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: PUT /todos/1"
  fi
}

delete_todo() {
  local res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE http://localhost:$PORT/todos/1)
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "204" ]; then
    echo "FAIL: DELETE /todos/1 expected 204, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: DELETE /todos/1"
  fi
}

todo_not_found() {
  local res=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:$PORT/todos/999)
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "404" ]; then
    echo "FAIL: GET /todos/999 expected 404, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: GET /todos/999"
  fi
}

logout() {
  local res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST http://localhost:$PORT/logout)
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "200" ]; then
    echo "FAIL: POST /logout expected 200, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: POST /logout"
  fi
}

get_me_unauth() {
  local res=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/me)
  local code=$(echo "$res" | tail -n1)
  if [ "$code" != "401" ]; then
    echo "FAIL: GET /me unauth expected 401, got $code. Response: $res"
    FAIL=1
  else
    echo "PASS: GET /me unauth"
  fi
}

# Run tests
register
login
get_me
put_password
post_todo
get_todos
get_todo
put_todo
delete_todo
todo_not_found
logout
get_me_unauth

# Cleanup
kill $SERVER_PID 2>/dev/null
rm -f cookies.txt

if [ $FAIL -eq 0 ]; then
  echo "All tests passed!"
  exit 0
else
  echo "Some tests failed."
  exit 1
fi
