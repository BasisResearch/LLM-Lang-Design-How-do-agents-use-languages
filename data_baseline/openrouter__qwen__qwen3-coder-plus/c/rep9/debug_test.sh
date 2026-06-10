#!/bin/bash

# Quick test to debug the login mechanism specifically
echo "Testing login and auth workflow manually:"

# Start server in background
echo "Starting server..."
timeout 10s ./server --port 8080 &
SERVER_PID=$!
sleep 1

echo "Creating user..."
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "debuguser", "password": "password123"}'

echo

echo "Trying to login and getting session cookies..."
curl -v -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "debuguser", "password": "password123"}' 2>&1 | grep -i set-cooki

echo

echo "Login without curl - showing raw headers"
RESPONSE=$(curl -s -D - -o response_body.json http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "debuguser", "password": "password123"}')

echo "Response headers:" 
echo "$RESPONSE"
echo "Response body:"
cat response_body.json

# Stop server
kill $SERVER_PID 2>/dev/null || true
rm -f response_body.json