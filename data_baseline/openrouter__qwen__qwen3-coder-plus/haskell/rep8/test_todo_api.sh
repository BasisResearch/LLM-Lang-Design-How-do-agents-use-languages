#!/bin/bash

echo "Testing Todo API..."

# Start the server in background with port 3001 (since 3000 might be busy in testing environments)
./run.sh --port 3001 &
SERVER_PID=$!
sleep 2  # Allow time for server to start

# Test variables
HOST="localhost:3001" 
COOKIE_JAR="/tmp/cookies.txt"

# Cleanup function
cleanup() {
  kill $SERVER_PID 2>/dev/null
  rm -f $COOKIE_JAR
}
trap cleanup EXIT

echo "Step 1: Testing register endpoint"
curl -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser1", "password": "password123"}' \
  http://$HOST/register

echo -e "\n\nStep 2: Register same username (should fail)"
curl -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser1", "password": "password123"}' \
  http://$HOST/register

echo -e "\n\nStep 3: Login with correct credentials (should return session cookie)"
curl -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser1", "password": "password123"}' \
  -c $COOKIE_JAR \
  http://$HOST/login

echo -e "\n\nStep 4: Try to access protected endpoint without cookie"
curl -X GET http://$HOST/me

echo -e "\n\nStep 5: Access protected endpoint with cookie"
curl -X GET -b $COOKIE_JAR http://$HOST/me

echo -e "\n\nStep 6: Create a todo item"
curl -X POST -H "Content-Type: application/json" \
  -d '{"title": "First Todo", "description": "Initial todo item"}' \
  -b $COOKIE_JAR \
  http://$HOST/todos

echo -e "\n\nStep 7: Retrieve all todos"
curl -X GET -b $COOKIE_JAR http://$HOST/todos

echo -e "\n\nStep 8: Modify the created todo"
TODO_ID=$(curl -X GET -b $COOKIE_JAR http://$HOST/todos \
  2>/dev/null | grep -o '"id":[0-9]*' | head -n1 | cut -d: -f2)

curl -X PUT -H "Content-Type: application/json" \
  -d '{"title": "Updated Todo", "completed": true}' \
  -b $COOKIE_JAR \
  http://$HOST/todos/$TODO_ID

echo -e "\n\nStep 9: Retrieve single todo by ID"
curl -X GET -b $COOKIE_JAR http://$HOST/todos/$TODO_ID

echo -e "\n\nStep 10: Delete the todo"
curl -X DELETE -b $COOKIE_JAR http://$HOST/todos/$TODO_ID

echo -e "\n\nTest completed."
echo "Note: The curl results may require manual verification."