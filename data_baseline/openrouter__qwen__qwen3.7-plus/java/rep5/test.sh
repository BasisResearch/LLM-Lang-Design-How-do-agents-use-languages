#!/bin/bash
set -e

PORT=8080
HOST="http://localhost:$PORT"

# Start server in background
./run.sh --port $PORT &
SERVER_PID=$!
sleep 3

# Helper function for curl
curl_json() {
    curl -s -w "\n%{http_code}" "$@"
}

trap "kill $SERVER_PID 2>/dev/null || true; rm -f cookies.txt" EXIT

echo "=== Testing Register ==="
RES=$(curl_json -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL: Register expected 201, got $CODE"; exit 1; fi
echo "PASS: Register"

echo "=== Testing Register Duplicate ==="
RES=$(curl_json -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then echo "FAIL: Duplicate Register expected 409, got $CODE"; exit 1; fi
echo "PASS: Register Duplicate"

echo "=== Testing Register Invalid Username ==="
RES=$(curl_json -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: Invalid Username expected 400, got $CODE"; exit 1; fi
echo "PASS: Register Invalid Username"

echo "=== Testing Register Short Password ==="
RES=$(curl_json -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username":"testuser2","password":"short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: Short Password expected 400, got $CODE"; exit 1; fi
echo "PASS: Register Short Password"

echo "=== Testing Login ==="
RES=$(curl_json -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Login expected 200, got $CODE"; exit 1; fi
echo "PASS: Login"

echo "=== Testing Login Invalid ==="
RES=$(curl_json -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"wrongpassword"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: Invalid Login expected 401, got $CODE"; exit 1; fi
echo "PASS: Login Invalid"

echo "=== Testing Me ==="
RES=$(curl_json -X GET "$HOST/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Me expected 200, got $CODE"; exit 1; fi
echo "PASS: Me"

echo "=== Testing Me Unauthenticated ==="
RES=$(curl_json -X GET "$HOST/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: Unauthenticated Me expected 401, got $CODE"; exit 1; fi
echo "PASS: Me Unauthenticated"

echo "=== Testing Change Password ==="
RES=$(curl_json -X PUT "$HOST/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"password123","new_password":"newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Change Password expected 200, got $CODE"; exit 1; fi
echo "PASS: Change Password"

echo "=== Testing Change Password Invalid Old ==="
RES=$(curl_json -X PUT "$HOST/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password":"wrongpassword","new_password":"newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: Change Password Invalid Old expected 401, got $CODE"; exit 1; fi
echo "PASS: Change Password Invalid Old"

echo "=== Testing Create Todo ==="
RES=$(curl_json -X POST "$HOST/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title":"My Todo","description":"Do this"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL: Create Todo expected 201, got $CODE"; exit 1; fi
TODO_ID=$(echo "$RES" | sed '$d' | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "PASS: Create Todo (ID: $TODO_ID)"

echo "=== Testing Create Todo Missing Title ==="
RES=$(curl_json -X POST "$HOST/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description":"Do this"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: Create Todo Missing Title expected 400, got $CODE"; exit 1; fi
echo "PASS: Create Todo Missing Title"

echo "=== Testing Get Todos ==="
RES=$(curl_json -X GET "$HOST/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Get Todos expected 200, got $CODE"; exit 1; fi
echo "PASS: Get Todos"

echo "=== Testing Get Todo By ID ==="
RES=$(curl_json -X GET "$HOST/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Get Todo By ID expected 200, got $CODE"; exit 1; fi
echo "PASS: Get Todo By ID"

echo "=== Testing Get Todo By ID Not Found ==="
RES=$(curl_json -X GET "$HOST/todos/9999" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "FAIL: Get Todo By ID Not Found expected 404, got $CODE"; exit 1; fi
echo "PASS: Get Todo By ID Not Found"

echo "=== Testing Update Todo ==="
RES=$(curl_json -X PUT "$HOST/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed":true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Update Todo expected 200, got $CODE"; exit 1; fi
echo "PASS: Update Todo"

echo "=== Testing Update Todo Empty Title ==="
RES=$(curl_json -X PUT "$HOST/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title":""}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL: Update Todo Empty Title expected 400, got $CODE"; exit 1; fi
echo "PASS: Update Todo Empty Title"

echo "=== Testing Delete Todo ==="
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$HOST/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then echo "FAIL: Delete Todo expected 204, got $CODE"; exit 1; fi
echo "PASS: Delete Todo"

echo "=== Testing Delete Todo Not Found ==="
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$HOST/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "FAIL: Delete Todo Not Found expected 404, got $CODE"; exit 1; fi
echo "PASS: Delete Todo Not Found"

echo "=== Testing Logout ==="
RES=$(curl_json -X POST "$HOST/logout" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Logout expected 200, got $CODE"; exit 1; fi
echo "PASS: Logout"

echo "=== Testing Me After Logout ==="
RES=$(curl_json -X GET "$HOST/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL: Me After Logout expected 401, got $CODE"; exit 1; fi
echo "PASS: Me After Logout"

echo "=== All tests passed! ==="