#!/bin/bash

# Start server
./run.sh --port 8080 > server.log 2>&1 &
SERVER_PID=$!

# Wait for server to be ready
for i in {1..10}; do
    if curl -s http://127.0.0.1:8080/me 2>/dev/null; then
        break
    fi
    sleep 0.5
done

# Cleanup on exit
cleanup() {
    kill $SERVER_PID 2>/dev/null
    rm -f cookies.txt server.log
}
trap cleanup EXIT

BASE_URL="http://127.0.0.1:8080"
FAILED=0

# 1. Register user (success)
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
     -H "Content-Type: application/json" \
     -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ]; then
    echo "FAIL: Register expected 201, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: Register"
fi

# 2. Register duplicate username (409)
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
     -H "Content-Type: application/json" \
     -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "409" ]; then
    echo "FAIL: Register duplicate expected 409, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: Register duplicate"
fi

# 3. Register invalid username (400)
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" \
     -H "Content-Type: application/json" \
     -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "400" ]; then
    echo "FAIL: Register invalid username expected 400, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: Register invalid username"
fi

# 4. Login (success) and get cookie
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
     -H "Content-Type: application/json" \
     -d '{"username": "testuser", "password": "password123"}' \
     -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ]; then
    echo "FAIL: Login expected 200, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: Login"
fi

# 5. Login invalid credentials (401) - DO NOT overwrite cookies.txt!
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" \
     -H "Content-Type: application/json" \
     -d '{"username": "testuser", "password": "wrongpass"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "401" ]; then
    echo "FAIL: Login invalid credentials expected 401, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: Login invalid credentials"
fi

# 6. GET /me (success)
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" \
     -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /me expected 200, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: GET /me"
fi

# 7. GET /me without cookie (401)
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "401" ]; then
    echo "FAIL: GET /me without cookie expected 401, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: GET /me without cookie"
fi

# 8. PUT /password (success)
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
     -H "Content-Type: application/json" \
     -b cookies.txt \
     -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ]; then
    echo "FAIL: PUT /password expected 200, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: PUT /password"
fi

# 9. PUT /password invalid old password (401)
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
     -H "Content-Type: application/json" \
     -b cookies.txt \
     -d '{"old_password": "wrongpass", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "401" ]; then
    echo "FAIL: PUT /password invalid old password expected 401, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: PUT /password invalid old password"
fi

# 10. PUT /password too short new password (400)
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" \
     -H "Content-Type: application/json" \
     -b cookies.txt \
     -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "400" ]; then
    echo "FAIL: PUT /password short new password expected 400, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: PUT /password short new password"
fi

# 11. POST /todos (success)
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
     -H "Content-Type: application/json" \
     -b cookies.txt \
     -d '{"title": "My Todo", "description": "A test todo"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ]; then
    echo "FAIL: POST /todos expected 201, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: POST /todos"
fi

# 12. POST /todos missing title (400)
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" \
     -H "Content-Type: application/json" \
     -b cookies.txt \
     -d '{"description": "A test todo"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "400" ]; then
    echo "FAIL: POST /todos missing title expected 400, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: POST /todos missing title"
fi

# 13. GET /todos (success)
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" \
     -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos expected 200, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: GET /todos"
fi

# 14. GET /todos/1 (success)
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/1" \
     -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ]; then
    echo "FAIL: GET /todos/1 expected 200, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: GET /todos/1"
fi

# 15. GET /todos/999 (404)
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/999" \
     -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "404" ]; then
    echo "FAIL: GET /todos/999 expected 404, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: GET /todos/999"
fi

# 16. PUT /todos/1 (success)
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/1" \
     -H "Content-Type: application/json" \
     -b cookies.txt \
     -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ]; then
    echo "FAIL: PUT /todos/1 expected 200, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: PUT /todos/1"
fi

# 17. PUT /todos/1 invalid title empty string (400)
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/1" \
     -H "Content-Type: application/json" \
     -b cookies.txt \
     -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "400" ]; then
    echo "FAIL: PUT /todos/1 empty title expected 400, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: PUT /todos/1 empty title"
fi

# 18. PUT /todos/999 (404)
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/999" \
     -H "Content-Type: application/json" \
     -b cookies.txt \
     -d '{"title": "Updated"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "404" ]; then
    echo "FAIL: PUT /todos/999 expected 404, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: PUT /todos/999"
fi

# 19. DELETE /todos/1 (success)
RES=$(curl -s -w "%{http_code}" -X DELETE "$BASE_URL/todos/1" \
     -b cookies.txt)
CODE=$(echo "$RES")
if [ "$CODE" != "204" ]; then
    echo "FAIL: DELETE /todos/1 expected 204, got $CODE"
    FAILED=$((FAILED+1))
else
    echo "PASS: DELETE /todos/1"
fi

# 20. DELETE /todos/1 again (404)
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/1" \
     -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "404" ]; then
    echo "FAIL: DELETE /todos/1 again expected 404, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: DELETE /todos/1 again"
fi

# 21. DELETE /todos/999 (404)
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/999" \
     -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "404" ]; then
    echo "FAIL: DELETE /todos/999 expected 404, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: DELETE /todos/999"
fi

# 22. POST /logout (success)
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" \
     -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "200" ]; then
    echo "FAIL: POST /logout expected 200, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: POST /logout"
fi

# 23. POST /logout again without session (401)
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" \
     -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "401" ]; then
    echo "FAIL: POST /logout again expected 401, got $CODE. Body: $BODY"
    FAILED=$((FAILED+1))
else
    echo "PASS: POST /logout again"
fi

echo ""
if [ $FAILED -eq 0 ]; then
    echo "ALL TESTS PASSED!"
    exit 0
else
    echo "$FAILED TESTS FAILED"
    echo "--- Server log ---"
    cat server.log
    exit 1
fi