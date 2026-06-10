#!/bin/bash

# Start the server in the background
echo "Starting server..."
cabal run todo-api-exe -- --port 3000 &
SERVER_PID=$!
sleep 3  # Wait for server to start

# Base URL
BASE_URL="http://localhost:3000"

# Test register endpoint
echo "Testing register endpoint..."
response=$(curl -s -X POST $BASE_URL/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')

if echo "$response" | grep -q '"id"'; then
  echo "✓ Register endpoint works"
else
  echo "✗ Register endpoint failed"
  echo "Response: $response"
fi

# Test login endpoint
echo "Testing login endpoint..."
response_with_headers=$(curl -s -D - -X POST $BASE_URL/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
  
# Extract session cookie
session_cookie=$(echo "$response_with_headers" | sed -n 's/Set-Cookie: session_id=\([a-zA-Z0-9_]*\).*$/\1/p' | head -1)

if [[ -n "$session_cookie" ]] && echo "$response_with_headers" | grep -q '"id"'; then
  echo "✓ Login endpoint works"
else
  echo "✗ Login endpoint failed"
  echo "Response: $response_with_headers"
fi

# Test authenticated endpoints with extracted session cookie
if [[ -n "$session_cookie" ]]; then
  # Test /me endpoint
  echo "Testing /me endpoint..."
  response=$(curl -s -X GET $BASE_URL/me \
    -H "Cookie: session_id=$session_cookie")
  
  if echo "$response" | grep -q '"id"'; then
    echo "✓ /me endpoint works"
  else
    echo "✗ /me endpoint failed"
    echo "Response: $response"
  fi

  # Test creating a todo
  echo "Testing /todos POST endpoint..."
  todo_response=$(curl -s -X POST $BASE_URL/todos \
    -H "Cookie: session_id=$session_cookie" \
    -H "Content-Type: application/json" \
    -d '{"title": "Test Todo", "description": "Test Description"}')
  
  if echo "$todo_response" | grep -q '"id"'; then
    echo "✓ /todos POST endpoint works"
    todo_id=$(echo "$todo_response" | grep -o '"id":[0-9]*' | cut -d':' -f2)
  else
    echo "✗ /todos POST endpoint failed"
    echo "Response: $todo_response"
  fi

  # Test getting the todos
  echo "Testing /todos GET endpoint..."
  response=$(curl -s -X GET $BASE_URL/todos \
    -H "Cookie: session_id=$session_cookie")
  
  if echo "$response" | grep -q '"id"'; then
    echo "✓ /todos GET endpoint works"
  else
    echo "✗ /todos GET endpoint failed"
    echo "Response: $response"
  fi

  # Test getting specific Todo
  if [[ -n "$todo_id" ]]; then
    echo "Testing /todos/$todo_id GET endpoint..."
    response=$(curl -s -X GET $BASE_URL/todos/$todo_id \
      -H "Cookie: session_id=$session_cookie")
    
    if echo "$response" | grep -q "$todo_id"; then
      echo "✓ /todos/:id GET endpoint works"
    else
      echo "✗ /todos/:id GET endpoint failed"
      echo "Response: $response"
    fi

    # Test updating a Todo
    echo "Testing /todos/$todo_id PUT endpoint..."
    update_response=$(curl -s -X PUT $BASE_URL/todos/$todo_id \
      -H "Cookie: session_id=$session_cookie" \
      -H "Content-Type: application/json" \
      -d '{"title": "Updated Title", "completed": true}')
    
    if echo "$update_response" | grep -q "Updated Title"; then
      echo "✓ /todos/:id PUT endpoint works"
    else
      echo "✗ /todos/:id PUT endpoint failed"
      echo "Response: $update_response"
    fi

    # Test deleting a Todo
    echo "Testing /todos/$todo_id DELETE endpoint..."
    delete_status=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE $BASE_URL/todos/$todo_id \
      -H "Cookie: session_id=$session_cookie")
    
    if [[ "$delete_status" == "204" ]]; then
      echo "✓ /todos/:id DELETE endpoint works"
    else
      echo "✗ /todos/:id DELETE endpoint failed, status: $delete_status"
    fi
  fi

  # Test changing password
  echo "Testing password change endpoint..."
  pwd_response=$(curl -s -w "\n%{http_code}" -X PUT $BASE_URL/password \
    -H "Cookie: session_id=$session_cookie" \
    -H "Content-Type: application/json" \
    -d '{"old_password": "password123", "new_password": "newpassword456"}')
  
  status_code=$(echo "$pwd_response" | tail -n 1)
  if [[ "$status_code" == "200" ]]; then
    echo "✓ Password change endpoint works"
  else 
    echo "✗ Password change endpoint failed, status: $status_code"
    echo "Response: $(echo "$pwd_response" | sed \$d)"
  fi
fi

# Test logout endpoint
if [[ -n "$session_cookie" ]]; then
  echo "Testing logout endpoint..."
  logout_response=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/logout \
    -H "Cookie: session_id=$session_cookie")
  status_code=$(echo "$logout_response" | tail -n 1)
  
  if [[ "$status_code" == "200" ]]; then
    echo "✓ Logout endpoint works"
  else
    echo "✗ Logout endpoint failed, status: $status_code"
  fi
fi

# Test unauthenticated requests
echo "Testing unauthenticated user..."
unauth_response=$(curl -s -w "\n%{http_code}" -X GET $BASE_URL/me)
status_code=$(echo "$unauth_response" | tail -n 1)

if [[ "$status_code" == "401" ]]; then
  echo "✓ Authentication requirement works"
else
  echo "✗ Authentication requirement failed, status: $status_code"  
  echo "Response: $(echo "$unauth_response" | sed \$d)"
fi

# Clean up - kill the server process
kill $SERVER_PID

echo "Testing complete."