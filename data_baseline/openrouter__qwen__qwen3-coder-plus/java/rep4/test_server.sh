#!/bin/bash

# Start server in background
./run.sh --port 8080 &
SERVER_PID=$!

# Wait for server to start up
sleep 3

# Test endpoint: POST /register
echo "Testing register..."
response=$(curl -s -w "%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')

body="${response%???}"
status="${response: -3}"

if [ "$body" = '{"id": 1, "username": "testuser"}' ] && [ "$status" = "201" ]; then
    echo "✓ Register test PASSED"
else
    echo "✗ Register test FAILED - Expected: {\"id\": 1, \"username\": \"testuser\"}, got: $body (status: $status)"
fi

# Save session cookie to temp file to use later
curl -c cookies.txt -s -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "anothertest", "password": "password123"}'

# Login and capture session cookie
login_response=$(curl -c cookies.txt -s -w "%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')

login_status="${login_response: -3}"
if [ "$login_status" = "200" ]; then
    echo "✓ Login test PASSED"
else
    echo "✗ Login test FAILED (status: $login_status)"
fi

# Test endpoint: GET /me
echo "Testing get me info..."
me_response=$(curl -b cookies.txt -s -w "%{http_code}" -X GET http://localhost:8080/me)
me_body="${me_response%???}"
me_status="${me_response: -3}"

if [ "$me_body" = '{"id": 1, "username": "testuser"}' ] && [ "$me_status" = "200" ]; then
    echo "✓ Get me test PASSED"
else
    echo "✗ Get me test FAILED - Expected: {\"id\": 1, \"username\": \"testuser\"}, got: $me_body (status: $me_status)"
fi

# Test endpoint: POST /todos
todo_response=$(curl -b cookies.txt -s -w "%{http_code}" -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Buy groceries", "description": "Go to the supermarket"}')
  
todo_body="${todo_response%???}"
todo_status="${todo_response: -3}"

# Check that the response contains expected todo data
if [[ $todo_body == *'"title":"Buy groceries"'* ]] && [[ $todo_body == *'"description":"Go to the supermarket"'* ]] && [ "$todo_status" = "201" ]; then
    echo "✓ Create todo test PASSED"
else
    echo "✗ Create todo test FAILED - Got: $todo_body (status: $todo_status)"
fi

# Test endpoint: GET /todos
todos_response=$(curl -b cookies.txt -s -w "%{http_code}" -X GET http://localhost:8080/todos)
todos_body="${todos_response%???}"
todos_status="${todos_response: -3}"

if [[ $todos_body == *'[{'*'"title":"Buy groceries"'*'}]'* ]] && [ "$todos_status" = "200" ]; then
    echo "✓ Get todos test PASSED"
else
    echo "✗ Get todos test FAILED - Got: $todos_body (status: $todos_status)"
fi

# Test endpoint: GET /todos/:id
specific_todo_response=$(curl -b cookies.txt -s -w "%{http_code}" -X GET http://localhost:8080/todos/1)
specific_todo_body="${specific_todo_response%???}"
specific_todo_status="${specific_todo_response: -3}"

if [[ $specific_todo_body == *'"title":"Buy groceries"'* ]] && [ "$specific_todo_status" = "200" ]; then
    echo "✓ Get specific todo test PASSED"
else
    echo "✗ Get specific todo test FAILED - Got: $specific_todo_body (status: $specific_todo_status)"
fi

# Test endpoint: PUT /todos/:id
update_response=$(curl -b cookies.txt -s -w "%{http_code}" -X PUT http://localhost:8080/todos/1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Buy groceries - URGENT", "completed": true}')
  
update_body="${update_response%???}"
update_status="${update_response: -3}"

if [[ $update_body == *'"title":"Buy groceries - URGENT"'* ]] && [[ $update_body == *'"completed":true'* ]] && [ "$update_status" = "200" ]; then
    echo "✓ Update todo test PASSED"
else
    echo "✗ Update todo test FAILED - Got: $update_body (status: $update_status)"
fi

# Test endpoint: PUT /password
pass_response=$(curl -b cookies.txt -s -w "%{http_code}" -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword456"}')
  
pass_body="${pass_response%???}"
pass_status="${pass_response: -3}"

if [ "$pass_body" = "{}" ] && [ "$pass_status" = "200" ]; then
    echo "✓ Change password test PASSED"
else
    echo "✗ Change password test FAILED - Got: $pass_body (status: $pass_status)"
fi

# Test endpoint: DELETE /todos/:id
delete_response=$(curl -b cookies.txt -s -w "%{http_code}" -X DELETE http://localhost:8080/todos/1)
delete_status="${delete_response: -3}"

if [ "$delete_status" = "204" ]; then
    echo "✓ Delete todo test PASSED"
else
    echo "✗ Delete todo test FAILED (status: $delete_status)"
fi

# Test endpoint: POST /logout
logout_response=$(curl -b cookies.txt -s -w "%{http_code}" -X POST http://localhost:8080/logout)
logout_status="${logout_response: -3}"

if [ "$logout_status" = "200" ]; then
    echo "✓ Logout test PASSED"
else
    echo "✗ Logout test FAILED (status: $logout_status)"
fi

# Clean up
kill $SERVER_PID
rm -f cookies.txt

echo "Tests complete!"