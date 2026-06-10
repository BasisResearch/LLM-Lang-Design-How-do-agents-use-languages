#!/bin/bash
set -e
PORT=3458
BASE="http://localhost:$PORT"

echo "Starting server..."
node server.js --port $PORT &
SERVER_PID=$!
sleep 2

test_api() {
  local method=$1
  local path=$2
  local data=$3
  local expected_code=$4
  local expected_body_contains=$5
  local cookie_file=$6

  local curl_args=(-s -w 'DELIM%{http_code}' -X "$method" "$BASE$path")
  if [ -n "$cookie_file" ]; then
    curl_args+=(-b "$cookie_file")
  fi
  if [ -n "$data" ]; then
    curl_args+=(-d "$data")
  fi

  echo "Running: curl ${curl_args[@]}"
  local RES=$(curl "${curl_args[@]}")
  local CODE="${RES##*DELIM}"
  local BODY="${RES%DELIM*}"
  echo "Code: $CODE, Body: $BODY"

  if [ "$CODE" != "$expected_code" ]; then
    echo "FAIL: $method $path - expected code $expected_code, got $CODE"
    kill $SERVER_PID
    exit 1
  fi
  echo "PASS: $method $path"
}

test_api POST /register '{"username": "user1", "password": "password123"}' 201 '"id":1'
test_api POST /login '{"username": "user1", "password": "password123"}' 200 '"id":1' "" # Note: login saves cookie, handled separately

# Let's do login with cookie save
curl -s -c cookies.txt -X POST "$BASE/login" -d '{"username": "user1", "password": "password123"}' > /dev/null
echo "Saved cookies"

test_api GET /me '' 200 '"username":"user1"' "cookies.txt"
test_api POST /todos '{"title": "My Todo", "description": "Do this"}' 201 '"title":"My Todo"' "cookies.txt"

RES=$(curl -s -w 'DELIM%{http_code}' -b cookies.txt -X GET "$BASE/todos")
CODE="${RES##*DELIM}"
BODY="${RES%DELIM*}"
echo "List todos Code: $CODE"
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
echo "TODO_ID: $TODO_ID"

test_api GET /todos/$TODO_ID '' 200 '"title":"My Todo"' "cookies.txt"
test_api PUT /todos/$TODO_ID '{"completed": true}' 200 '"completed":true' "cookies.txt"
test_api DELETE /todos/$TODO_ID '' 204 "" "cookies.txt"
test_api GET /todos/$TODO_ID '' 404 "Todo not found" "cookies.txt"

echo "ALL TESTS PASSED!"
kill $SERVER_PID
