#!/bin/bash
set -e

PORT=8888

# Start server in background
./run.sh --port "$PORT" &
SERVER_PID=$!
sleep 2

BASE="http://localhost:$PORT"
COOKIES="cookies_test.txt"
> "$COOKIES"

echo "Testing /register..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL /register: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /register"

echo "Testing /register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then echo "FAIL /register dup: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /register dup"

echo "Testing /register invalid username..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"ab","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL /register invalid username: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /register invalid username"

echo "Testing /register short password..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser2","password":"short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL /register short password: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /register short password"

echo "Testing /login..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' -c "$COOKIES")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL /login: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /login"

echo "Testing /login invalid credentials..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"wrongpassword"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL /login invalid: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /login invalid"

echo "Testing /me..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -b "$COOKIES")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL /me: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /me"

echo "Testing /me without auth..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL /me no auth: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /me no auth"

echo "Testing /password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" -b "$COOKIES" -H "Content-Type: application/json" -d '{"old_password":"password123","new_password":"newpassword1"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL /password: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /password"

echo "Testing /password wrong old password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" -b "$COOKIES" -H "Content-Type: application/json" -d '{"old_password":"wrong","new_password":"newpassword1"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL /password wrong old: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /password wrong old"

echo "Testing /password short new password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/password" -b "$COOKIES" -H "Content-Type: application/json" -d '{"old_password":"newpassword1","new_password":"short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL /password short new: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /password short new"

echo "Testing /todos (empty)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos" -b "$COOKIES")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL /todos empty: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /todos empty"

echo "Testing POST /todos..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -b "$COOKIES" -H "Content-Type: application/json" -d '{"title":"My Todo","description":"Do this"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "FAIL POST /todos: $CODE"; kill $SERVER_PID; exit 1; fi
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "PASS POST /todos (ID: $TODO_ID)"

echo "Testing POST /todos without title..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -b "$COOKIES" -H "Content-Type: application/json" -d '{"description":"No title"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL POST /todos no title: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS POST /todos no title"

echo "Testing GET /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/$TODO_ID" -b "$COOKIES")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL GET /todos/:id: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS GET /todos/:id"

echo "Testing GET /todos/:id not found..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/9999" -b "$COOKIES")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "FAIL GET /todos/:id not found: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS GET /todos/:id not found"

echo "Testing PUT /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/$TODO_ID" -b "$COOKIES" -H "Content-Type: application/json" -d '{"completed":true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL PUT /todos/:id: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS PUT /todos/:id"

echo "Testing PUT /todos/:id empty title..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/$TODO_ID" -b "$COOKIES" -H "Content-Type: application/json" -d '{"title":""}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "FAIL PUT /todos/:id empty title: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS PUT /todos/:id empty title"

echo "Testing GET /todos (check completed)..."
RES=$(curl -s -X GET "$BASE/todos" -b "$COOKIES")
if [[ "$RES" != *"\"completed\":true"* ]]; then echo "FAIL GET /todos check completed"; kill $SERVER_PID; exit 1; fi
echo "PASS GET /todos check completed"

echo "Testing DELETE /todos/:id..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/todos/$TODO_ID" -b "$COOKIES")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then echo "FAIL DELETE /todos/:id: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS DELETE /todos/:id"

echo "Testing GET /todos/:id (after delete)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/$TODO_ID" -b "$COOKIES")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "FAIL GET /todos/:id after delete: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS GET /todos/:id after delete"

echo "Testing /logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/logout" -b "$COOKIES")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "FAIL /logout: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /logout"

echo "Testing /me (after logout)..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -b "$COOKIES")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "FAIL /me after logout: $CODE"; kill $SERVER_PID; exit 1; fi
echo "PASS /me after logout"

# Cleanup
kill $SERVER_PID 2>/dev/null || true
rm -f "$COOKIES" server.o server

echo ""
echo "========================================="
echo "ALL TESTS PASSED SUCCESSFULLY!"
echo "========================================="