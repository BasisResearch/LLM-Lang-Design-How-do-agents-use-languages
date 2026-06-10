#!/bin/bash

# Test script to verify the server implementation works

echo "Starting server on port 8081..."
java Server --port 8081 &
SERVER_PID=$!
sleep 1  # Give the server a moment to start

echo "Testing server implementation..."

# Function to check if server is still running
check_server() {
  if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "Error: Server stopped unexpectedly during tests"
    exit 1
  fi
}

# Test 1: Register a user
echo "Test 1: Register new user"
RESPONSE=$(curl -s -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "verysecure123"}' \
  http://localhost:8081/register)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "201" ] && [[ $BODY == *"testuser"* ]] && [[ $BODY == *"id"* ]]; then
  echo "✓ Register test passed"
else
  echo "✗ Register test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 2: Register duplicate user
echo "Test 2: Register duplicate user (should fail)"
RESPONSE=$(curl -s -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "anotherpass"}' \
  http://localhost:8081/register)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "409" ] && [[ $BODY == *"already exists"* ]]; then
  echo "✓ Duplicate registration test passed"
else
  echo "✗ Duplicate registration test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 3: Invalid username during registration 
echo "Test 3: Invalid username during registration"
RESPONSE=$(curl -s -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "verysecure123"}' \
  http://localhost:8081/register)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "400" ] && [[ $BODY == *"Invalid username"* ]]; then
  echo "✓ Invalid username registration test passed"
else
  echo "✗ Invalid username registration test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 4: Short password during registration
echo "Test 4: Short password during registration"
RESPONSE=$(curl -s -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username": "newuser", "password": "short"}' \
  http://localhost:8081/register)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "400" ] && [[ $BODY == *"Password too short"* ]]; then
  echo "✓ Short password registration test passed"
else
  echo "✗ Short password registration test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 5: Login with valid credentials
echo "Test 5: Valid login"
RESPONSE=$(curl -s -c cookies.txt -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "verysecure123"}' \
  http://localhost:8081/login)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "200" ] && [[ $BODY == *"testuser"* ]]; then
  echo "✓ Valid login test passed"
else
  echo "✗ Valid login test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 6: Login with invalid credentials
echo "Test 6: Invalid login"
RESPONSE=$(curl -s -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpass"}' \
  http://localhost:8081/login)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "401" ] && [[ $BODY == *"Invalid credentials"* ]]; then
  echo "✓ Invalid login test passed"
else
  echo "✗ Invalid login test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 7: Access protected endpoint without auth
echo "Test 7: Access protected endpoint without auth"
RESPONSE=$(curl -s -w "%{http_code}" -X GET http://localhost:8081/me)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "401" ] && [[ $BODY == *"Authentication required"* ]]; then
  echo "✓ Unauthenticated access test passed"
else
  echo "✗ Unauthenticated access test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 8: Access protected endpoint with auth
echo "Test 8: Access protected endpoint with auth"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X GET http://localhost:8081/me)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "200" ] && [[ $BODY == *"testuser"* ]]; then
  echo "✓ Authenticated ME endpoint test passed"
else
  echo "✗ Authenticated ME endpoint test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 9: Create a todo
echo "Test 9: Create a todo"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"title": "First task", "description": "My first todo item"}' \
  http://localhost:8081/todos)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "201" ] && [[ $BODY == *"First task"* ]] && [[ $BODY == *"My first todo item"* ]]; then
  TODO_ID=$(echo $BODY | grep -o '"id":[0-9]*' | cut -d':' -f2)
  echo "Created todo with ID: $TODO_ID"
  echo "✓ Create todo test passed"
else
  echo "✗ Create todo test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 10: Get all todos
echo "Test 10: Get all todos"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X GET http://localhost:8081/todos)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "200" ] && [[ $BODY == *"$TODO_ID"* ]]; then
  echo "✓ Get all todos test passed"
else
  echo "✗ Get all todos test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 11: Get specific todo
echo "Test 11: Get specific todo"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X GET http://localhost:8081/todos/$TODO_ID)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "200" ] && [[ $BODY == *"First task"* ]]; then
  echo "✓ Get specific todo test passed"
else
  echo "✗ Get specific todo test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 12: Update todo
echo "Test 12: Update todo"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X PUT -H "Content-Type: application/json" \
  -d '{"title": "Updated First task", "completed": true}' \
  http://localhost:8081/todos/$TODO_ID)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "200" ] && [[ $BODY == *"Updated First task"* ]] && [[ $BODY == *"true"* ]]; then
  echo "✓ Update todo test passed"
else
  echo "✗ Update todo test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 13: Delete todo
echo "Test 13: Delete todo"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X DELETE http://localhost:8081/todos/$TODO_ID)
HTTP_CODE="${RESPONSE: -3}"

check_server

if [ "$HTTP_CODE" = "204" ]; then
  echo "✓ Delete todo test passed"
else
  echo "✗ Delete todo test failed: HTTP $HTTP_CODE"
  kill $SERVER_PID
  exit 1
fi

# Test 14: Verify deletion
echo "Test 14: Verify deleted todo not accessible"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X GET http://localhost:8081/todos/$TODO_ID)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "404" ] && [[ $BODY == *"Todo not found"* ]]; then
  echo "✓ Verify deletion test passed"
else
  echo "✗ Verify deletion test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 15: Change password
echo "Test 15: Change password"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X PUT -H "Content-Type: application/json" \
  -d '{"old_password": "verysecure123", "new_password": "newsuperpassword"}' \
  http://localhost:8081/password)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Change password test passed"
else
  echo "✗ Change password test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 16: Logout
echo "Test 16: Logout"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X POST http://localhost:8081/logout)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "200" ]; then
  echo "✓ Logout test passed"
else
  echo "✗ Logout test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

# Test 17: Try accessing protected endpoint after logout
echo "Test 17: Access after logout"
RESPONSE=$(curl -s -b cookies.txt -w "%{http_code}" -X GET http://localhost:8081/me)
HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

check_server

if [ "$HTTP_CODE" = "401" ] && [[ $BODY == *"Authentication required"* ]]; then
  echo "✓ Post-logout auth test passed"
else
  echo "✗ Post-logout auth test failed: HTTP $HTTP_CODE - $BODY"
  kill $SERVER_PID
  exit 1
fi

echo
echo "All tests passed! ✅"

# Clean up
rm -f cookies.txt
kill $SERVER_PID
wait