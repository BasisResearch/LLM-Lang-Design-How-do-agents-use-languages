#!/bin/bash

echo "Running simple API tests..."

# Start the server
timeout 30s ./run.sh --port 8080 &
SERVER_PID=$!
echo "Server started with PID: $SERVER_PID"

# Allow some time for server startup
sleep 3

# Test endpoint availability  
echo "Testing registration:"
curl -s -H "Content-Type: application/json" -X POST -d '{"username":"testuser","password":"testpass123"}' http://localhost:8080/register
echo ""

echo "Testing login:"
LOGIN_RESULT=$(curl -s -c cookies.txt -H "Content-Type: application/json" -X POST -d '{"username":"testuser","password":"testpass123"}' http://localhost:8080/login)
echo $LOGIN_RESULT

# Extract session cookie
SESSION_COOKIE=$(grep -h session_id cookies.txt | tail -n 1 | awk '{print $7}')

if [ -z "$SESSION_COOKIE" ]; then
    # Alternative: extract from curl -v headers
    SESSION_COOKIE=$(curl -s -D - -c cookies.txt -H "Content-Type: application/json" -X POST -d '{"username":"testuser","password":"testpass123"}' http://localhost:8080/login 2>&1 | grep -i "set-cookie:" | grep -o "session_id=[^;]*" | sed 's/session_id=//')
fi

echo "Session cookie obtained: $SESSION_COOKIE"

# Test authentication-requiring endpoints
echo "Testing /me endpoint with auth:"
curl -s -b "session_id=$SESSION_COOKIE" http://localhost:8080/me
echo ""

echo "Creating a todo:"
TODO_RESULT=$(curl -s -b "session_id=$SESSION_COOKIE" -H "Content-Type: application/json" -X POST -d '{"title":"Test Todo","description":"A test todo"}' http://localhost:8080/todos)
echo $TODO_RESULT

TODO_ID=$(echo $TODO_RESULT | grep -o '"id":[0-9]*' | cut -d ':' -f 2)
echo "Created todo with ID: $TODO_ID"

# List todos
echo "Getting all todos:"
curl -s -b "session_id=$SESSION_COOKIE" http://localhost:8080/todos
echo ""

if [ -n "$TODO_ID" ]; then
    echo "Getting specific todo ($TODO_ID):"
    curl -s -b "session_id=$SESSION_COOKIE" http://localhost:8080/todos/$TODO_ID
    echo ""
    
    # Update the todo 
    echo "Updating todo ($TODO_ID):"
    curl -s -b "session_id=$SESSION_COOKIE" -H "Content-Type: application/json" -X PUT -d '{"completed":true}' http://localhost:8080/todos/$TODO_ID
    echo ""
fi

echo "Testing password update:"
curl -s -b "session_id=$SESSION_COOKIE" -H "Content-Type: application/json" -X PUT -d '{"old_password":"testpass123","new_password":"newpassword456"}' http://localhost:8080/password
echo ""

echo "Logging out:"
curl -s -b "session_id=$SESSION_COOKIE" -H "Content-Type: application/json" -X POST http://localhost:8080/logout
echo ""

# Clean up
rm -f cookies.txt
kill -TERM $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo "Tests Complete!"