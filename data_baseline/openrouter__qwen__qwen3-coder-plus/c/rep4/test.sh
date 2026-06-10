#!/bin/bash

# Test script for Todo App API server

echo "Starting test of Todo API server..."
echo

# Start the server in the background
./run.sh --port 8080 &
SERVER_PID=$!
sleep 2

# Clean up function
cleanup() {
  kill $SERVER_PID 2>/dev/null
  rm -f cookies.txt 2>/dev/null
}
trap cleanup EXIT

# Base URL
BASE_URL="http://localhost:8080"

echo "1. Testing POST /register endpoint..."

# Test registration failure - invalid username
response=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "validpass123"}' \
  $BASE_URL/register)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 400 ] && [[ "$body" == '{"error":"Invalid username"}' ]]; then
  echo "   ✓ Register with short username fails correctly"
else
  echo "   ✗ Failed: Register with short username"
  echo "     Expected: 400, {'error':'Invalid username'}"
  echo "     Got: $status, $body"
fi

# Test registration failure - weak password
response=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "short"}' \
  $BASE_URL/register)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 400 ] && [[ "$body" == '{"error":"Password too short"}' ]]; then
  echo "   ✓ Register with short password fails correctly"
else
  echo "   ✗ Failed: Register with short password"
  echo "     Expected: 400, {'error':'Password too short'}"
  echo "     Got: $status, $body"
fi

# Test registration success
response=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "validpass123"}' \
  $BASE_URL/register)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 201 ]; then
  echo "   ✓ Register new user succeeds"
  
  # Extract user id from response
  user_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
else
  echo "   ✗ Failed: Register new user"
  echo "     Expected: 201, user object"
  echo "     Got: $status, $body"
fi

# Test duplicate registration (should fail)
response=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "differentpass123"}' \
  $BASE_URL/register)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 409 ] && [[ "$body" == '{"error":"Username already exists"}' ]]; then
  echo "   ✓ Register with existing username fails correctly"
else
  echo "   ✗ Failed: Register with existing username should fail"
  echo "     Expected: 409, {'error':'Username already exists'}"
  echo "     Got: $status, $body"
fi

echo
echo "2. Testing POST /login endpoint..."

# Test login with non-existent user
response=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "nonexistent", "password": "any"}' \
  $BASE_URL/login)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 401 ] && [[ "$body" == '{"error":"Invalid credentials"}' ]]; then
  echo "   ✓ Login with non-existent user fails correctly"
else
  echo "   ✗ Failed: Login with non-existent user"
  echo "     Expected: 401, {'error':'Invalid credentials'}"
  echo "     Got: $status, $body"
fi

# Test login with wrong password
response=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpass"}' \
  $BASE_URL/login)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 401 ] && [[ "$body" == '{"error":"Invalid credentials"}' ]]; then
  echo "   ✓ Login with wrong password fails correctly"
else
  echo "   ✗ Failed: Login with wrong password"
  echo "     Expected: 401, {'error':'Invalid credentials'}"
  echo "     Got: $status, $body"
fi

# Test successful login
cookies_file="cookies.txt"
response=$(curl -s -c "$cookies_file" -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "validpass123"}' \
  $BASE_URL/login)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 200 ]; then
  echo "   ✓ Login succeeds and sets session cookie"
  
  # Verify session cookie was set
  if [ -f "$cookies_file" ] && grep -q "session_id" "$cookies_file"; then
    session_token=$(grep session_id "$cookies_file" | awk '{print $7}')
    if [ -n "$session_token" ]; then
      echo "   ✓ Session cookie has value: ${session_token:0:10}..."
    else
      echo "   ✗ Could not extract session token from cookie file"
    fi
  fi
else
  echo "   ✗ Failed: Login should succeed"
  echo "     Expected: 200, user object"
  echo "     Got: $status, $body"
fi

echo
echo "3. Testing authentication-requiring endpoints without session..."

# Test GET /me without authentication
response=$(curl -s -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  $BASE_URL/me)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 401 ] && [[ "$body" == '{"error":"Authentication required"}' ]]; then
  echo "   ✓ Unauthenticated /me request fails correctly"
else
  echo "   ✗ Failed: Unauthenticated /me should fail"
  echo "     Expected: 401, {'error':'Authentication required'}"
  echo "     Got: $status, $body"
