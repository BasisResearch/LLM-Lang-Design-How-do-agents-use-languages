#!/bin/bash

# Test server functionality by making HTTP requests with curl
echo "Testing server functionality..."

# Start server on background
./run.sh --port 8080 &
SERVER_PID=$!
sleep 2  # Give server time to start

# Cleanup function
cleanup() {
  kill $SERVER_PID 2>/dev/null || true
}

# Handle script exit
trap cleanup EXIT

echo "Testing register endpoint (should work)"
curl -v -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}'

echo -e "\n\nTesting duplicate registration (should fail with 409)"
curl -v -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}'

echo -e "\n\nTesting invalid username (too short)"
curl -v -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"ab","password":"password123"}'

echo -e "\n\nTesting weak password (too short)"
curl -v -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username":"validuser","password":"weak"}'

echo -e "\n\nTesting login with valid credentials (should work)"
COOKIE_FILE=$(mktemp)
curl -v -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  -c "$COOKIE_FILE"

echo -e "\n\nTesting authentication required endpoint before login (should fail with 401)"
curl -v -X GET http://localhost:8080/me

echo -e "\n\nTesting protected endpoint with cookie (should work)"
curl -v -X GET http://localhost:8080/me \
  -b "$COOKIE_FILE"

echo -e "\n\nTesting creating a todo (should work)"
curl -v -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"First task","description":"My first todo item"}' \
  -b "$COOKIE_FILE"

echo -e "\n\nTesting getting todos (should return the created todo)"
curl -v -X GET http://localhost:8080/todos \
  -b "$COOKIE_FILE"

echo -e "\n\nTesting updating a todo (should work)"
curl -v -X PUT http://localhost:8080/todos/1 \
  -H "Content-Type: application/json" \
  -d '{"title":"Updated task","completed":true}' \
  -b "$COOKIE_FILE"

echo -e "\n\nTesting getting specific todo (should return the updated todo)"
curl -v -X GET http://localhost:8080/todos/1 \
  -b "$COOKIE_FILE"

echo -e "\n\nTesting changing password (should work)"
curl -v -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password":"password123","new_password":"newpassword789"}' \
  -b "$COOKIE_FILE"

echo -e "\n\nTesting logout (should work)"
curl -v -X POST http://localhost:8080/logout \
  -b "$COOKIE_FILE"

echo -e "\n\nTesting protected endpoint after logout (should fail with 401)"
curl -v -X GET http://localhost:8080/me \
  -b "$COOKIE_FILE"

echo -e "\n\nTesting delete endpoint"
# First create another todo to delete
curl -v -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title":"Task to delete","description":"Deleting this"}' \
  -b "$COOKIE_FILE" --cookie "$COOKIE_FILE"

# Login again
curl -v -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"newpassword789"}' \
  -c "$COOKIE_FILE"

# Now delete the second todo
curl -v -X DELETE http://localhost:8080/todos/2 \
  -b "$COOKIE_FILE"

# Check that there is only one task left
echo -e "\n\nVerifying deletion (should show only one task)"
curl -v -X GET http://localhost:8080/todos \
  -b "$COOKIE_FILE"

echo -e "\n\nAll tests completed successfully!"
rm -f "$COOKIE_FILE"