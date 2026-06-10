#!/bin/bash
set -e

PORT=8888
BASE="http://localhost:$PORT"

echo "Starting server..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 3

cleanup() {
    echo "Stopping server..."
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt
}
trap cleanup EXIT

req() {
    echo "=== $1 ==="
    shift
    curl -s -w "\nHTTP_CODE: %{http_code}\n" "$@"
}

echo "1. Register User 1"
RES=$(req -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
echo "$RES"
echo "$RES" | grep -q '"id":1' && echo "PASS: Register" || echo "FAIL: Register"

echo ""
echo "2. Register Duplicate"
RES=$(req -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
echo "$RES"
echo "$RES" | grep -q '"error":"Username already exists"' && echo "PASS: Duplicate" || echo "FAIL: Duplicate"

echo ""
echo "3. Login"
RES=$(req -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
echo "$RES"
echo "$RES" | grep -q '"id":1' && echo "PASS: Login" || echo "FAIL: Login"

echo ""
echo "4. Me"
RES=$(req -X GET "$BASE/me" -b cookies.txt)
echo "$RES"
echo "$RES" | grep -q '"username":"testuser"' && echo "PASS: Me" || echo "FAIL: Me"

echo ""
echo "5. Create Todo"
RES=$(req -X POST "$BASE/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title":"My Todo","description":"Do this"}')
echo "$RES"
echo "$RES" | grep -q '"title":"My Todo"' && echo "PASS: Create Todo" || echo "FAIL: Create Todo"

echo ""
echo "6. Get Todos"
RES=$(req -X GET "$BASE/todos" -b cookies.txt)
echo "$RES"
echo "$RES" | grep -q '"title":"My Todo"' && echo "PASS: Get Todos" || echo "FAIL: Get Todos"

echo ""
echo "7. Update Todo"
RES=$(req -X PUT "$BASE/todos/1" -b cookies.txt -H "Content-Type: application/json" -d '{"completed":true}')
echo "$RES"
echo "$RES" | grep -q '"completed":true' && echo "PASS: Update Todo" || echo "FAIL: Update Todo"

echo ""
echo "8. Get Specific Todo"
RES=$(req -X GET "$BASE/todos/1" -b cookies.txt)
echo "$RES"
echo "$RES" | grep -q '"completed":true' && echo "PASS: Get Specific Todo" || echo "FAIL: Get Specific Todo"

echo ""
echo "9. Delete Todo"
RES=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/todos/1" -b cookies.txt)
echo "HTTP_CODE: $RES"
echo "$RES" | grep -q "204" && echo "PASS: Delete Todo" || echo "FAIL: Delete Todo"

echo ""
echo "10. Get Deleted Todo (Expect 404)"
RES=$(req -X GET "$BASE/todos/1" -b cookies.txt)
echo "$RES"
echo "$RES" | grep -q '"error":"Todo not found"' && echo "PASS: Get Deleted Todo 404" || echo "FAIL: Get Deleted Todo 404"

echo ""
echo "11. Logout"
RES=$(req -X POST "$BASE/logout" -b cookies.txt)
echo "$RES"
echo "$RES" | grep -q '{}' && echo "PASS: Logout" || echo "FAIL: Logout"

echo ""
echo "12. Me after logout (Expect 401)"
RES=$(req -X GET "$BASE/me" -b cookies.txt)
echo "$RES"
echo "$RES" | grep -q '"error":"Authentication required"' && echo "PASS: Me after logout 401" || echo "FAIL: Me after logout 401"

echo ""
echo "13. Test Invalid Username"
RES=$(req -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
echo "$RES"
echo "$RES" | grep -q '"error":"Invalid username"' && echo "PASS: Invalid Username" || echo "FAIL: Invalid Username"

echo ""
echo "14. Test Short Password"
RES=$(req -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"validuser2","password":"short"}')
echo "$RES"
echo "$RES" | grep -q '"error":"Password too short"' && echo "PASS: Short Password" || echo "FAIL: Short Password"

echo ""
echo "All tests completed!"