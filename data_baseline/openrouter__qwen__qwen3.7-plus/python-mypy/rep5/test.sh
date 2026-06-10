#!/bin/bash
set -e

PORT=8765
BASE_URL="http://localhost:$PORT"

echo "Starting server on port $PORT..."
python3 main.py --port $PORT &
SERVER_PID=$!

# Wait for server to be ready
for i in {1..10}; do
    if curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/me" | grep -q "401"; then
        break
    fi
    sleep 0.5
done

cleanup() {
    echo "Cleaning up server..."
    kill $SERVER_PID || true
    wait $SERVER_PID || true
    rm -f cookies.txt
}
trap cleanup EXIT

echo "Server started with PID $SERVER_PID"

check() {
    local name=$1
    local expected=$2
    local actual=$3
    if echo "$actual" | grep -qi "$expected"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        echo "Expected to find: $expected"
        echo "Actual: $actual"
        exit 1
    fi
}

echo "1. Testing /register"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
check "/register success" '"id":' "$RES"

echo "2. Testing /register duplicate"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
check "/register duplicate" '409' "$RES"

echo "3. Testing /register invalid username"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
check "/register invalid username" '400' "$RES"

echo "4. Testing /register short password"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
check "/register short password" '400' "$RES"

echo "5. Testing /login"
RES=$(curl -s -c cookies.txt -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
check "/login success" '"id":' "$RES"

echo "6. Testing /login invalid credentials"
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
check "/login invalid credentials" '401' "$RES"

echo "7. Testing /me"
RES=$(curl -s -b cookies.txt "$BASE_URL/me")
check "/me success" '"username":"testuser"' "$RES"

echo "8. Testing /me without auth"
RES=$(curl -s -w "\n%{http_code}" "$BASE_URL/me")
check "/me without auth" '401' "$RES"

echo "9. Testing /password"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
check "/password success" '200' "$RES"

echo "10. Testing /password invalid old password"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "wrong", "new_password": "newpassword123"}')
check "/password invalid old password" '401' "$RES"

echo "11. Testing /password short new password"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}')
check "/password short new password" '400' "$RES"

echo "12. Testing /todos create"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Do this"}')
check "/todos create success" '"title":"My Todo"' "$RES"

echo "13. Testing /todos create missing title"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"description": "Do this"}')
check "/todos create missing title" '400' "$RES"

echo "14. Testing /todos create empty title"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "", "description": "Do this"}')
check "/todos create empty title" '400' "$RES"

echo "15. Testing /todos list"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos")
check "/todos list success" '"title":"My Todo"' "$RES"

echo "16. Testing /todos get"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/1")
check "/todos get success" '"title":"My Todo"' "$RES"

echo "17. Testing /todos get not found"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE_URL/todos/999")
check "/todos get not found" '404' "$RES"

echo "18. Testing /todos update"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"completed": true, "title": "Updated Todo"}')
check "/todos update success" '"completed":true' "$RES"
check "/todos update title changed" '"title":"Updated Todo"' "$RES"

echo "19. Testing /todos update empty title"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"title": ""}')
check "/todos update empty title" '400' "$RES"

echo "20. Testing /todos update not found"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE_URL/todos/999" -H "Content-Type: application/json" -d '{"completed": true}')
check "/todos update not found" '404' "$RES"

echo "21. Testing /todos delete"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X DELETE "$BASE_URL/todos/1")
check "/todos delete success" '204' "$HTTP_CODE"

echo "22. Testing /todos get after delete"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "$BASE_URL/todos/1")
check "/todos get after delete" '404' "$HTTP_CODE"

echo "23. Testing /logout"
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE_URL/logout")
check "/logout success" '200' "$RES"

echo "24. Testing /me after logout"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt "$BASE_URL/me")
check "/me after logout" '401' "$HTTP_CODE"

echo "ALL TESTS PASSED!"
