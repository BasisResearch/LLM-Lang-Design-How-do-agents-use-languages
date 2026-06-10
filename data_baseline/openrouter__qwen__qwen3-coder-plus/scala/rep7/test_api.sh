#!/bin/bash

# Test script for Todo API
SERVER_URL="http://localhost:8080"

echo "Starting server in background..."
scala-cli run TodoApp.scala -- --port 8080 &
SERVER_PID=$!
sleep 3  # Wait for server to start

# Function to cleanup
cleanup() {
  echo "Stopping server..."
  kill $SERVER_PID 2>/dev/null
}

# Trap script exit to ensure cleanup
trap cleanup EXIT

echo "Testing Todo API endpoints..."

# Test 1: Register new user
echo "Test 1: Registering new user..."
response=$(curl -s -X POST $SERVER_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')

if [[ $response == *'"id"'* ]]; then
  echo "✓ Registration successful: $response"
else
  echo "✗ Registration failed: $response"
  exit 1
fi

# Test 2: Invalid registration (short password)
echo "Test 2: Trying registration with short password..."
response=$(curl -s -X POST $SERVER_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "pass"}')

if [[ $response == *'"Password too short"'* ]]; then
  echo "✓ Short password validation passed: $response"
else
  echo "✗ Short password validation failed: $response"
  exit 1
fi

# Test 3: Login with valid credentials
echo "Test 3: Logging in with valid credentials..."
response=$(curl -s -c cookies.txt -X POST $SERVER_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')

if [[ $response == *'"id"'* ]]; then
  echo "✓ Login successful: $response"
  SESSION_ID=$(grep session_id cookies.txt | awk '{print $7}')
  if [ -n "$SESSION_ID" ]; then
    echo "✓ Session cookie obtained: $SESSION_ID"
  else
    echo "✗ Failed to get session ID"
    exit 1
  fi
else
  echo "✗ Login failed: $response"
  exit 1
fi

# Test 4: Get user info (requires auth)
echo "Test 4: Getting user info with session..."
response=$(curl -s -b cookies.txt $SERVER_URL/me)

if [[ $response == *'"id"'* && $response == *'"username"'* ]]; then
  echo "✓ Get user info successful: $response"
else
  echo "✗ Get user info failed: $response"
  exit 1
fi

# Test 5: Get user info without auth (should fail)
echo "Test 5: Attempting to get user info without auth..."
response=$(curl -s $SERVER_URL/me)

if [[ $response == *'"Authentication required"'* ]]; then
  echo "✓ Unauthorized access correctly blocked: $response"
else
  echo "✗ Access should have been blocked: $response"
  exit 1
fi

# Test 6: Create todo
echo "Test 6: Creating a todo item..."
response=$(curl -s -b cookies.txt -X POST $SERVER_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "My First Task", "description": "Task description"}')

if [[ $response == *'"id"'* && $response == *'"title"'* ]]; then
  TODO_ID=$(echo $response | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
  echo "✓ Todo created successfully with ID: $TODO_ID, response: $response"
else
  echo "✗ Todo creation failed: $response"
  exit 1
fi

# Test 7: Get all todos
echo "Test 7: Getting all todos for user..."
response=$(curl -s -b cookies.txt $SERVER_URL/todos)

if [[ $response == *"My First Task"* ]]; then
  echo "✓ Successfully retrieved todos: $response"
else
  echo "✗ Failed to retrieve todos: $response"
  exit 1
fi

# Test 8: Get specific todo
echo "Test 8: Getting a specific todo..."
response=$(curl -s -b cookies.txt $SERVER_URL/todos/$TODO_ID)

if [[ $response == *"My First Task"* ]]; then
  echo "✓ Successfully retrieved specific todo: $response"
else
  echo "✗ Failed to retrieve specific todo: $response"
  exit 1
fi

# Test 9: Update todo
echo "Test 9: Updating the todo..."
response=$(curl -s -b cookies.txt -X PUT $SERVER_URL/todos/$TODO_ID \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated Task Title", "completed": true}')

if [[ $response == *"Updated Task Title"* && $response == *'"completed":true'* ]]; then
  echo "✓ Todo updated successfully: $response"
else
  echo "✗ Todo update failed: $response"
  exit 1
fi

# Test 10: Change password
echo "Test 10: Changing password..."
response=$(curl -s -b cookies.txt -X PUT $SERVER_URL/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword456"}')

if [ "$response" == "{}" ]; then
  echo "✓ Password changed successfully"
else
  echo "✗ Password change failed: $response"
  exit 1
fi

# Test 11: Logout
echo "Test 11: Logging out..."
response=$(curl -s -b cookies.txt -X POST $SERVER_URL/logout)

if [ "$response" == "{}" ]; then
  echo "✓ Logout successful"
else
  echo "✗ Logout failed: $response"
  exit 1
fi

# Try to access protected resource after logout
echo "Test 12: Trying to access protected resource after logout..."
response=$(curl -s -b cookies.txt $SERVER_URL/me)

if [[ $response == *'"Authentication required"'* ]]; then
  echo "✓ Access correctly blocked after logout: $response"
else
  echo "✗ Access should have been blocked after logout: $response"
  exit 1
fi

# Test 13: Log back in with new password
echo "Test 13: Logging back in with new password..."
response=$(curl -s -c cookies_new.txt -X POST $SERVER_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newpassword456"}')

if [[ $response == *'"id"'* ]]; then
  echo "✓ Re-login with new password successful: $response"
else
  echo "✗ Re-login with new password failed: $response"
  exit 1
fi

# Test 14: Create multiple todos and verify order
echo "Test 14: Creating additional todos to test ordering..."
response1=$(curl -s -b cookies_new.txt -X POST $SERVER_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Second Task", "description": "Another task"}')
response2=$(curl -s -b cookies_new.txt -X POST $SERVER_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Third Task", "description": "Yet another task"}')

id1=$(echo $response1 | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
id2=$(echo $response2 | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")

if [ -n "$id1" ] && [ -n "$id2" ] && [ $id2 -gt $id1 ]; then
  echo "✓ Additional todos created: Task $id1 and Task $id2"
else
  echo "✗ Failed to create additional todos"
  exit 1
fi

# Test 15: Verify todos come back in ascending ID order
all_todos=$(curl -s -b cookies_new.txt $SERVER_URL/todos)
first_todo_id=$(echo $all_todos | python3 -c "import sys, json; todos=json.load(sys.stdin); print(todos[0]['id'])")

if [ "$first_todo_id" -eq $TODO_ID ] || [ "$first_todo_id" -eq $id1 ]; then
  echo "✓ Todos returned in correct order: $(echo $all_todos | wc -l) lines"
else
  echo "✗ Todos not returned in ascending ID order: $all_todos"
fi

# Test 16: Delete a todo
echo "Test 16: Deleting a todo..."
response=$(curl -s -b cookies_new.txt -X DELETE $SERVER_URL/todos/$id1)
status_code=$(curl -s -w "%{http_code}" -o /dev/null -b cookies_new.txt -X DELETE $SERVER_URL/todos/$id1)

if [ "$status_code" -eq 204 ]; then
  echo "✓ Todo deleted successfully (status: $status_code)"
else
  echo "✗ Todo deletion failed (status: $status_code): $response"
  exit 1
fi

# Test 17: Try to access deleted todo (should return 404)
STATUS_404=$(curl -s -w "%{http_code}" -o /dev/null -b cookies_new.txt $SERVER_URL/todos/$id1)
if [ "$STATUS_404" -eq 404 ]; then
  echo "✓ Deleted todo correctly returns 404 (status: $STATUS_404)"
else
  echo "✗ Deleted todo should return 404"
  exit 1
fi

# Test 18: Test title validation (empty title should fail)
echo "Test 18: Testing empty title validation..."
response=$(curl -s -b cookies_new.txt -X POST $SERVER_URL/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "", "description": "Description only"}')

if [[ $response == *'"Title is required"'* ]]; then
  echo "✓ Empty title validation passed: $response"
else
  echo "✗ Empty title validation failed: $response"
  exit 1
fi

echo "All tests passed successfully!"

# Cleanup will happen at script exit due to trap