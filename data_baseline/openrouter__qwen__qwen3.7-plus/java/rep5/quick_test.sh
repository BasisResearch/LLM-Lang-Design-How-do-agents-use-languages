#!/bin/bash
set -e

PORT=8085

# Start server in background, redirect output
nohup java TodoServer --port $PORT > server.log 2>&1 &
SERVER_PID=$!
echo "Started server with PID $SERVER_PID"

# Wait for server to be ready
for i in {1..10}; do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/register" | grep -q "405\|400"; then
        echo "Server is ready"
        break
    fi
    sleep 1
done

echo "=== Testing Register ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:$PORT/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL: Register expected 201, got $CODE, body: $(echo "$RES" | sed '$d')"; exit 1; fi
echo "PASS: Register"

echo "=== Testing Login ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:$PORT/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Login expected 200, got $CODE"; exit 1; fi
echo "PASS: Login"

echo "=== Testing Me ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "http://localhost:$PORT/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Me expected 200, got $CODE"; exit 1; fi
echo "PASS: Me"

echo "=== Testing Create Todo ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:$PORT/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title":"My Todo","description":"Do this"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL: Create Todo expected 201, got $CODE"; exit 1; fi
TODO_ID=$(echo "$RES" | sed '$d' | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "PASS: Create Todo (ID: $TODO_ID)"

echo "=== Testing Get Todos ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "http://localhost:$PORT/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Get Todos expected 200, got $CODE"; exit 1; fi
echo "PASS: Get Todos"

echo "=== Testing Update Todo ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "http://localhost:$PORT/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed":true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Update Todo expected 200, got $CODE"; exit 1; fi
echo "PASS: Update Todo"

echo "=== Testing Delete Todo ==="
RES=$(curl -s -w "\n%{http_code}" -X DELETE "http://localhost:$PORT/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then echo "FAIL: Delete Todo expected 204, got $CODE"; exit 1; fi
echo "PASS: Delete Todo"

echo "=== Testing Logout ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:$PORT/logout" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL: Logout expected 200, got $CODE"; exit 1; fi
echo "PASS: Logout"

echo "=== All tests passed! ==="

# Cleanup
kill $SERVER_PID 2>/dev/null || true
rm -f cookies.txt server.log