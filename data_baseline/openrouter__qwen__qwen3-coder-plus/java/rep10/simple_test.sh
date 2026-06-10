#!/bin/bash

echo "Starting server on port 8081..."
timeout 30s java Server --port 8081 &
SERVER_PID=$!
sleep 2  # Give the server a moment to start

echo "Running focused test..."

# Register first
RESP=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  http://localhost:8081/register)
echo "Registration response: $RESP"

# Login to get session cookie
curl -s -c cookies.txt -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  http://localhost:8081/login
  
# Create a todo and parse its ID robustly 
CREATE_RESP=$(curl -s -b cookies.txt -X POST -H "Content-Type: application/json" \
  -d '{"title": "Simple test todo", "description": "Test desc"}' \
  http://localhost:8081/todos)
echo "Create todo response: $CREATE_RESP"

# Extract todo ID - more robust extraction from JSON
TODO_ID=$(echo "$CREATE_RESP" | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*')
echo "Extracted TODO_ID: $TODO_ID"

# Test getting a single todo by ID
GET_TODO_RESP=$(curl -s -b cookies.txt -X GET http://localhost:8081/todos/$TODO_ID)
GET_TODO_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X GET http://localhost:8081/todos/$TODO_ID)
echo "Get todo by ID ($TODO_ID) - Status: $GET_TODO_STATUS, Response: $GET_TODO_RESP"

# Try to cause an error to make sure 404 "Todo not found" responses work differently from 404 "Not found"
NONEXISTENT_GET_RESP=$(curl -s -X GET http://localhost:8081/does_not_exist)
NONEXISTENT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X GET http://localhost:8081/does_not_exist)
echo "Nonexistent path - Status: $NONEXISTENT_STATUS, Response: $NONEXISTENT_GET_RESP"

kill $SERVER_PID 2>/dev/null || true
rm -f cookies.txt