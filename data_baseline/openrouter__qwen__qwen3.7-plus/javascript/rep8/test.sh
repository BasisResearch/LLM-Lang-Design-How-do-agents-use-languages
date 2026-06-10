#!/bin/bash

PORT=3456
node server.js --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 1

BASE_URL="http://127.0.0.1:$PORT"
FAILURES=0

echo "Testing POST /register..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "201" ] && echo "$BODY" | grep -q "testuser"; then
  echo "PASS: POST /register"
else
  echo "FAIL: POST /register - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing POST /register invalid username..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "400" ] && echo "$BODY" | grep -q "Invalid username"; then
  echo "PASS: POST /register invalid username"
else
  echo "FAIL: POST /register invalid username - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing POST /register short password..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "400" ] && echo "$BODY" | grep -q "Password too short"; then
  echo "PASS: POST /register short password"
else
  echo "FAIL: POST /register short password - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing POST /register duplicate username..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "409" ] && echo "$BODY" | grep -q "Username already exists"; then
  echo "PASS: POST /register duplicate username"
else
  echo "FAIL: POST /register duplicate username - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing POST /login..."
curl -s -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' > /dev/null
if [ -f cookies.txt ] && grep -q "session_id" cookies.txt; then
  echo "PASS: POST /login"
else
  echo "FAIL: POST /login"
  FAILURES=$((FAILURES+1))
fi

echo "Testing POST /login invalid credentials..."
RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrong"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "401" ] && echo "$BODY" | grep -q "Invalid credentials"; then
  echo "PASS: POST /login invalid credentials"
else
  echo "FAIL: POST /login invalid credentials - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

COOKIES="--cookie cookies.txt"

echo "Testing GET /me..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X GET "$BASE_URL/me")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "200" ] && echo "$BODY" | grep -q "testuser"; then
  echo "PASS: GET /me"
else
  echo "FAIL: GET /me - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing GET /me without auth..."
RESP=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "401" ] && echo "$BODY" | grep -q "Authentication required"; then
  echo "PASS: GET /me without auth"
else
  echo "FAIL: GET /me without auth - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing PUT /password..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "200" ]; then
  echo "PASS: PUT /password"
else
  echo "FAIL: PUT /password - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing GET /todos..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X GET "$BASE_URL/todos")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "200" ] && [ "$BODY" = "[]" ]; then
  echo "PASS: GET /todos"
else
  echo "FAIL: GET /todos - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing POST /todos..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title": "Test Todo", "description": "Test description"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "201" ] && echo "$BODY" | grep -q "Test Todo"; then
  echo "PASS: POST /todos"
else
  echo "FAIL: POST /todos - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing POST /todos missing title..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"description": "No title"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "400" ] && echo "$BODY" | grep -q "Title is required"; then
  echo "PASS: POST /todos missing title"
else
  echo "FAIL: POST /todos missing title - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing GET /todos/1..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X GET "$BASE_URL/todos/1")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "200" ] && echo "$BODY" | grep -q "Test Todo"; then
  echo "PASS: GET /todos/1"
else
  echo "FAIL: GET /todos/1 - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing GET /todos/999 (not found)..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X GET "$BASE_URL/todos/999")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "404" ] && echo "$BODY" | grep -q "Todo not found"; then
  echo "PASS: GET /todos/999"
else
  echo "FAIL: GET /todos/999 - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing PUT /todos/1..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"completed": true, "title": "Updated Title"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "200" ] && echo "$BODY" | grep -q "Updated Title" && echo "$BODY" | grep -q "true"; then
  echo "PASS: PUT /todos/1"
else
  echo "FAIL: PUT /todos/1 - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing PUT /todos/1 empty title..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"title": ""}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "400" ] && echo "$BODY" | grep -q "Title is required"; then
  echo "PASS: PUT /todos/1 empty title"
else
  echo "FAIL: PUT /todos/1 empty title - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

# Create another user to test 404 for other users' todos
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "otheruser", "password": "password123"}' > /dev/null
curl -s -c cookies2.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "otheruser", "password": "password123"}' > /dev/null

echo "Testing GET /todos/1 for other user..."
RESP=$(curl -s -w "\n%{http_code}" --cookie cookies2.txt -X GET "$BASE_URL/todos/1")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "404" ] && echo "$BODY" | grep -q "Todo not found"; then
  echo "PASS: GET /todos/1 for other user"
else
  echo "FAIL: GET /todos/1 for other user - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing PUT /todos/1 for other user..."
RESP=$(curl -s -w "\n%{http_code}" --cookie cookies2.txt -X PUT "$BASE_URL/todos/1" -H "Content-Type: application/json" -d '{"title": "Hacked"}')
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "404" ] && echo "$BODY" | grep -q "Todo not found"; then
  echo "PASS: PUT /todos/1 for other user"
else
  echo "FAIL: PUT /todos/1 for other user - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing DELETE /todos/1..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X DELETE "$BASE_URL/todos/1")
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "204" ]; then
  echo "PASS: DELETE /todos/1"
else
  echo "FAIL: DELETE /todos/1 - Status: $STATUS"
  FAILURES=$((FAILURES+1))
fi

echo "Testing POST /logout..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X POST "$BASE_URL/logout")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "200" ] && [ "$BODY" = "{}" ]; then
  echo "PASS: POST /logout"
else
  echo "FAIL: POST /logout - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

echo "Testing GET /me after logout..."
RESP=$(curl -s -w "\n%{http_code}" $COOKIES -X GET "$BASE_URL/me")
BODY=$(echo "$RESP" | head -n -1)
STATUS=$(echo "$RESP" | tail -n 1)
if [ "$STATUS" = "401" ] && echo "$BODY" | grep -q "Authentication required"; then
  echo "PASS: GET /me after logout"
else
  echo "FAIL: GET /me after logout - Status: $STATUS, Body: $BODY"
  FAILURES=$((FAILURES+1))
fi

# Cleanup
rm -f cookies.txt cookies2.txt
kill $SERVER_PID 2>/dev/null || true

echo ""
if [ $FAILURES -eq 0 ]; then
  echo "ALL TESTS PASSED!"
  exit 0
else
  echo "TESTS FAILED: $FAILURES"
  exit 1
fi
