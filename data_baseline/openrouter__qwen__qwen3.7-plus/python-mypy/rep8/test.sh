#!/bin/bash
set -e

# Ensure server is not running
pkill -f "uvicorn main:app" || true
sleep 1

# Start server in background
python3 -m uvicorn main:app --host 0.0.0.0 --port 8765 &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID || true
    rm -f cookies.txt
}
trap cleanup EXIT

BASE="http://localhost:8765"

# Test register
echo "Testing register..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "Register failed: $CODE"; exit 1; fi

# Test register duplicate
echo "Testing register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then echo "Register duplicate failed: $CODE"; exit 1; fi

# Test register invalid username
echo "Testing register invalid username..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "Register invalid username failed: $CODE"; exit 1; fi

# Test register short password
echo "Testing register short password..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "Register short password failed: $CODE"; exit 1; fi

# Test login
echo "Testing login..."
RES=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Login failed: $CODE"; exit 1; fi

# Test login invalid
echo "Testing login invalid..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrong"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "Login invalid failed: $CODE"; exit 1; fi

# Test me
echo "Testing me..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Me failed: $CODE"; exit 1; fi

# Test password change
echo "Testing password change..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Password change failed: $CODE"; exit 1; fi

# Test password change short
echo "Testing password change short..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE/password" -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "Password change short failed: $CODE"; exit 1; fi

# Test create todo
echo "Testing create todo..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE/todos" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Do this"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "Create todo failed: $CODE"; exit 1; fi
TODO_ID=$(echo "$RES" | head -n -1 | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

# Test create todo empty title
echo "Testing create todo empty title..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE/todos" -H "Content-Type: application/json" -d '{"title": "   "}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "Create todo empty title failed: $CODE"; exit 1; fi

# Test get todos
echo "Testing get todos..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/todos")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Get todos failed: $CODE"; exit 1; fi

# Test get specific todo
echo "Testing get specific todo..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Get specific todo failed: $CODE"; exit 1; fi

# Test get specific todo not found
echo "Testing get specific todo not found..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/todos/9999")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "Get specific todo not found failed: $CODE"; exit 1; fi

# Test update todo
echo "Testing update todo..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT "$BASE/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Update todo failed: $CODE"; exit 1; fi
COMPLETED=$(echo "$RES" | head -n -1 | python3 -c "import sys, json; print(json.load(sys.stdin)['completed'])")
if [ "$COMPLETED" != "True" ]; then echo "Update todo completed check failed: $COMPLETED"; exit 1; fi

# Test delete todo
echo "Testing delete todo..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then echo "Delete todo failed: $CODE"; exit 1; fi

# Test delete todo not found
echo "Testing delete todo not found..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then echo "Delete todo not found failed: $CODE"; exit 1; fi

# Test logout
echo "Testing logout..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE/logout")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Logout failed: $CODE"; exit 1; fi

# Test me after logout
echo "Testing me after logout..."
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "Me after logout failed: $CODE"; exit 1; fi

echo "All tests passed!"
