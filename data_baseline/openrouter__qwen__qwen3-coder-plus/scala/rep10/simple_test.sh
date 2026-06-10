#!/bin/bash

# Function to check if server responds to registration endpoint
echo "Testing basic server functionality..."

# Start the server in the background using available port (kill any existing process on 8090 first)
sudo kill -9 $(lsof -t -i:8090) 2>/dev/null || true

./run.sh --port 8090 &
SERVER_PID=$!

# Wait a moment for the server to start
sleep 3

# Test register endpoint
echo "Registering user..."
RESPONSE=$(curl -s -X POST http://localhost:8090/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8090/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')

echo "Status: $HTTP_CODE"
echo "Response: $RESPONSE"

if [[ $HTTP_CODE -eq 201 ]]; then
    echo "✓ Basic functionality test PASSED"
    
    # Test login
    echo "Testing login..."
    LOGIN_RSP=$(curl -s -X POST http://localhost:8090/login \
      -H "Content-Type: application/json" \
      -d '{"username": "testuser", "password": "password123"}')
    LOGIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:8090/login \
      -H "Content-Type: application/json" \
      -d '{"username": "testuser", "password": "password123"}')
    
    echo "Login Status: $LOGIN_CODE" 
    echo "Login Response: $LOGIN_RSP"
    
    if [[ $LOGIN_CODE -eq 200 ]]; then
        echo "✓ Login functionality test PASSED"
        
        # Test todo creation with cookie handling
        echo "Testing Todo Creation..."
        TODO_RSP=$(curl -s -c cookies.txt -X POST http://localhost:8090/todos \
          -H "Content-Type: application/json" \
          -d '{"title": "Test Todo", "description": "Just a test"}')
        TODO_CODE=$(curl -s -o /dev/null -w "%{http_code}" -c cookies.txt -X POST http://localhost:8090/todos \
          -H "Content-Type: application/json" \
          -d '{"title": "Test Todo", "description": "Just a test"}')
        
        echo "Todo Create Status: $TODO_CODE"
        echo "Todo Create Response: $TODO_RSP"
        
        if [[ $TODO_CODE -eq 201 ]]; then
            echo "✓ Todo creation functionality test PASSED"
        else
            echo "✗ Todo creation FAILED"
            RESULT="FAILED"
        fi
    else
        echo "✗ Login functionality test FAILED" 
        RESULT="FAILED"
    fi
else
    echo "✗ Basic functionality test FAILED"
    RESULT="FAILED"
fi

# Cleanup
rm -f cookies.txt 2>/dev/null
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

if [[ "$RESULT" != "FAILED" ]]; then
    echo " "
    echo "🎉 All basic functionality tests PASSED!"
else
    echo " "
    echo "❌ Some tests FAILED"
    exit 1
fi