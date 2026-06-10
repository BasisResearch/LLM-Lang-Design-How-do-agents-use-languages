#!/bin/bash

# Start server in background
./run.sh --port 8891 > server.log 2>&1 &
SERVER_PID=$!
sleep 3

BASE_URL="http://127.0.0.1:8891"
PASS=0
FAIL=0

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name (expected $expected, got $actual)"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Running Tests ==="

# 1. Register
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' "$BASE_URL/register")
CODE=$(echo "$RES" | tail -n1)
check "Register" "201" "$CODE"

# 2. Register Duplicate
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' "$BASE_URL/register")
CODE=$(echo "$RES" | tail -n1)
check "Register Duplicate" "409" "$CODE"

# 3. Login
RES=$(curl -s -i -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' "$BASE_URL/login")
CODE=$(echo "$RES" | head -n1 | awk '{print $2}')
COOKIE=$(echo "$RES" | grep -i 'Set-Cookie' | grep -o 'session_id=[^;]*' | head -n1)
check "Login" "200" "$CODE"
if [ -z "$COOKIE" ]; then
    echo "FAIL: Login No cookie"
    FAIL=$((FAIL + 1))
else
    echo "PASS: Login Cookie"
    PASS=$((PASS + 1))
fi

# 4. Get Me
RES=$(curl -s -w "\n%{http_code}" -X GET -b "$COOKIE" "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
check "Get Me" "200" "$CODE"

# 5. Create Todo
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -b "$COOKIE" -d '{"title":"My Todo","description":"Do it"}' "$BASE_URL/todos")
CODE=$(echo "$RES" | tail -n1)
check "Create Todo" "201" "$CODE"
TODO_ID=$(echo "$RES" | sed '$d' | grep -o '"id":[0-9]*' | grep -o '[0-9]*')

# 6. Create Todo with Empty Title
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -b "$COOKIE" -d '{"title":""}' "$BASE_URL/todos")
CODE=$(echo "$RES" | tail -n1)
check "Create Todo Empty Title" "400" "$CODE"

# 7. Get Todos
RES=$(curl -s -w "\n%{http_code}" -X GET -b "$COOKIE" "$BASE_URL/todos")
CODE=$(echo "$RES" | tail -n1)
check "Get Todos" "200" "$CODE"

# 8. Get Todo By ID
RES=$(curl -s -w "\n%{http_code}" -X GET -b "$COOKIE" "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
check "Get Todo By ID" "200" "$CODE"

# 9. Other user's todo -> 404
curl -s -X POST -H "Content-Type: application/json" -d '{"username":"otheruser","password":"password123"}' "$BASE_URL/register" > /dev/null
OTHER_RES=$(curl -s -i -X POST -H "Content-Type: application/json" -d '{"username":"otheruser","password":"password123"}' "$BASE_URL/login")
OTHER_COOKIE=$(echo "$OTHER_RES" | grep -i 'Set-Cookie' | grep -o 'session_id=[^;]*' | head -n1)
OTHER_TODO_RES=$(curl -s -X POST -H "Content-Type: application/json" -b "$OTHER_COOKIE" -d '{"title":"Other Todo"}' "$BASE_URL/todos")
OTHER_TODO_ID=$(echo "$OTHER_TODO_RES" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
RES=$(curl -s -w "\n%{http_code}" -X GET -b "$COOKIE" "$BASE_URL/todos/$OTHER_TODO_ID")
CODE=$(echo "$RES" | tail -n1)
check "Get Other User Todo" "404" "$CODE"

# 10. Update Todo
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b "$COOKIE" -d '{"completed":true}' "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
check "Update Todo" "200" "$CODE"

# 11. Update Todo Empty Title
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b "$COOKIE" -d '{"title":""}' "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
check "Update Todo Empty Title" "400" "$CODE"

# 12. Delete Todo
RES=$(curl -s -w "\n%{http_code}" -X DELETE -b "$COOKIE" "$BASE_URL/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
check "Delete Todo" "204" "$CODE"

# 13. Delete Non-existent Todo
RES=$(curl -s -w "\n%{http_code}" -X DELETE -b "$COOKIE" "$BASE_URL/todos/9999")
CODE=$(echo "$RES" | tail -n1)
check "Delete Non-existent Todo" "404" "$CODE"

# 14. Change Password
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b "$COOKIE" -d '{"old_password":"password123","new_password":"newpassword123"}' "$BASE_URL/password")
CODE=$(echo "$RES" | tail -n1)
check "Change Password" "200" "$CODE"

# 15. Change Password Wrong Old
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b "$COOKIE" -d '{"old_password":"wrong","new_password":"newpassword123"}' "$BASE_URL/password")
CODE=$(echo "$RES" | tail -n1)
check "Change Password Wrong Old" "401" "$CODE"

# 16. Change Password Short New
RES=$(curl -s -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" -b "$COOKIE" -d '{"old_password":"newpassword123","new_password":"short"}' "$BASE_URL/password")
CODE=$(echo "$RES" | tail -n1)
check "Change Password Short New" "400" "$CODE"

# 17. Login with New Password
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"newpassword123"}' "$BASE_URL/login")
CODE=$(echo "$RES" | tail -n1)
check "Login New Password" "200" "$CODE"

# 18. Logout
RES=$(curl -s -w "\n%{http_code}" -X POST -b "$COOKIE" -d '{}' "$BASE_URL/logout")
CODE=$(echo "$RES" | tail -n1)
check "Logout" "200" "$CODE"

# 19. Auth Required after Logout
RES=$(curl -s -w "\n%{http_code}" -X GET -b "$COOKIE" "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
check "Auth Required after Logout" "401" "$CODE"

# 20. Invalid Credentials
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"wrong"}' "$BASE_URL/login")
CODE=$(echo "$RES" | tail -n1)
check "Invalid Credentials" "401" "$CODE"

# 21. Invalid Username Register
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}' "$BASE_URL/register")
CODE=$(echo "$RES" | tail -n1)
check "Invalid Username Register" "400" "$CODE"

# 22. Password Too Short Register
RES=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"validuser2","password":"short"}' "$BASE_URL/register")
CODE=$(echo "$RES" | tail -n1)
check "Password Too Short Register" "400" "$CODE"

# Cleanup
kill $SERVER_PID 2>/dev/null || true

echo ""
echo "========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi