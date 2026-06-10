#!/bin/bash

PORT=8080
if [[ "$1" == "--port" ]]; then
    PORT="$2"
fi

echo "Starting server..."
./run.sh --port $PORT > server.log 2>&1 &
SERVER_PID=$!

# Wait for server to start
for i in {1..15}; do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:$PORT/register | grep -q "400\|405"; then
        echo "Server is ready."
        break
    fi
    sleep 1
done

curl_json() {
    curl -s -w "\nHTTP_CODE:%{http_code}" "$@"
}

FAILED=0

test_endpoint() {
    local name=$1
    local expected_code=$2
    local expected_str=$3
    local res=$4
    
    local code_match=false
    if [[ "$res" == *"HTTP_CODE:$expected_code"* ]]; then
        code_match=true
    fi
    
    local str_match=false
    if [[ -z "$expected_str" ]] || [[ "$res" == *"$expected_str"* ]]; then
        str_match=true
    fi

    if $code_match && $str_match; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        echo "Expected code: $expected_code, str: $expected_str"
        echo "Response: $res"
        FAILED=1
    fi
}

echo "=== Running Tests ==="

# 1. Register
RES=$(curl_json -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
test_endpoint "register" "201" "testuser" "$RES"

# 2. Register duplicate
RES=$(curl_json -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
test_endpoint "register duplicate" "409" "Username already exists" "$RES"

# 3. Invalid username
RES=$(curl_json -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
test_endpoint "register invalid username" "400" "Invalid username" "$RES"

# 4. Password too short
RES=$(curl_json -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username":"validuser123","password":"short"}')
test_endpoint "register password too short" "400" "Password too short" "$RES"

# 5. Login
RES=$(curl_json -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
test_endpoint "login" "200" "testuser" "$RES"

# 6. Login invalid credentials
RES=$(curl_json -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username":"testuser","password":"wrongpassword"}')
test_endpoint "login invalid credentials" "401" "Invalid credentials" "$RES"

# 7. Me
RES=$(curl_json -X GET http://localhost:$PORT/me -b cookies.txt)
test_endpoint "me" "200" "testuser" "$RES"

# 8. Password
RES=$(curl_json -X PUT http://localhost:$PORT/password -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
test_endpoint "password" "200" "{}" "$RES"

# 9. Password invalid old
RES=$(curl_json -X PUT http://localhost:$PORT/password -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"wrongpass","new_password":"newpassword123"}')
test_endpoint "password invalid old" "401" "Invalid credentials" "$RES"

# 10. Password too short new
RES=$(curl_json -X PUT http://localhost:$PORT/password -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"newpassword123","new_password":"short"}')
test_endpoint "password new too short" "400" "Password too short" "$RES"

# 11. Post Todo
RES=$(curl_json -X POST http://localhost:$PORT/todos -H "Content-Type: application/json" -b cookies.txt -d '{"title":"My Todo","description":"Do this"}')
test_endpoint "post todo" "201" "My Todo" "$RES"

# 12. Post Todo missing title
RES=$(curl_json -X POST http://localhost:$PORT/todos -H "Content-Type: application/json" -b cookies.txt -d '{"description":"Do this"}')
test_endpoint "post todo missing title" "400" "Title is required" "$RES"

# 13. Post Todo empty title
RES=$(curl_json -X POST http://localhost:$PORT/todos -H "Content-Type: application/json" -b cookies.txt -d '{"title":"","description":"Do this"}')
test_endpoint "post todo empty title" "400" "Title is required" "$RES"

# 14. Get Todos
RES=$(curl_json -X GET http://localhost:$PORT/todos -b cookies.txt)
test_endpoint "get todos" "200" "My Todo" "$RES"

# 15. Get Todo
RES=$(curl_json -X GET http://localhost:$PORT/todos/1 -b cookies.txt)
test_endpoint "get todo 1" "200" "My Todo" "$RES"

# 16. Get Todo not found
RES=$(curl_json -X GET http://localhost:$PORT/todos/999 -b cookies.txt)
test_endpoint "get todo not found" "404" "Todo not found" "$RES"

# 17. Put Todo
RES=$(curl_json -X PUT http://localhost:$PORT/todos/1 -H "Content-Type: application/json" -b cookies.txt -d '{"title":"Updated Todo","completed":true}')
test_endpoint "put todo 1" "200" "Updated Todo" "$RES"

# 18. Put Todo empty title
RES=$(curl_json -X PUT http://localhost:$PORT/todos/1 -H "Content-Type: application/json" -b cookies.txt -d '{"title":""}')
test_endpoint "put todo empty title" "400" "Title is required" "$RES"

# 19. Logout
RES=$(curl_json -X POST http://localhost:$PORT/logout -b cookies.txt)
test_endpoint "logout" "200" "{}" "$RES"

# 20. Me after logout
RES=$(curl_json -X GET http://localhost:$PORT/me -b cookies.txt)
test_endpoint "me after logout" "401" "Authentication required" "$RES"

# 21. Delete Todo (need re-login)
curl -s -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' -c cookies.txt > /dev/null
RES=$(curl_json -X DELETE http://localhost:$PORT/todos/1 -b cookies.txt)
test_endpoint "delete todo 1" "204" "" "$RES"

# 22. Get deleted todo
RES=$(curl_json -X GET http://localhost:$PORT/todos/1 -b cookies.txt)
test_endpoint "get deleted todo" "404" "Todo not found" "$RES"

# 23. Delete todo not found
RES=$(curl_json -X DELETE http://localhost:$PORT/todos/999 -b cookies.txt)
test_endpoint "delete todo not found" "404" "Todo not found" "$RES"

# 24. Another user cannot access todo
# Create another user
curl -s -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username":"user2","password":"password123"}' > /dev/null
curl -s -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username":"user2","password":"password123"}' -c cookies2.txt > /dev/null
# Create a todo for user2
curl -s -X POST http://localhost:$PORT/todos -H "Content-Type: application/json" -b cookies2.txt -d '{"title":"User2 Todo"}' > /dev/null
# User 1 tries to access User 2's todo (todo id 2)
curl -s -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' -c cookies.txt > /dev/null
RES=$(curl_json -X GET http://localhost:$PORT/todos/2 -b cookies.txt)
test_endpoint "get another user's todo" "404" "Todo not found" "$RES"

# Cleanup
kill $SERVER_PID 2>/dev/null
rm -f cookies.txt cookies2.txt

echo ""
if [ $FAILED -eq 0 ]; then
    echo "=== ALL TESTS PASSED ==="
else
    echo "=== SOME TESTS FAILED ==="
    exit 1
fi
