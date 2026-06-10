#!/bin/bash
set -e

PORT=8888
BASE="http://localhost:$PORT"

# Start server in background
./run.sh --port $PORT > server.log 2>&1 &
SERVER_PID=$!

# Wait for server to start
for i in {1..10}; do
    if curl -s "http://localhost:$PORT/me" > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

cleanup() {
    echo "Server log:"
    cat server.log
    kill $SERVER_PID 2>/dev/null || true
    exit 1
}
trap cleanup EXIT

echo "Testing /register..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "Register failed: $RES"; exit 1; fi
echo "Register OK"

echo "Testing /register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then echo "Register duplicate failed: $RES"; exit 1; fi
echo "Register duplicate OK"

echo "Testing /login..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Login failed: $RES"; exit 1; fi
echo "Login OK"

echo "Testing /me..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Me failed: $RES"; exit 1; fi
echo "Me OK"

echo "Testing /password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Password failed: $RES"; exit 1; fi
echo "Password OK"

echo "Testing /todos (empty)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Get todos failed: $RES"; exit 1; fi
echo "Get todos OK"

echo "Testing /todos create..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "My Todo", "description": "Do it"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "Create todo failed: $RES"; exit 1; fi
TODO_ID=$(echo "$RES" | grep -o '"id": *[0-9]*' | grep -o '[0-9]*' | head -n1)
echo "Create todo OK, ID: $TODO_ID"

echo "Testing /todos/:id get..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Get todo failed: $RES"; exit 1; fi
echo "Get todo OK"

echo "Testing /todos/:id update..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Update todo failed: $RES"; exit 1; fi
echo "Update todo OK"

echo "Testing /logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/logout" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Logout failed: $RES"; exit 1; fi
echo "Logout OK"

echo "Testing /me after logout (should be 401)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "Me after logout failed: $RES"; exit 1; fi
echo "Me after logout OK"

echo "Testing /todos/:id delete..."
curl -s -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' -c cookies.txt > /dev/null
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then echo "Delete todo failed: $RES"; exit 1; fi
echo "Delete todo OK"

echo "Testing /todos/:id get after delete (should be 404)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "Get todo after delete failed: $RES"; exit 1; fi
echo "Get todo after delete OK"

echo "All tests passed!"
rm -f cookies.txt server.log
trap - EXIT
kill $SERVER_PID 2>/dev/null || true