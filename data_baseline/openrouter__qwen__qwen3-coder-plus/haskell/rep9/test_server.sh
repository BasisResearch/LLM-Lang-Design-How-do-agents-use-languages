#!/bin/bash

set -e
echo "Building the server..."
cabal build

echo "Starting server on port 8080..."
cabal run todo-app -- --port 8080 &
SERVER_PID=$!

# Give server time to start
sleep 5

echo "Running tests..."

# Test Register
echo "Testing registration..."
RESP=$(curl -s -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"secret123"}')
echo "Register response: $RESP"
echo $RESP | grep -q "id" && echo "Registration OK" || { echo "Registration FAILED"; kill $SERVER_PID; exit 1; }

# Test Login
echo "Testing login..."
COOKIES=$(mktemp)
curl -s -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"secret123"}' \
  -c $COOKIES
echo "Login completed"

# Test Auth Required - Get me
echo "Testing /me endpoint..."
RESP=$(curl -s -X GET http://localhost:8080/me -b $COOKIES)
echo "Me response: $RESP"
echo $RESP | grep -q "id" && echo "Get Me OK" || { echo "Get Me FAILED"; kill $SERVER_PID; exit 1; }

# Test Todo Creation
echo "Testing todo creation..."
RESP=$(curl -s -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"First task","description":"Complete todo app"}' \
  -b $COOKIES)
echo "Create todo response: $RESP"
echo $RESP | grep -q "id" && echo "Todo creation OK" || { echo "Todo creation FAILED"; kill $SERVER_PID; exit 1; }
TODO_ID=$(echo $RESP | grep -o '"id":[0-9]*' | cut -d':' -f2)

# Test Get Todos
echo "Testing get all todos..."
RESP=$(curl -s -X GET http://localhost:8080/todos -b $COOKIES)
echo "Get todos response: $RESP"

# Test Get Specific Todo
echo "Testing get specific todo..."
RESP=$(curl -s -X GET http://localhost:8080/todos/$TODO_ID -b $COOKIES)
echo "Get specific todo response: $RESP"

# Test Update Todo
echo "Testing update todo..."
RESP=$(curl -s -X PUT http://localhost:8080/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated task","completed":true}' \
  -b $COOKIES)
echo "Update todo response: $RESP"

# Clean up and finish
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true
rm $COOKIES
echo "All tests completed!"
