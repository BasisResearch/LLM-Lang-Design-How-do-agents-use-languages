#!/bin/bash
set -e

PORT=3001
echo "Starting server on port $PORT..."
node server.js --port $PORT &
SERVER_PID=$!

# Wait for server to be ready
for i in {1..10}; do
  if curl -s "http://localhost:$PORT/me" > /dev/null 2>&1; then
    break
  fi
  sleep 1
done

COOKIE_JAR=$(mktemp)
trap "rm -f $COOKIE_JAR; kill $SERVER_PID 2>/dev/null" EXIT

run_test() {
  local name=$1
  local method=$2
  local url=$3
  local data=$4
  local expected_code=$5
  local use_cookie=$6
  
  echo -n "Testing $name... "
  
  if [ "$use_cookie" = "true" ]; then
    if [ -n "$data" ]; then
      RESPONSE=$(curl -s -w "\n%{http_code}" -X "$method" "$url" -b "$COOKIE_JAR" -H "Content-Type: application/json" -d "$data")
    else
      RESPONSE=$(curl -s -w "\n%{http_code}" -X "$method" "$url" -b "$COOKIE_JAR")
    fi
  else
    if [ -n "$data" ]; then
      RESPONSE=$(curl -s -w "\n%{http_code}" -X "$method" "$url" -H "Content-Type: application/json" -d "$data")
    else
      RESPONSE=$(curl -s -w "\n%{http_code}" -X "$method" "$url")
    fi
  fi
  
  CODE=$(echo "$RESPONSE" | tail -n1)
  
  if [ "$CODE" != "$expected_code" ]; then
    echo "FAILED (Expected code $expected_code, got $CODE)"
    echo "Response: $(echo "$RESPONSE" | sed '$d')"
    exit 1
  fi
  echo "OK"
}

# 1. Register user (no cookie needed)
run_test "Register user" "POST" "http://localhost:$PORT/register" '{"username":"testuser","password":"password123"}' "201" "false"

# 2. Register duplicate (no cookie needed)
run_test "Register duplicate" "POST" "http://localhost:$PORT/register" '{"username":"testuser","password":"password123"}' "409" "false"

# 3. Login and save cookie (no cookie needed for login, but saves to jar)
curl -s -c "$COOKIE_JAR" -X POST "http://localhost:$PORT/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' > /dev/null
echo "Login OK"

# 4. Login invalid (no cookie needed)
run_test "Login invalid" "POST" "http://localhost:$PORT/login" '{"username":"testuser","password":"wrong"}' "401" "false"

# 5. GET /me (needs cookie)
RESP=$(curl -s -b "$COOKIE_JAR" "http://localhost:$PORT/me")
if [[ "$RESP" != *'"username":"testuser"'* ]]; then
  echo "GET /me FAILED: $RESP"
  exit 1
fi
echo "GET /me OK"

# 6. GET /me without auth (no cookie)
run_test "GET /me without auth" "GET" "http://localhost:$PORT/me" "" "401" "false"

# 7. PUT /password (needs cookie)
run_test "PUT /password" "PUT" "http://localhost:$PORT/password" '{"old_password":"password123","new_password":"newpassword123"}' "200" "true"

# 8. PUT /password invalid old (needs cookie)
run_test "PUT /password invalid old" "PUT" "http://localhost:$PORT/password" '{"old_password":"wrong","new_password":"newpassword123"}' "401" "true"

# 9. PUT /password short new (needs cookie)
run_test "PUT /password short new" "PUT" "http://localhost:$PORT/password" '{"old_password":"newpassword123","new_password":"short"}' "400" "true"

# Reset password for remaining tests (needs cookie)
curl -s -b "$COOKIE_JAR" -X PUT "http://localhost:$PORT/password" -H "Content-Type: application/json" -d '{"old_password":"newpassword123","new_password":"password123"}' > /dev/null

# 10. POST /todos (needs cookie)
run_test "POST /todos" "POST" "http://localhost:$PORT/todos" '{"title":"My Todo","description":"A description"}' "201" "true"

# 11. POST /todos missing title (needs cookie)
run_test "POST /todos missing title" "POST" "http://localhost:$PORT/todos" '{"description":"No title"}' "400" "true"

# 12. POST /todos empty title (needs cookie)
run_test "POST /todos empty title" "POST" "http://localhost:$PORT/todos" '{"title":""}' "400" "true"

# 13. GET /todos (needs cookie)
RESP=$(curl -s -b "$COOKIE_JAR" "http://localhost:$PORT/todos")
TODO_ID=$(node -e "try { const data = JSON.parse(process.argv[1]); console.log(data[0] ? data[0].id : data.id); } catch(e) { process.exit(1); }" "$RESP")
if [ -z "$TODO_ID" ]; then
  echo "Could not find todo ID"
  exit 1
fi
echo "GET /todos OK"

# 14. GET /todos/:id (needs cookie)
run_test "GET /todos/:id" "GET" "http://localhost:$PORT/todos/$TODO_ID" "" "200" "true"

# 15. PUT /todos/:id (needs cookie)
run_test "PUT /todos/:id" "PUT" "http://localhost:$PORT/todos/$TODO_ID" '{"completed":true}' "200" "true"

# 16. PUT /todos/:id empty title (needs cookie)
run_test "PUT /todos/:id empty title" "PUT" "http://localhost:$PORT/todos/$TODO_ID" '{"title":""}' "400" "true"

# 17. DELETE /todos/:id (needs cookie)
run_test "DELETE /todos/:id" "DELETE" "http://localhost:$PORT/todos/$TODO_ID" "" "204" "true"

# 18. GET /todos/:id after delete (needs cookie)
run_test "GET /todos/:id after delete" "GET" "http://localhost:$PORT/todos/$TODO_ID" "" "404" "true"

# 19. POST /logout (needs cookie)
run_test "POST /logout" "POST" "http://localhost:$PORT/logout" "" "200" "true"

# 20. GET /me after logout (needs cookie, but should fail with 401)
run_test "GET /me after logout" "GET" "http://localhost:$PORT/me" "" "401" "true"

echo "All tests passed!"