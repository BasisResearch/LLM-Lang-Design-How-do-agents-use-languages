#!/bin/bash

# Test script to verify the Todo API server
set -e  # Exit on error

PORT=8080
BASE_URL="http://localhost:$PORT"

echo "Starting server in background..."
./server_final --port $PORT &
SERVER_PID=$!
sleep 1  # Let server start

echo "Testing API endpoints..."

# Test main endpoints
echo "Testing home route..."
response=$(curl -s -w "%{http_code}" "$BASE_URL/")
status_code="${response: -3}"
response_body="${response%???}"
echo "Status: $status_code, Response: $response_body"

echo "Testing /todos endpoint..."
response=$(curl -s -w "%{http_code}" "$BASE_URL/todos") 
status_code="${response: -3}"
response_body="${response%???}"
echo "Status: $status_code, Response: $response_body"

echo "Testing /register endpoint..."
response=$(curl -s -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username": "test", "password": "password123"}' "$BASE_URL/register")
status_code="${response: -3}" 
response_body="${response%???}"
echo "Status: $status_code, Response: $response_body"

echo "Testing /login endpoint..."
response=$(curl -s -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username": "test", "password": "password123"}' "$BASE_URL/login")
status_code="${response: -3}"
response_body="${response%???}"
echo "Status: $status_code, Response: $response_body"

# Clean up
kill $SERVER_PID 2>/dev/null || true
echo "Tests completed!"