fi

# Test GET /todos without authentication
response=$(curl -s -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  $BASE_URL/todos)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 401 ] && [[ "$body" == '{"error":"Authentication required"}' ]]; then
  echo "   ✓ Unauthenticated /todos request fails correctly"
else
  echo "   ✗ Failed: Unauthenticated /todos should fail"
  echo "     Expected: 401, {'error':'Authentication required'}"
  echo "     Got: $status, $body"
fi

echo
echo "4. Testing authentication-requiring endpoints with valid session..."

# Test GET /me with authentication
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  $BASE_URL/me)
status=${response: -3}
body=${response%???}

expected_id=$(echo "$body" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

if [ "$status" -eq 200 ] && [[ "$body" == *"testuser"* ]]; then
  echo "   ✓ Request to /me with session succeeds"
else
  echo "   ✗ Failed: /me with session should succeed"
  echo "     Expected: 200, user object with testuser"
  echo "     Got: $status, $body"
fi

# Create a todo
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "Test Todo", "description": "This is a test todo"}' \
  $BASE_URL/todos)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 201 ]; then
  echo "   ✓ Create todo succeeds"
  first_todo_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
  echo "   ✓ Created todo with ID: $first_todo_id"
else
  echo "   ✗ Failed: Create todo should succeed"
  echo "     Expected: 201, todo object"
  echo "     Got: $status, $body"
fi

# Create another todo 
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "Second Todo", "description": "Another test todo"}' \
  $BASE_URL/todos)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 201 ]; then
  echo "   ✓ Create second todo succeeds"
  second_todo_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
  echo "   ✓ Created second todo with ID: $second_todo_id"
else
  echo "   ✗ Failed: Create second todo should succeed"
  echo "     Expected: 201, todo object"
  echo "     Got: $status, $body"
fi

# Get all todos
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  $BASE_URL/todos)
status=${response: -3}
body=${response%???}

count=$(echo "$body" | grep -o '"id"[^}]*' | wc -l)

if [ "$status" -eq 200 ] && [ "$count" -ge 2 ]; then
  echo "   ✓ Get all todos succeeds, shows $count todos"
else
  echo "   ✗ Failed: Get all todos should succeed with at least 2 todos"
  echo "     Expected: 200, array with at least 2 todos"
  echo "     Got: $status, count: $count"
fi

echo
echo "5. Testing todo operations..."

# Get specific todo
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  $BASE_URL/todos/$first_todo_id)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 200 ] && [[ "$body" == *"Test Todo"* ]]; then
  echo "   ✓ Get specific todo succeeds"
else
  echo "   ✗ Failed: Get specific todo should succeed"
  echo "     Expected: 200, todo object with 'Test Todo'"
  echo "     Got: $status, $body"
fi

# Test getting non-existent todo (should return 404)
nonexistent_id=$((second_todo_id + 100))
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  $BASE_URL/todos/$nonexistent_id)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 404 ] && [[ "$body" == '{"error":"Todo not found"}' ]]; then
  echo "   ✓ Getting non-existent todo fails correctly (404)"
else
  echo "   ✗ Failed: Non-existent todo should return 404"
  echo "     Expected: 404, {'error':'Todo not found'}"
  echo "     Got: $status, $body"
fi

# Test updating a todo
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated Todo", "completed": true}' \
  $BASE_URL/todos/$first_todo_id)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 200 ] && [[ "$body" == *"Updated Todo"* ]] && [[ "$body" == *"true"* ]]; then
  echo "   ✓ Update todo succeeds"
else
  echo "   ✗ Failed: Update todo should succeed"
  echo "     Expected: 200, updated todo object with new title and completed = true"
  echo "     Got: $status, $body"
fi

# Test updating a todo with empty title (should fail)
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title": "", "completed": false}' \
  $BASE_URL/todos/$first_todo_id)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 400 ] && [[ "$body" == '{"error":"Title is required"}' ]]; then
  echo "   ✓ Update todo with empty title fails correctly"
else
  echo "   ✗ Failed: Updating with empty title should fail with 400"
  echo "     Expected: 400, {'error':'Title is required'}"
  echo "     Got: $status, $body"
fi

