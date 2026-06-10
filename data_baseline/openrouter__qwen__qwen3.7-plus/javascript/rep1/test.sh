#!/bin/bash
set -e

PORT=3456

# Start server in background
node server.js --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 2

cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE_URL="http://127.0.0.1:$PORT"

test_endpoint() {
  local method=$1
  local url=$2
  local data=$3
  local expected_code=$4
  local cookie_file=$5
  local check_body=$6

  local curl_cmd="curl -s -w \"%{http_code}\" -X $method \"$BASE_URL$url\""
  if [ -n "$cookie_file" ]; then
    curl_cmd="$curl_cmd -b $cookie_file -c $cookie_file"
  fi
  if [ -n "$data" ]; then
    curl_cmd="$curl_cmd -H \"Content-Type: application/json\" -d '$data'"
  fi

  local RESP=$(eval $curl_cmd)
  local CODE="${RESP: -3}"
  local BODY="${RESP:0:-3}"

  if [ "$CODE" != "$expected_code" ]; then
    echo "FAIL: $method $url - Expected code $expected_code, got $CODE. Body: $BODY"
    exit 1
  fi

  if [ -n "$check_body" ]; then
    if ! echo "$BODY" | grep -q "$check_body"; then
      echo "FAIL: $method $url - Body check '$check_body' failed. Body: $BODY"
      exit 1
    fi
  fi
  
  echo "PASS: $method $url"
}

echo "Running tests..."

test_endpoint "POST" "/register" '{"username":"testuser","password":"password123"}' "201" "" '"id":1'
test_endpoint "POST" "/register" '{"username":"ab","password":"password123"}' "400" "" '"Invalid username"'
test_endpoint "POST" "/register" '{"username":"testuser2","password":"short"}' "400" "" '"Password too short"'
test_endpoint "POST" "/register" '{"username":"testuser","password":"password123"}' "409" "" '"Username already exists"'

COOKIE_FILE=$(mktemp)
test_endpoint "POST" "/login" '{"username":"testuser","password":"password123"}' "200" "$COOKIE_FILE" '"id":1'
test_endpoint "POST" "/login" '{"username":"testuser","password":"wrong"}' "401" "" '"Invalid credentials"'

test_endpoint "GET" "/me" "" "200" "$COOKIE_FILE" '"username":"testuser"'
test_endpoint "GET" "/me" "" "401" "" '"Authentication required"'

test_endpoint "PUT" "/password" '{"old_password":"password123","new_password":"newpassword123"}' "200" "$COOKIE_FILE" ""
test_endpoint "PUT" "/password" '{"old_password":"wrong","new_password":"newpassword123"}' "401" "$COOKIE_FILE" '"Invalid credentials"'
test_endpoint "PUT" "/password" '{"old_password":"newpassword123","new_password":"short"}' "400" "$COOKIE_FILE" '"Password too short"'

test_endpoint "GET" "/todos" "" "200" "$COOKIE_FILE" '\[\]'

test_endpoint "POST" "/todos" '{"title":"My first todo","description":"This is a description"}' "201" "$COOKIE_FILE" '"title":"My first todo"'
TODO_ID=$(curl -s -X GET "$BASE_URL/todos" -b "$COOKIE_FILE" | grep -o '"id":[0-9]*' | head -n 1 | cut -d':' -f2)

test_endpoint "POST" "/todos" '{"description":"No title"}' "400" "$COOKIE_FILE" '"Title is required"'

test_endpoint "GET" "/todos/$TODO_ID" "" "200" "$COOKIE_FILE" '"title":"My first todo"'
test_endpoint "GET" "/todos/9999" "" "404" "$COOKIE_FILE" '"Todo not found"'

test_endpoint "PUT" "/todos/$TODO_ID" '{"completed":true}' "200" "$COOKIE_FILE" '"completed":true'
test_endpoint "PUT" "/todos/$TODO_ID" '{"title":""}' "400" "$COOKIE_FILE" '"Title is required"'

test_endpoint "DELETE" "/todos/$TODO_ID" "" "204" "$COOKIE_FILE" ""
test_endpoint "DELETE" "/todos/$TODO_ID" "" "404" "$COOKIE_FILE" '"Todo not found"'

test_endpoint "POST" "/logout" "" "200" "$COOKIE_FILE" ""
test_endpoint "GET" "/me" "" "401" "$COOKIE_FILE" '"Authentication required"'

rm -f "$COOKIE_FILE"
echo "ALL TESTS PASSED!"