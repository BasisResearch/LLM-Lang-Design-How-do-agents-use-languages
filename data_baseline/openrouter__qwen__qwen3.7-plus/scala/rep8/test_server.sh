#!/bin/bash

PORT=${1:-8085}
SERVER_URL="http://localhost:$PORT"

echo "==== Starting server on port $PORT ===="
pkill -f "scala-cli run Server.scala -- --port $PORT" || true
sleep 1

./run.sh --port $PORT > /tmp/server_test.log 2>&1 &
SERVER_PID=$!
sleep 8

echo "==== Checking if server is up ===="
if curl -s $SERVER_URL/me | grep -q "Authentication required"; then
    echo "Server is up!"
else
    echo "Server failed to start!"
    cat /tmp/server_test.log
    exit 1
fi

FAILED=0

test_endpoint() {
    local name="$1"
    local expected_status="$2"
    local expected_body_substring="$3"
    local method="${4:-GET}"
    local url="$5"
    local data="$6"
    local cookie="$7"

    echo "Testing: $name"
    
    if [ -n "$cookie" ]; then
        RESPONSE=$(curl -s -X "$method" -w "%{http_code}" "$url" -H "Content-Type: application/json" ${data:+-d "$data"} -b "$cookie")
    else
        RESPONSE=$(curl -s -X "$method" -w "%{http_code}" "$url" -H "Content-Type: application/json" ${data:+-d "$data"})
    fi
    
    HTTP_CODE="${RESPONSE: -3}"
    BODY="${RESPONSE:0:${#RESPONSE}-3}"
    
    if [ "$HTTP_CODE" != "$expected_status" ]; then
        echo "  FAIL: Expected status $expected_status, got $HTTP_CODE"
        echo "  Body: $BODY"
        FAILED=1
    elif [ -n "$expected_body_substring" ] && ! echo "$BODY" | grep -q "$expected_body_substring"; then
        echo "  FAIL: Expected body to contain '$expected_body_substring', got '$BODY'"
        FAILED=1
    else
        echo "  PASS: Status $HTTP_CODE"
    fi
}

# 1. Register - Success
test_endpoint "Register User 1" "201" '"username":"user1"' "POST" "$SERVER_URL/register" '{"username": "user1", "password": "password123"}'

# 2. Register - Invalid username
test_endpoint "Register Invalid Username" "400" '"error":"Invalid username"' "POST" "$SERVER_URL/register" '{"username": "ab", "password": "password123"}'

# 3. Register - Password too short
test_endpoint "Register Password Too Short" "400" '"error":"Password too short"' "POST" "$SERVER_URL/register" '{"username": "user2", "password": "short"}'

# 4. Register - Duplicate
test_endpoint "Register Duplicate" "409" '"error":"Username already exists"' "POST" "$SERVER_URL/register" '{"username": "user1", "password": "password123"}'

# 5. Register User 2
test_endpoint "Register User 2" "201" '"username":"user2"' "POST" "$SERVER_URL/register" '{"username": "user2", "password": "password123"}'

# 6. Login - Success
echo "Testing: Login Success"
LOGIN_RESP=$(curl -si -X POST "$SERVER_URL/login" -H "Content-Type: application/json" -d '{"username": "user1", "password": "password123"}')
HTTP_CODE=$(echo "$LOGIN_RESP" | grep -oP '(?<=HTTP/1.1 )\d+')
COOKIE1=$(echo "$LOGIN_RESP" | grep -oP 'session_id=[^;]+')
if [ "$HTTP_CODE" = "200" ] && echo "$LOGIN_RESP" | grep -q '"username":"user1"'; then
    echo "  PASS: Status $HTTP_CODE"
else
    echo "  FAIL: Expected status 200, got $HTTP_CODE"
    echo "  Response: $LOGIN_RESP"
    FAILED=1
fi

# 7. Login - Fail
test_endpoint "Login Fail" "401" '"error":"Invalid credentials"' "POST" "$SERVER_URL/login" '{"username": "user1", "password": "wrong"}'

# 8. Me - No cookie
test_endpoint "Me No Cookie" "401" '"error":"Authentication required"' "GET" "$SERVER_URL/me"

# 9. Me - With cookie
test_endpoint "Me With Cookie" "200" '"username":"user1"' "GET" "$SERVER_URL/me" "" "$COOKIE1"

# 10. Update Password - Success
test_endpoint "Update Password Success" "200" "" "PUT" "$SERVER_URL/password" '{"old_password": "password123", "new_password": "newpassword1"}' "$COOKIE1"

# 11. Get new cookie for user 1 after password change
LOGIN_RESP1_NEW=$(curl -si -X POST "$SERVER_URL/login" -H "Content-Type: application/json" -d '{"username": "user1", "password": "newpassword1"}')
COOKIE1_NEW=$(echo "$LOGIN_RESP1_NEW" | grep -oP 'session_id=[^;]+')

# 12. Update Password - Old password fail
test_endpoint "Update Password Wrong Old Password" "401" '"error":"Invalid credentials"' "PUT" "$SERVER_URL/password" '{"old_password": "password123", "new_password": "newpassword2"}' "$COOKIE1_NEW"