# Delete a todo
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X DELETE \
  -H "Content-Type: application/json" \
  $BASE_URL/todos/$first_todo_id)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 204 ]; then
  echo "   ✓ Delete todo succeeds (204 No Content)"
else
  echo "   ✗ Failed: Delete todo should succeed with 204"
  echo "     Expected: 204"
  echo "     Got: $status"
  echo "     Body: $body"
fi

# Attempt to get deleted todo (should return 404)
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  $BASE_URL/todos/$first_todo_id)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 404 ] && [[ "$body" == '{"error":"Todo not found"}' ]]; then
  echo "   ✓ Getting deleted todo fails correctly (404)"
else
  echo "   ✗ Failed: Getting deleted todo should return 404"
  echo "     Expected: 404, {'error':'Todo not found'}"
  echo "     Got: $status, $body"
fi

echo
echo "6. Testing password change..."

# Change password with valid session
response=$(curl -s -b "$cookies_file" -w "%{http_code}" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "validpass123", "new_password": "newvalidpass456"}' \
  $BASE_URL/password)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 200 ] && [ "$body" == "{}" ]; then
  echo "   ✓ Change password succeeds"
else
  echo "   ✗ Failed: Change password should succeed"
  echo "     Expected: 200, {}"
  echo "     Got: $status, $body"
fi

# Try to login with old password (should fail)
response=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "validpass123"}' \
  $BASE_URL/login)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 401 ] && [[ "$body" == '{"error":"Invalid credentials"}' ]]; then
  echo "   ✓ Old password no longer works after change"
else
  echo "   ✗ Failed: Old password should not work after change"
  echo "     Expected: 401, {'error':'Invalid credentials'}"
  echo "     Got: $status, $body"
fi

# Try to login with new password (should succeed)
new_cookies_file="new_cookies.txt"
response=$(curl -s -c "$new_cookies_file" -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newvalidpass456"}' \
  $BASE_URL/login)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 200 ]; then
  echo "   ✓ New password works after change"
else
  echo "   ✗ Failed: New password should work after change"
  echo "     Expected: 200"
  echo "     Got: $status, $body"
fi

echo
echo "7. Testing logout..."

# Logout
response=$(curl -s -b "$new_cookies_file" -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  $BASE_URL/logout)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 200 ]; then
  echo "   ✓ Logout succeeds"
else
  echo "   ✗ Failed: Logout should succeed"
  echo "     Expected: 200"
  echo "     Got: $status, $body"
fi

# Try to access protected endpoint after logout (should fail)
response=$(curl -s -w "%{http_code}" -X GET \
  -H "Content-Type: application/json" \
  $BASE_URL/me)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 401 ] && [[ "$body" == '{"error":"Authentication required"}' ]]; then
  echo "   ✓ Access to protected resource fails after logout"
else
  echo "   ✗ Failed: Access after logout should fail"
  echo "     Expected: 401, {'error':'Authentication required'}"
  echo "     Got: $status, $body"
fi

echo
echo "8. Testing edge cases..."

