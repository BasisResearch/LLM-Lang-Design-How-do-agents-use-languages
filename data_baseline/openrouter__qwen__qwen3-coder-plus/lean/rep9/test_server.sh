#!/bin/bash

# Test script to verify all API endpoints work as expected
set -e

PORT=${1:-8080}
BASE_URL="http://localhost:$PORT"

echo "Testing Todo API server..."

# Wait a moment for server to start
sleep 3

echo "Test 1: Register new user"
response=$(curl -s -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
echo "Response: $response"
expected='{"id":1,"username":"testuser"}'
if echo "$response" | grep -q '"id":1' && echo "$response" | grep -q '"username":"testuser"'; then
  echo "✓ Register test passed"
else
  echo "✗ Register test failed"
  exit 1
fi

echo ""
echo "Test 2: Login user and check session cookie"
# Extract session cookie
login_response=$(curl -c cookies.txt -s -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
echo "Login Response: $login_response"
if echo "$login_response" | grep -q '"id":1'; then
  echo "✓ Login test passed"
else
  echo "✗ Login test failed"
  exit 1
fi

# Extract session ID from cookies file
SESSION_ID=$(grep session_id cookies.txt | awk '{print $7}')
if [ -n "$SESSION_ID" ]; then
  echo "Session ID extracted: $SESSION_ID"
else
  echo "Could not extract session ID - cookies.txt:"
  cat cookies.txt
  exit 1
fi

echo ""
echo "Test 3: Get user info using authentication"
me_response=$(curl -b cookies.txt -s -X GET "$BASE_URL/me")
echo "Me Response: $me_response"
if echo "$me_response" | grep -q '"id":1'; then
  echo "✓ Me endpoint test passed"
else
  echo "✗ Me endpoint test failed"
  exit 1
fi

echo ""
echo "Test 4: Create a todo item"
todo_response=$(curl -b cookies.txt -s -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -d '{"title": "Buy groceries", "description": "Milk and bread"}')
echo "Create Todo Response: $todo_response"
TODO_ID=$(echo "$todo_response" | grep -o '"id":[0-9]*' | cut -d':' -f2)
if [ -n "$TODO_ID" ]; then
  echo "Created Todo ID: $TODO_ID"
else
  echo "Could not extract todo ID"
  exit 1
fi

echo ""
echo "Test 5: Get all todos for user"
todos_response=$(curl -b cookies.txt -s -X GET "$BASE_URL/todos")
echo "Todos Response: $todos_response"
if echo "$todos_response" | grep -q '"id":1'; then
  echo "✓ Get todos test passed"
else
  echo "✗ Get todos test failed"
  exit 1
fi

echo ""
echo "Test 6: Get a specific todo by ID"
specific_todo=$(curl -b cookies.txt -s -X GET "$BASE_URL/todos/$TODO_ID")
echo "Specific Todo Response: $specific_todo"
if echo "$specific_todo" | grep -q '"title":"Buy groceries"'; then
  echo "✓ Get specific todo test passed"
else
  echo "✗ Get specific todo test failed"
  exit 1
fi

echo ""
echo "Test 7: Update the todo"
update_response=$(curl -b cookies.txt -s -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -d '{"completed": true, "title": "Buy groceries updated"}')
echo "Update Todo Response: $update_response"
if echo "$update_response" | grep -q '"completed":true'; then
  echo "✓ Update todo test passed"
else
  echo "✗ Update todo test failed"
  exit 1
fi

echo ""
echo "Test 8: Change password"
password_response=$(curl -b cookies.txt -s -X PUT "$BASE_URL/password" \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword456"}')
echo "Password Change Response: $password_response"
if [ "$password_response" = "{}" ] || echo "$password_response" | grep -q '{}'; then
  echo "✓ Password change test passed"
else
  echo "✗ Password change test failed"
  exit 1
fi

echo ""
echo "Test 9: Logout (invalidate session)"
logout_response=$(curl -b cookies.txt -s -X POST "$BASE_URL/logout" \
  -H "Content-Type: application/json")
echo "Logout response: $logout_response"
if echo "$logout_response" | grep -q '{}'; then
  echo "✓ Logout test passed"
else
  echo "✗ Logout test failed"
  exit 1
fi

# Now we should get an error accessing protected route
echo ""
echo "Test 10: Access protected resource without valid session (should fail)"
noauth_response=$(curl -s -X GET "$BASE_URL/me")
echo "No Auth Response: $noauth_response"
if echo "$noauth_response" | grep -q '"error":"Authentication required"'; then
  echo "✓ Auth required test passed"
else
  echo "✗ Auth required test failed"
  exit 1
fi

echo ""
echo "Test 11: Delete todo"
delete_response=$(curl -b cookies.txt -s -X DELETE "$BASE_URL/todos/$TODO_ID")
delete_status=$(curl -sw '%{http_code}' -b cookies.txt -s -X DELETE "$BASE_URL/todos/$TODO_ID" -o /tmp/delete.out)
if [ "$delete_status" -eq 204 ]; then
  echo "✓ Delete Todo test passed"
else
  echo "✗ Delete Todo test failed"
  echo "Status: $delete_status"
  cat /tmp/delete.out
  exit 1
fi

echo ""
echo "🎉 All tests passed!"