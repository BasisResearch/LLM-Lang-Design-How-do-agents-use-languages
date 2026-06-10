#!/bin/bash

echo "Starting server on port 8080..."
./run.sh --port 8080 &
SERVER_PID=$!

sleep 3

echo "Testing endpoints..."

echo "1. Registering new user..."
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' 
echo ""

sleep 1

echo "2. Login..."
RESPONSE=$(curl -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' -c cookies.txt -D headers.txt -s)
echo "Login Response: $RESPONSE"

# Extract session cookie
SESSION_ID=$(grep session_id cookies.txt | awk '{print $7}' || echo "")
if [ -n "$SESSION_ID" ]; then
  echo "Got session ID: $SESSION_ID"
else
  echo "No session cookie received!"
fi
echo ""

sleep 1

echo "3. Fetching user profile..."
curl -X GET http://localhost:8080/me \
  -H "Cookie: session_id=$SESSION_ID"
echo ""
echo ""

sleep 1

echo "4. Creating todo..."
TODO_RESPONSE=$(curl -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$SESSION_ID" \
  -d '{"title":"My First Todo","description":"This is my first todo item"}' -s)
echo "Created Todo: $TODO_RESPONSE"
TODO_ID=$(echo "$TODO_RESPONSE" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "Created Todo ID: $TODO_ID"
echo ""

sleep 1

echo "5. Listing todos..."
curl -X GET http://localhost:8080/todos \
  -H "Cookie: session_id=$SESSION_ID"
echo ""
echo ""

sleep 1

echo "6. Getting single todo..."
curl -X GET http://localhost:8080/todos/$TODO_ID \
  -H "Cookie: session_id=$SESSION_ID"
echo ""
echo ""

sleep 1

echo "7. Updating todo..."
curl -X PUT http://localhost:8080/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -H "Cookie: session_id=$SESSION_ID" \
  -d '{"title":"Updated Todo","completed":true}'
echo ""
echo ""

sleep 1

echo "8. Verifying update..."
curl -X GET http://localhost:8080/todos/$TODO_ID \
  -H "Cookie: session_id=$SESSION_ID"
echo ""
echo ""

sleep 1

echo "9. Testing authentication (should fail without session)..."
curl -X GET http://localhost:8080/me
echo ""
echo ""

sleep 1

echo "10. Logout..."
curl -X POST http://localhost:8080/logout \
  -H "Cookie: session_id=$SESSION_ID"
echo ""
echo ""

sleep 1

# Cleanup
kill $SERVER_PID 2>/dev/null || true
rm -f cookies.txt headers.txt

echo "Tests completed!"