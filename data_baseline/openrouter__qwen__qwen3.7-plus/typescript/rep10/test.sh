#!/bin/bash
set -e

PORT=3001
BASE_URL="http://localhost:$PORT"

echo "Starting server..."
./run.sh --port $PORT > server.log 2>&1 &
SERVER_PID=$!
sleep 5

check() {
  local name=$1
  local expected=$2
  local actual=$3
  if echo "$actual" | grep -qF "$expected"; then
    echo "✅ PASS: $name"
  else
    echo "❌ FAIL: $name"
    echo "Expected to contain: $expected"
    echo "Actual: $actual"
    kill $SERVER_PID || true
    exit 1
  fi
}

# 1. Register invalid username
RES=$(curl -s -X POST $BASE_URL/register -H 'Content-Type: application/json' -d '{"username":"a","password":"password123"}')
check "Register invalid username (short)" "Invalid username" "$RES"

RES=$(curl -s -X POST $BASE_URL/register -H 'Content-Type: application/json' -d '{"username":"user@1","password":"password123"}')
check "Register invalid username (chars)" "Invalid username" "$RES"

# 2. Register invalid password
RES=$(curl -s -X POST $BASE_URL/register -H 'Content-Type: application/json' -d '{"username":"user1","password":"short"}')
check "Register password too short" "Password too short" "$RES"

# 3. Register success
RES=$(curl -s -X POST $BASE_URL/register -H 'Content-Type: application/json' -d '{"username":"testuser","password":"password123"}')
check "Register success" "testuser" "$RES"

# 4. Register already exists
RES=$(curl -s -X POST $BASE_URL/register -H 'Content-Type: application/json' -d '{"username":"testuser","password":"password123"}')
check "Register already exists" "Username already exists" "$RES"

# 5. Login invalid
RES=$(curl -s -X POST $BASE_URL/login -H 'Content-Type: application/json' -d '{"username":"testuser","password":"wrongpass"}')
check "Login invalid credentials" "Invalid credentials" "$RES"

# 6. Login success
RES=$(curl -s -c cookies.txt -X POST $BASE_URL/login -H 'Content-Type: application/json' -d '{"username":"testuser","password":"password123"}')
check "Login success" "testuser" "$RES"

# 7. Me with cookie
RES=$(curl -s -X GET $BASE_URL/me -b cookies.txt)
check "Me success" "testuser" "$RES"

# 8. Me without cookie
RES=$(curl -s -X GET $BASE_URL/me)
check "Me no auth" "Authentication required" "$RES"

# 9. Change password invalid old
RES=$(curl -s -X PUT $BASE_URL/password -H 'Content-Type: application/json' -b cookies.txt -d '{"old_password":"wrong","new_password":"newpassword123"}')
check "Password invalid old" "Invalid credentials" "$RES"

# 10. Change password new too short
RES=$(curl -s -X PUT $BASE_URL/password -H 'Content-Type: application/json' -b cookies.txt -d '{"old_password":"password123","new_password":"short"}')
check "Password new too short" "Password too short" "$RES"

# 11. Change password success
RES=$(curl -s -X PUT $BASE_URL/password -H 'Content-Type: application/json' -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
check "Password change success" "{}" "$RES"

# 12. Create todo
RES=$(curl -s -X POST $BASE_URL/todos -H 'Content-Type: application/json' -b cookies.txt -d '{"title":"My first todo","description":"Some description"}')
check "Create todo" "My first todo" "$RES"
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')

# 13. List todos
RES=$(curl -s -X GET $BASE_URL/todos -b cookies.txt)
check "List todos" "My first todo" "$RES"

# 14. Get specific todo
RES=$(curl -s -X GET $BASE_URL/todos/$TODO_ID -b cookies.txt)
check "Get todo" "My first todo" "$RES"

# 15. Update todo
RES=$(curl -s -X PUT $BASE_URL/todos/$TODO_ID -H 'Content-Type: application/json' -b cookies.txt -d '{"completed":true}')
check "Update todo" "true" "$RES"

# 16. Update todo with empty title
RES=$(curl -s -X PUT $BASE_URL/todos/$TODO_ID -H 'Content-Type: application/json' -b cookies.txt -d '{"title":""}')
check "Update todo empty title" "Title is required" "$RES"

# 17. Get todo not found
RES=$(curl -s -X GET $BASE_URL/todos/9999 -b cookies.txt)
check "Get todo not found" "Todo not found" "$RES"

# 18. Delete todo
RES=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE $BASE_URL/todos/$TODO_ID -b cookies.txt)
check "Delete todo" "204" "$RES"

# 19. Logout
RES=$(curl -s -X POST $BASE_URL/logout -b cookies.txt)
check "Logout success" "{}" "$RES"

# 20. Me after logout
RES=$(curl -s -X GET $BASE_URL/me -b cookies.txt)
check "Me after logout" "Authentication required" "$RES"

# Cleanup
kill $SERVER_PID || true
rm -f cookies.txt server.log
echo "✅ All tests passed!"