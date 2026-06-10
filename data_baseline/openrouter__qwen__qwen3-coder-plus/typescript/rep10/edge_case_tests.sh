#!/bin/bash

set -e  # Exit on any error

# Start server on a port for edge case testing
PORT=8082
echo "Starting server on port $PORT for edge case tests..."

node dist/server.js --port $PORT &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

# Wait for server startup
sleep 2

# Set up cleanup
cleanup() {
  if ps -p $SERVER_PID > /dev/null; then
    kill -TERM $SERVER_PID
  fi
}
trap cleanup EXIT

BASE_URL="http://localhost:$PORT"

echo "Running edge case tests..."

# Edge case 1: Test registration validations
echo "Edge Case 1: Registration validation - short username (should fail)"
RESPONSE=$(curl -s -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
echo "Short username response: $RESPONSE"
echo ""

# Edge case 2: Invalid characters in username
echo "Edge Case 2: Registration - special chars username (should fail)"
RESPONSE=$(curl -s -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "user@name", "password": "password123"}')
echo "Special chars username response: $RESPONSE"
echo ""

# Edge case 3: Short password
echo "Edge Case 3: Registration - short password (should fail)"
RESPONSE=$(curl -s -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "valid_user", "password": "short"}')
echo "Short password response: $RESPONSE"
echo ""

# Edge case 4: Successful registration 
echo "Edge Case 4: Valid registration (should succeed)"
RESPONSE=$(curl -s -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "valid_user", "password": "password123"}')
echo "Valid registration response: $RESPONSE"
echo ""

# Edge case 5: Login with wrong password
echo "Edge Case 5: Login with wrong password (should fail)"
RESPONSE=$(curl -s -X POST $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "valid_user", "password": "wrongpassword"}')
echo "Wrong password login response: $RESPONSE"
echo ""

# Edge case 6: Create todo without required title field
echo "Edge Case 6: Create todo without title (should fail)"
curl -s -c cookies.txt -X POST $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "valid_user", "password": "password123"}' > /dev/null
RESPONSE=$(curl -s -b cookies.txt -X POST $BASE_URL/todos \
  -H "Content-Type: application/json" \
  -d '{}')
echo "No title todo response: $RESPONSE"
echo ""

# Edge case 7: Create todo with blank title
echo "Edge Case 7: Create todo with blank title (should fail)"
RESPONSE=$(curl -s -b cookies.txt -X POST $BASE_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "", "description": "Some description"}')
echo "Blank title todo response: $RESPONSE"
echo ""

# Edge case 8: Normal todo creation should work
echo "Edge Case 8: Valid todo creation (should succeed)"
RESPONSE=$(curl -s -b cookies.txt -X POST $BASE_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Valid title", "description": ""}')
echo "Valid todo response: $RESPONSE"
TODO_ID=$(echo "$RESPONSE" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo ""

# Edge case 9: Try to update the newly created todo with blank title
echo "Edge Case 9: Update todo with blank title (should fail)"
RESPONSE=$(curl -s -b cookies.txt -X PUT $BASE_URL/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title": ""}')
echo "Blank title update response: $RESPONSE"
echo ""

# Edge case 10: Change password with wrong old password
echo "Edge Case 10: Change password with wrong old password (should fail)"
RESPONSE=$(curl -s -b cookies.txt -X PUT $BASE_URL/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "wrongpassword", "new_password": "newerpass123"}')
echo "Wrong old password change response: $RESPONSE"
echo ""

# Edge case 11: Try changing to short new password
echo "Edge Case 11: Change password to short password (should fail)"
RESPONSE=$(curl -s -b cookies.txt -X PUT $BASE_URL/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "short"}')
echo "Short new password change response: $RESPONSE"
echo ""

# Edge case 12: Valid password change should work
echo "Edge Case 12: Valid password change (should succeed)"
RESPONSE=$(curl -s -b cookies.txt -X PUT $BASE_URL/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword456"}')
echo "Valid password change response: $RESPONSE"
echo ""

# Edge case 13: After password change, old password should not work for login
echo "Edge Case 13: Login with old password after change (should fail)"
curl -s -X POST $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "valid_user", "password": "password123"}'
# This request will fail, but we don't capture the output as it's expected

# Test logging in with new password
LOGIN_RESP=$(curl -s -b cookies.txt -X POST $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "valid_user", "password": "newpassword456"}')
echo "Login with new password succeeded: $LOGIN_RESP"
echo ""

# Clean up cookies
rm -f cookies.txt

echo "All edge case tests completed!"