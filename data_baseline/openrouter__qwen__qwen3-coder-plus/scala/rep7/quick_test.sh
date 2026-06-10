#!/bin/bash

# Quick verification test
scala-cli run TodoApp.scala -- --port 8080 &
SERVER_PID=$!
sleep 3

echo "Starting quick test..."

# Step 1: Register a user first
echo "Register user:"
response=$(curl -s -X POST http://localhost:8080/register -H "Content-Type: application/json" -d '{"username": "quick_user", "password": "secure123"}')
echo $response

# Step 2: Login 
echo "Login:"
curl -s -c cookies.txt -X POST http://localhost:8080/login -H "Content-Type: application/json" -d '{"username": "quick_user", "password": "secure123"}'
echo " -> Logged in"

# Step 3: Create a todo
echo "Creating todo:"
response=$(curl -s -b cookies.txt -X POST http://localhost:8080/todos -H "Content-Type: application/json" -d '{"title": "Quick Task", "description": "Test task"}')
echo "Created: $response"
TODO_ID=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

echo "Todo ID: $TODO_ID"

# Step 4: Get all todos 
echo "All todos:"
curl -s -b cookies.txt http://localhost:8080/todos

# Step 5: Try delete it
echo "Deleting todo $TODO_ID :"
status=$(curl -s -w "%{http_code}" -o /dev/null -b cookies.txt -X DELETE http://localhost:8080/todos/$TODO_ID)
echo "Status: $status"

# Step 6: Verify it's gone
echo "Verify deletion (should be 404):"
status=$(curl -s -w "%{http_code}" -o /dev/null -b cookies.txt http://localhost:8080/todos/$TODO_ID)
echo "Check status after deletion: $status"

# Clean up
kill $SERVER_PID 2>/dev/null
rm -f cookies.txt 2>/dev/null
echo "Done."