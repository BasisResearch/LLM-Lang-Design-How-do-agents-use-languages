#!/bin/bash

echo "Testing Todo App Server..."

# Start the server in the background
echo "Starting server on port 3001..."
./run.sh --port 3001 &
SERVER_PID=$!
sleep 3  # Give the server time to start

# Test variables
BASE_URL="http://localhost:3001"

echo "Test 1: Register a new user"
response=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  $BASE_URL/register)
echo "Response: $response"
if echo $response | grep -q "id"; then
  echo "✓ Register user test PASSED"
else
  echo "✗ Register user test FAILED"
fi
echo

# Capture session cookie from registration response
echo "Test 2: Login with the user"
response=$(curl -s -c cookies.txt -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  $BASE_URL/login)
echo "Response: $response"
if echo $response | grep -q "id"; then
  echo "✓ Login test PASSED"
else
  echo "✗ Login test FAILED"
fi
echo

echo "Test 3: Access protected /me endpoint"
response=$(curl -s -b cookies.txt -X GET $BASE_URL/me)
echo "Response: $response"
if echo $response | grep -q "testuser"; then
  echo "✓ Access /me endpoint test PASSED"
else
  echo "✗ Access /me endpoint test FAILED"
fi
echo

echo "Test 4: Create a new todo"
response=$(curl -s -b cookies.txt -X POST -H "Content-Type: application/json" \
  -d '{"title":"Test todo","description":"Test description"}' \
  $BASE_URL/todos)
echo "Response: $response"
if echo $response | grep -q "id"; then
  echo "✓ Create todo test PASSED"
else
  echo "✗ Create todo test FAILED"
fi
echo

echo "Test 5: List todos"
response=$(curl -s -b cookies.txt -X GET $BASE_URL/todos)
echo "Response: $response"
if echo $response | grep -q "Test todo"; then
  echo "✓ List todos test PASSED"
else
  echo "✗ List todos test FAILED"
fi
echo

echo "Test 6: Get specific todo"
# Assuming the todo ID is 1
response=$(curl -s -b cookies.txt -X GET $BASE_URL/todos/1)
echo "Response: $response"
if echo $response | grep -q "Test todo"; then
  echo "✓ Get specific todo test PASSED"
else
  echo "✗ Get specific todo test FAILED"
fi
echo

echo "Test 7: Update specific todo"
response=$(curl -s -b cookies.txt -X PUT -H "Content-Type: application/json" \
  -d '{"title":"Updated todo","completed":true}' \
  $BASE_URL/todos/1)
echo "Response: $response"
if echo $response | jq -e '.completed == true' >/dev/null 2>&1; then
  echo "✓ Update todo test PASSED"
else
  echo "✗ Update todo test FAILED"
fi
echo

echo "Test 8: Logout"
response=$(curl -s -b cookies.txt -X POST $BASE_URL/logout)
echo "Response: $response"
if [ "$response" == "{}" ]; then
  echo "✓ Logout test PASSED"
else
  echo "✗ Logout test FAILED"
fi
echo

echo "Test 9: Try accessing protected endpoint without session"
response=$(curl -s -X GET $BASE_URL/me)
echo "Response: $response"
if echo $response | grep -q "Authentication required"; then
  echo "✓ Unauthenticated access blocked test PASSED"
else
  echo "✗ Unauthenticated access blocked test FAILED"
fi
echo

echo "Test 10: Delete todo"
response=$(curl -s -b cookies.txt -X DELETE $BASE_URL/todos/1)
status_code=$(curl -s -o /dev/null -w "%{http_code}" -b cookies.txt -X DELETE $BASE_URL/todos/1)
if [ "$status_code" -eq 204 ]; then
  echo "✓ Delete todo test PASSED"
else
  echo "✗ Delete todo test FAILED, status: $status_code"
fi
echo

echo "Test 11: Test various error conditions"

# Try registering duplicate username
response=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  $BASE_URL/register)
status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"password123"}' \
  $BASE_URL/register)
if [ "$status" -eq 409 ]; then
  echo "✓ Duplicate registration blocked test PASSED"
else
  echo "✗ Duplicate registration blocked test FAILED"
fi

# Try login with wrong credentials
response=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"wrongpassword"}' \
  $BASE_URL/login)
status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  -d '{"username":"testuser","password":"wrongpassword"}' \
  $BASE_URL/login)
if [ "$status" -eq 401 ]; then
  echo "✓ Bad login blocked test PASSED"
else
  echo "✗ Bad login blocked test FAILED"
fi

# Clean up
kill $SERVER_PID
rm -f cookies.txt

echo
echo "Testing completed!"