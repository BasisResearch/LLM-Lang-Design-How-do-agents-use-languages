#!/bin/bash
set -e

PORT=$(( 8000 + RANDOM % 2000 ))
BASE_URL="http://localhost:$PORT"

# Start server in background
node server.js --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 2

# Function to cleanup
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
  rm -f cookies.txt cookies2.txt cookies3.txt
}
trap cleanup EXIT

# Test 1: Invalid username (too short)
echo "Testing Invalid username (too short)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then echo "Invalid username failed: $RES"; exit 1; fi
echo "Invalid username success"

# Test 2: Invalid username (bad chars)
echo "Testing Invalid username (bad chars)..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "bad-user!", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then echo "Invalid username (bad chars) failed: $RES"; exit 1; fi
echo "Invalid username (bad chars) success"

# Test 3: Register
echo "Testing Register..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "201" ]; then echo "Register failed: $RES"; exit 1; fi
echo "Register success"

# Test 4: Register duplicate
echo "Testing Register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "409" ]; then echo "Register duplicate failed: $RES"; exit 1; fi
echo "Register duplicate success"

# Test 5: Password too short
echo "Testing Password too short..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "user5", "password": "short"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then echo "Password too short failed: $RES"; exit 1; fi
echo "Password too short success"

# Test 6: Login
echo "Testing Login..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Login failed: $RES"; exit 1; fi
echo "Login success"

# Test 7: Login invalid credentials
echo "Testing Login invalid credentials..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpass"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "401" ]; then echo "Login invalid credentials failed: $RES"; exit 1; fi
echo "Login invalid credentials success"

# Test 8: Get me
echo "Testing Get me..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Get me failed: $RES"; exit 1; fi
echo "Get me success"

# Test 9: Change password
echo "Testing Change password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword456"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Change password failed: $RES"; exit 1; fi
echo "Change password success"

# Test 10: Change password wrong old password
echo "Testing Change password wrong old password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "wrongold", "new_password": "newpassword456"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "401" ]; then echo "Change password wrong old password failed: $RES"; exit 1; fi
echo "Change password wrong old password success"

# Test 11: Create todo
echo "Testing Create todo..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "My Todo", "description": "A description"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "201" ]; then echo "Create todo failed: $RES"; exit 1; fi
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "Create todo success, ID: $TODO_ID"

# Test 12: Create todo without title
echo "Testing Create todo without title..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description": "no title"}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then echo "Create todo without title failed: $RES"; exit 1; fi
echo "Create todo without title success"

# Test 13: Create todo with empty title
echo "Testing Create todo with empty title..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "   "}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then echo "Create todo with empty title failed: $RES"; exit 1; fi
echo "Create todo with empty title success"

# Test 14: Get todos
echo "Testing Get todos..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Get todos failed: $RES"; exit 1; fi
echo "Get todos success"

# Test 15: Get specific todo
echo "Testing Get specific todo..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Get specific todo failed: $RES"; exit 1; fi
echo "Get specific todo success"

# Test 16: Get specific todo (other user's)
echo "Testing Get specific todo (other user)..."
curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' > /dev/null
curl -s -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' -c cookies2.txt > /dev/null
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies2.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "404" ]; then echo "Get specific todo (other user) failed: $RES"; exit 1; fi
echo "Get specific todo (other user) success"

# Test 17: Update todo
echo "Testing Update todo..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Update todo failed: $RES"; exit 1; fi
echo "Update todo success"

# Test 18: Update todo with empty title
echo "Testing Update todo with empty title..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
CODE=${RES##*$'\n'}
if [ "$CODE" != "400" ]; then echo "Update todo with empty title failed: $RES"; exit 1; fi
echo "Update todo with empty title success"

# Test 19: Verify updated_at changes
echo "Testing updated_at changes..."
RES3=$(curl -s -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "Update test 2"}')
TODO_ID2=$(echo "$RES3" | grep -o '"id":[0-9]*' | cut -d: -f2)
GET1=$(curl -s -X GET "$BASE_URL/todos/$TODO_ID2" -b cookies.txt)
UPDATED_AT1=$(echo "$GET1" | grep -o '"updated_at":"[^"]*"' | cut -d'"' -f4)
sleep 1
curl -s -X PUT "$BASE_URL/todos/$TODO_ID2" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}' > /dev/null
GET2=$(curl -s -X GET "$BASE_URL/todos/$TODO_ID2" -b cookies.txt)
UPDATED_AT2=$(echo "$GET2" | grep -o '"updated_at":"[^"]*"' | cut -d'"' -f4)
if [ "$UPDATED_AT1" == "$UPDATED_AT2" ]; then echo "updated_at did not change!"; exit 1; fi
echo "updated_at changes success"

# Test 20: Delete todo
echo "Testing Delete todo..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "204" ]; then echo "Delete todo failed: $RES"; exit 1; fi
echo "Delete todo success"

# Test 21: Delete non-existent todo
echo "Testing Delete non-existent todo..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/9999" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "404" ]; then echo "Delete non-existent todo failed: $RES"; exit 1; fi
echo "Delete non-existent todo success"

# Test 22: Delete other user's todo
echo "Testing Delete other user's todo..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID2" -b cookies2.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "404" ]; then echo "Delete other user's todo failed: $RES"; exit 1; fi
echo "Delete other user's todo success"

# Test 23: Logout
echo "Testing Logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "200" ]; then echo "Logout failed: $RES"; exit 1; fi
echo "Logout success"

# Test 24: Access protected route after logout
echo "Testing Access after logout..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=${RES##*$'\n'}
if [ "$CODE" != "401" ]; then echo "Access after logout failed: $RES"; exit 1; fi
echo "Access after logout success"

# Test 25: Access protected route without auth
echo "Testing Access without auth..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
CODE=${RES##*$'\n'}
if [ "$CODE" != "401" ]; then echo "Access without auth failed: $RES"; exit 1; fi
echo "Access without auth success"

echo "All tests passed!"