#!/bin/bash

echo "Testing server functionality..."

# First test: Start server in background, wait and test it
scala-cli run TodoServer.scala -- --port 8080 &
SERVER_PID=$!
sleep 5  # Give more time for server to start

# Test registering a user
echo "Trying to register a user..."
response=$(curl -s -X POST -w "\n%{http_code}" http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')

status_code=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n1)

if [ "$status_code" -eq 201 ]; then
    echo "✓ Registration worked!"
    echo "  Response: $body"
else
    echo "✗ Registration failed!"
    echo "  Response: $body"
    echo "  Status: $status_code"
fi

# Kill the server
kill $SERVER_PID 2>/dev/null

echo "Test completed."