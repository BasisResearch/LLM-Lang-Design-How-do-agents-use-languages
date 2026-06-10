#!/bin/bash
set -e
PORT=8888
./run.sh --port $PORT &
PID=$!
sleep 1

BASE="http://localhost:$PORT"

# Register
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/register -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ]; then echo "Register failed: $CODE $BODY"; kill $PID; exit 1; fi
echo "Register OK"

# Register duplicate
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/register -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then echo "Duplicate register failed: $CODE"; kill $PID; exit 1; fi
echo "Duplicate register OK"

# Register short password
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE/register -d '{"username":"testuser2","password":"short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then echo "Short password failed: $CODE"; kill $PID; exit 1; fi
echo "Short password OK"

# Login
RES=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST $BASE/login -d '{"username":"testuser","password":"password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Login failed: $CODE"; kill $PID; exit 1; fi
echo "Login OK"

# Me
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET $BASE/me)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Me failed: $CODE"; kill $PID; exit 1; fi
echo "Me OK"

# Create Todo
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST $BASE/todos -d '{"title":"My Todo","description":"Do this"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then echo "Create todo failed: $CODE"; kill $PID; exit 1; fi
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "Create Todo OK, ID: $TODO_ID"

# Get Todos
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET $BASE/todos)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Get todos failed: $CODE"; kill $PID; exit 1; fi
echo "Get Todos OK"

# Get Todo
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET $BASE/todos/$TODO_ID)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Get todo failed: $CODE"; kill $PID; exit 1; fi
echo "Get Todo OK"

# Update Todo
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT $BASE/todos/$TODO_ID -d '{"completed":true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Update todo failed: $CODE"; kill $PID; exit 1; fi
echo "Update Todo OK"

# Delete Todo
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE $BASE/todos/$TODO_ID)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then echo "Delete todo failed: $CODE"; kill $PID; exit 1; fi
echo "Delete Todo OK"

# Change Password
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT $BASE/password -d '{"old_password":"password123","new_password":"newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Change password failed: $CODE"; kill $PID; exit 1; fi
echo "Change Password OK"

# Logout
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST $BASE/logout)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then echo "Logout failed: $CODE"; kill $PID; exit 1; fi
echo "Logout OK"

# Me after logout (should fail)
RES=$(curl -s -w "\n%{http_code}" -b cookies.txt -X GET $BASE/me)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then echo "Me after logout failed: $CODE"; kill $PID; exit 1; fi
echo "Me after logout OK"

kill $PID
rm -f cookies.txt
echo "ALL TESTS PASSED"