# 13. Update Password - New password too short
test_endpoint "Update Password New Password Too Short" "400" '"error":"Password too short"' "PUT" "$SERVER_URL/password" '{"old_password": "newpassword1", "new_password": "short"}' "$COOKIE1_NEW"

# 14. Get Todos - Empty
test_endpoint "Get Todos Empty" "200" '\[\]' "GET" "$SERVER_URL/todos" "" "$COOKIE1_NEW"

# 15. Create Todo - Success
test_endpoint "Create Todo Success" "201" '"title":"Buy milk"' "POST" "$SERVER_URL/todos" '{"title": "Buy milk", "description": "Get 2% milk"}' "$COOKIE1_NEW"

# 16. Create Todo - No title
test_endpoint "Create Todo No Title" "400" '"error":"Title is required"' "POST" "$SERVER_URL/todos" '{"description": "Get 2% milk"}' "$COOKIE1_NEW"

# 17. Create Todo - Empty title
test_endpoint "Create Todo Empty Title" "400" '"error":"Title is required"' "POST" "$SERVER_URL/todos" '{"title": "", "description": "Get 2% milk"}' "$COOKIE1_NEW"

# 18. Create Todo - Whitespace title
test_endpoint "Create Todo Whitespace Title" "400" '"error":"Title is required"' "POST" "$SERVER_URL/todos" '{"title": "   ", "description": "Get 2% milk"}' "$COOKIE1_NEW"

# 19. Get Todos - With one todo
test_endpoint "Get Todos With Data" "200" '"title":"Buy milk"' "GET" "$SERVER_URL/todos" "" "$COOKIE1_NEW"

# 20. Get Specific Todo - Success
test_endpoint "Get Specific Todo Success" "200" '"id":1' "GET" "$SERVER_URL/todos/1" "" "$COOKIE1_NEW"

# 21. Get Specific Todo - Not found (wrong id)
test_endpoint "Get Specific Todo Not Found" "404" '"error":"Todo not found"' "GET" "$SERVER_URL/todos/999" "" "$COOKIE1_NEW"

# 22. Create Todo for User 2
echo "Testing: Create Todo User 2"
LOGIN_RESP_U2=$(curl -si -X POST "$SERVER_URL/login" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}')
COOKIE_U2=$(echo "$LOGIN_RESP_U2" | grep -oP 'session_id=[^;]+')
curl -s -X POST "$SERVER_URL/todos" -H "Content-Type: application/json" -d '{"title": "User 2 Todo"}' -b "$COOKIE_U2" > /dev/null

# 23. Get Specific Todo - Other user's todo (should be 404 to prevent enumeration)
# User 1 (COOKIE1_NEW) tries to get User 2's todo (id=2)
test_endpoint "Get Other User Todo" "404" '"error":"Todo not found"' "GET" "$SERVER_URL/todos/2" "" "$COOKIE1_NEW"

# 24. Update Specific Todo - Success (partial update)
test_endpoint "Update Specific Todo Success" "200" '"completed":true' "PUT" "$SERVER_URL/todos/1" '{"completed": true}' "$COOKIE1_NEW"

# 25. Update Specific Todo - Empty title
test_endpoint "Update Specific Todo Empty Title" "400" '"error":"Title is required"' "PUT" "$SERVER_URL/todos/1" '{"title": ""}' "$COOKIE1_NEW"

# 26. Update Specific Todo - Not found
test_endpoint "Update Specific Todo Not Found" "404" '"error":"Todo not found"' "PUT" "$SERVER_URL/todos/999" '{"completed": false}' "$COOKIE1_NEW"

# 27. Delete Other User Todo - User 1 (COOKIE1_NEW) tries to delete User 2's todo (id=2). MUST be 404.
test_endpoint "Delete Other User Todo" "404" '"error":"Todo not found"' "DELETE" "$SERVER_URL/todos/2" "" "$COOKIE1_NEW"

# 28. Delete Specific Todo - Success (User 1 deletes their own todo)
test_endpoint "Delete Specific Todo Success" "204" "" "DELETE" "$SERVER_URL/todos/1" "" "$COOKIE1_NEW"

# 29. Delete Specific Todo - Already deleted / Not found
test_endpoint "Delete Specific Todo Not Found" "404" '"error":"Todo not found"' "DELETE" "$SERVER_URL/todos/1" "" "$COOKIE1_NEW"

# 30. Logout
test_endpoint "Logout" "200" '\{\}' "POST" "$SERVER_URL/logout" "" "$COOKIE1_NEW"

# 31. Me after logout
test_endpoint "Me After Logout" "401" '"error":"Authentication required"' "GET" "$SERVER_URL/me" "" "$COOKIE1_NEW"

echo "==== Stopping server ===="
kill $SERVER_PID 2>/dev/null || true

if [ $FAILED -eq 0 ]; then
    echo "==== ALL TESTS PASSED ===="
    exit 0
else
    echo "==== SOME TESTS FAILED ===="
    exit 1
fi