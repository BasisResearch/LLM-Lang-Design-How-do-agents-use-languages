#!/bin/bash
set -e

PORT=8080

# Start server in background
./run.sh --port $PORT &
SERVER_PID=$!
sleep 1

trap "kill $SERVER_PID 2>/dev/null || true" EXIT

BASE_URL="http://localhost:$PORT"

echo "=== Testing POST /register ==="
REG_RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
REG_BODY=$(echo "$REG_RESP" | head -n 1)
REG_CODE=$(echo "$REG_RESP" | tail -n 1)
echo "Register response code: $REG_CODE, body: $REG_BODY"
if [ "$REG_CODE" != "201" ]; then echo "FAIL: Expected 201 for register"; exit 1; fi
if ! echo "$REG_BODY" | grep -q '"id"'; then echo "FAIL: Expected id in register response"; exit 1; fi

# Test duplicate register
REG_DUP_BODY=$(curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
echo "Duplicate register: $REG_DUP_BODY"
if ! echo "$REG_DUP_BODY" | grep -q 'Username already exists'; then echo "FAIL: Expected Username already exists"; exit 1; fi

# Test invalid username
REG_INV_BODY=$(curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
echo "Short username: $REG_INV_BODY"
if ! echo "$REG_INV_BODY" | grep -q 'Invalid username'; then echo "FAIL: Expected Invalid username"; exit 1; fi

# Test invalid password
REG_INV_PASS=$(curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser2","password":"short"}')
echo "Short password: $REG_INV_PASS"
if ! echo "$REG_INV_PASS" | grep -q 'Password too short'; then echo "FAIL: Expected Password too short"; exit 1; fi

echo "=== Testing POST /login ==="
LOGIN_RESP=$(curl -s -c cookies.txt -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
LOGIN_BODY=$(echo "$LOGIN_RESP" | head -n 1)
LOGIN_CODE=$(echo "$LOGIN_RESP" | tail -n 1)
echo "Login response code: $LOGIN_CODE, body: $LOGIN_BODY"
if [ "$LOGIN_CODE" != "200" ]; then echo "FAIL: Expected 200 for login"; exit 1; fi

# Test invalid credentials
LOGIN_INV=$(curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"wrongpass"}')
echo "Invalid login: $LOGIN_INV"
if ! echo "$LOGIN_INV" | grep -q 'Invalid credentials'; then echo "FAIL: Expected Invalid credentials"; exit 1; fi

echo "=== Testing GET /me ==="
ME_BODY=$(curl -s -b cookies.txt "$BASE_URL/me")
echo "Me response: $ME_BODY"
if ! echo "$ME_BODY" | grep -q 'testuser'; then echo "FAIL: Expected testuser in me response"; exit 1; fi

# Test unauthenticated /me
ME_UNAUTH_RESP=$(curl -s -w "\n%{http_code}" "$BASE_URL/me")
ME_UNAUTH_CODE=$(echo "$ME_UNAUTH_RESP" | tail -n 1)
if [ "$ME_UNAUTH_CODE" != "401" ]; then echo "FAIL: Expected 401 for unauthenticated me"; exit 1; fi

echo "=== Testing POST /logout ==="
LOGOUT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X POST "$BASE_URL/logout")
echo "Logout response code: $LOGOUT_CODE"
if [ "$LOGOUT_CODE" != "200" ]; then echo "FAIL: Expected 200 for logout"; exit 1; fi

# Test me after logout
ME_LOGOUT_RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/me")
ME_LOGOUT_CODE=$(echo "$ME_LOGOUT_RESP" | tail -n 1)
if [ "$ME_LOGOUT_CODE" != "401" ]; then echo "FAIL: Expected 401 after logout"; exit 1; fi

# Login again for remaining tests
curl -s -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' > /dev/null

echo "=== Testing PUT /password ==="
PASS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password":"password123","new_password":"newpassword123"}')
echo "Password change code: $PASS_CODE"
if [ "$PASS_CODE" != "200" ]; then echo "FAIL: Expected 200 for password change"; exit 1; fi

# Test wrong old password
PASS_WRONG=$(curl -s -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password":"wrongpass","new_password":"newpassword123"}')
echo "Wrong old pass: $PASS_WRONG"
if ! echo "$PASS_WRONG" | grep -q 'Invalid credentials'; then echo "FAIL: Expected Invalid credentials for wrong old password"; exit 1; fi

# Test short new password
PASS_SHORT=$(curl -s -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password":"newpassword123","new_password":"short"}')
echo "Short new pass: $PASS_SHORT"
if ! echo "$PASS_SHORT" | grep -q 'Password too short'; then echo "FAIL: Expected Password too short"; exit 1; fi

echo "=== Testing POST /todos ==="
TODO_RESP=$(curl -s -b cookies.txt -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title":"My Todo","description":"Test description"}')
TODO_BODY=$(echo "$TODO_RESP" | head -n 1)
TODO_CODE=$(echo "$TODO_RESP" | tail -n 1)
echo "Create todo code: $TODO_CODE, body: $TODO_BODY"
if [ "$TODO_CODE" != "201" ]; then echo "FAIL: Expected 201 for create todo"; exit 1; fi
if ! echo "$TODO_BODY" | grep -q '"title":"My Todo"'; then echo "FAIL: Expected title in todo response"; exit 1; fi

# Test empty title
TODO_EMPTY_TITLE=$(curl -s -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"description":"Test"}')
echo "Empty title: $TODO_EMPTY_TITLE"
if ! echo "$TODO_EMPTY_TITLE" | grep -q 'Title is required'; then echo "FAIL: Expected Title is required"; exit 1; fi

echo "=== Testing GET /todos ==="
TODOS_LIST=$(curl -s -b cookies.txt "$BASE_URL/todos")
echo "Todos list: $TODOS_LIST"
if ! echo "$TODOS_LIST" | grep -q 'My Todo'; then echo "FAIL: Expected My Todo in todos list"; exit 1; fi

echo "=== Testing GET /todos/:id ==="
TODO_ID=$(echo "$TODO_BODY" | sed 's/.*"id":\([0-9]*\).*/\1/' | head -1)
TODO_GET=$(curl -s -b cookies.txt "$BASE_URL/todos/$TODO_ID")
echo "Get single todo: $TODO_GET"
if ! echo "$TODO_GET" | grep -q 'My Todo'; then echo "FAIL: Expected My Todo in get todo response"; exit 1; fi

# Test not found
TODO_404=$(curl -s -b cookies.txt "$BASE_URL/todos/99999")
echo "Not found todo: $TODO_404"
if ! echo "$TODO_404" | grep -q 'Todo not found'; then echo "FAIL: Expected Todo not found"; exit 1; fi

echo "=== Testing PUT /todos/:id ==="
TODO_UPDATE=$(curl -s -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"title":"Updated Todo","completed":true}')
echo "Update todo: $TODO_UPDATE"
if ! echo "$TODO_UPDATE" | grep -q '"completed":true'; then echo "FAIL: Expected completed true"; exit 1; fi
if ! echo "$TODO_UPDATE" | grep -q 'Updated Todo'; then echo "FAIL: Expected Updated Todo"; exit 1; fi

# Test empty title update
TODO_EMPTY_UPDATE=$(curl -s -b cookies.txt -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"title":""}')
echo "Empty title update: $TODO_EMPTY_UPDATE"
if ! echo "$TODO_EMPTY_UPDATE" | grep -q 'Title is required'; then echo "FAIL: Expected Title is required on update"; exit 1; fi

echo "=== Testing DELETE /todos/:id ==="
DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/$TODO_ID")
echo "Delete todo code: $DEL_CODE"
if [ "$DEL_CODE" != "204" ]; then echo "FAIL: Expected 204 for delete todo"; exit 1; fi

# Test delete not found
DEL_CODE2=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/$TODO_ID")
if [ "$DEL_CODE2" != "404" ]; then echo "FAIL: Expected 404 for deleted todo"; exit 1; fi

echo "=== ALL TESTS PASSED ==="