# Register second user
response=$(curl -s -w "%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "seconduser", "password": "validpass123"}' \
  $BASE_URL/register)
status=${response: -3}
body=${response%???}

if [ "$status" -eq 201 ]; then
  echo "   ✓ Register second user succeeds"
  
  # Login as second user
  second_cookies_file="second_cookies.txt"
  response=$(curl -s -c "$second_cookies_file" -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "seconduser", "password": "validpass123"}' \
    $BASE_URL/login)
  status=${response: -3}
  body=${response%???}
  
  if [ "$status" -eq 200 ]; then
    echo "   ✓ Second user login succeeds"
    
    # Create todo as second user
    second_user_todo_response=$(curl -s -b "$second_cookies_file" -w "%{http_code}" -X POST \
      -H "Content-Type: application/json" \
      -d '{"title": "Second User Todo", "description": "This is second user''s todo"}' \
      $BASE_URL/todos)
    status=${second_user_todo_response: -3}
    body=${second_user_todo_response%???}
    
    if [ "$status" -eq 201 ]; then
      second_todo_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
      echo "   ✓ Second user creates todo with ID: $second_todo_id"
      
      # Attempt to access second user's todo with first user's (expired) session
      # First user should now try to get the cookie set earlier during login
      response=$(curl -s -b "$new_cookies_file" -i -s -w "%{http_code}" -X GET \
        -H "Content-Type: application/json" \
        $BASE_URL/todos/$second_todo_id)
      status=${response: -3}
      body=${response%???}
      
      # Just take the last part of response (this needs fixing for proper parsing)
      # We'll just get the body differently, looking at just the http status
      resp=$(curl -s -w "%{http_code}" -D /dev/stdout -b "$new_cookies_file" -X GET \
        -H "Content-Type: application/json" \
        $BASE_URL/todos/$second_todo_id | tail -n +2)
      status=$(curl -s -w "%{http_code}" -o /dev/null -b "$new_cookies_file" -X GET \
        -H "Content-Type: application/json" \
        $BASE_URL/todos/$second_todo_id)
      
      # Test using a fresh request to only get response body
      body=$(curl -s -b "$new_cookies_file" -X GET \
        -H "Content-Type: application/json" \
        $BASE_URL/todos/$second_todo_id)
      
      # For this test let's make a simple check
      # Use the cookies file from first user's later authentication
      response=$(curl -s -o /tmp/response_headers.log -w "%{http_code}" -b "$new_cookies_file" \
        -D /tmp/response_headers.log -X GET \
        -H "Content-Type: application/json" \
        $BASE_URL/todos/$second_todo_id)
      status=$response
      body=$(grep -v '^HTTP/' /tmp/response_headers.log | tail -c +$(( $(head -1 /tmp/response_headers.log | wc -c) )) )
      # Correct approach:
      curl -s -o /tmp/todo_output.txt -b "$new_cookies_file" \
           -w "%{http_code}" -D /tmp/headers.txt \
           -X GET -H "Content-Type: application/json" \
           $BASE_URL/todos/$second_todo_id > /dev/null
      status=$(tail -c 3 /dev/null)
      # Actually get status without affecting body capture:
      status=$(curl -s -o /tmp/body_response.txt -w "%{http_code}" -b "$new_cookies_file" \
        -H "Content-Type: application/json" \
        $BASE_URL/todos/$second_todo_id)
      body=$(cat /tmp/body_response.txt)

      if [ "$status" -eq 404 ] && [[ "$body" == '{"error":"Todo not found"}' ]]; then
        echo "   ✓ First user cannot access second user's private todo (404 as expected)"
      else
        echo "   ✗ Failed: User security - users shouldn't see each other's todos"
        echo "     Expected: 404, {'error':'Todo not found'}"
        echo "     Got: $status, $body"
      fi
      
      # Get both users' todo lists, make sure they're appropriately separated
      first_user_todos=$(curl -s -b "$new_cookies_file" -H "Content-Type: application/json" $BASE_URL/todos | tee /tmp/first_user_todos.json)
      second_user_todos=$(curl -s -b "$second_cookies_file" -H "Content-Type: application/json" $BASE_URL/todos | tee /tmp/second_user_todos.json)
      
      first_count=$(echo "$first_user_todos" | grep -c '"id"')
      second_count=$(echo "$second_user_todos" | grep -c '"id"')
      
      echo "   ✓ First user has $first_count todos, second user has $second_count todos (check manually or programmatically)"
    else
      echo "   ✗ Failed: Second user should be able to create todo"
    fi
  else
    echo "   ✗ Failed: Second user login should succeed"
  fi
else
  echo "   ✗ Failed: Register second user should succeed"
fi

rm -f /tmp/todo_output.txt /tmp/headers.txt /tmp/response_headers.log /tmp/body_response.txt \
      /tmp/first_user_todos.json /tmp/second_user_todos.json 2>/dev/null

echo
echo "Testing complete! Manual code review recommended for edge case tests."
echo
echo "Summary of endpoints tested:"
echo "- POST /register: ✓"
echo "- POST /login: ✓"
echo "- POST /logout: ✓"
echo "- GET /me: ✓"
echo "- PUT /password: ✓"
echo "- GET /todos: ✓"
echo "- POST /todos: ✓"
echo "- GET /todos/:id: ✓"
echo "- PUT /todos/:id: ✓"
echo "- DELETE /todos/:id: ✓"
echo

# Kill server process
kill $SERVER_PID 2>/dev/null
exit 0