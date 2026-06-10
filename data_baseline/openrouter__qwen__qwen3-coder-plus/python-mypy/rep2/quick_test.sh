#!/bin/bash

SERVER_PID=""
function cleanup {
  if [[ -n "$SERVER_PID" ]]; then
    kill $SERVER_PID 2>/dev/null
  fi
}

trap cleanup EXIT

echo "Starting server..."
timeout 30 python3 server.py --port 8081 &
SERVER_PID=$!
sleep 2

echo "Testing endpoint without session (should return 401)..."
result=$(curl -s -w "\n%{http_code}" -X GET http://localhost:8081/me)
status_line=$(echo "$result" | tail -n 1)
body=$(echo "$result" | head -n -1)

if [ "$status_line" = "401" ]; then
    echo "✓ GET /me without session correctly returns 401"
else
    echo "✗ GET /me without session returned $status_line, expected 401"
    echo "Body: $body"
    exit 1
fi

echo "Testing user registration..."
reg_result=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8081/register -H "Content-Type: application/json" -d '{"username":"test_user","password":"secure123"}')
reg_status=$(echo "$reg_result" | tail -n 1)
reg_body=$(echo "$reg_result" | head -n -1)

if [ "$reg_status" = "201" ]; then
    echo "✓ User registered successfully"
    # Extract user ID for login
    user_id=$(echo $reg_body | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
    echo "User ID: $user_id"
else
    echo "✗ Registration failed with status $reg_status"
    echo "Body: $reg_body"
    exit 1
fi

# Test login with cookies saved to file
echo "Testing login..."
session_jar="session.cookie.test"
curl -s -c $session_jar -X POST http://localhost:8081/login -H "Content-Type: application/json" -d '{"username":"test_user","password":"secure123"}'

# Check if we can access profile with session
echo "Testing profile access with valid session..."
profile_result=$(curl -s -b $session_jar -w "\n%{http_code}" -X GET http://localhost:8081/me)
profile_status=$(echo "$profile_result" | tail -n 1)
profile_body=$(echo "$profile_result" | head -n -1)

if [ "$profile_status" = "200" ]; then
    echo "✓ Profile accessible with valid session"
else
    echo "✗ Profile not accessible with valid session: $profile_status"
    echo "Body: $profile_body"
    exit 1
fi

# Test creating a todo
echo "Testing todo creation..."
todo_result=$(curl -s -b $session_jar -w "\n%{http_code}" -X POST http://localhost:8081/todos -H "Content-Type: application/json" -d '{"title":"Test task","description":"This is a test"}')
todo_status=$(echo "$todo_result" | tail -n 1)
todo_body=$(echo "$todo_result" | head -n -1)

if [ "$todo_status" = "201" ]; then
    echo "✓ Todo created successfully"
    todo_id=$(echo $todo_body | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
    echo "Todo ID: $todo_id"
else
    echo "✗ Todo creation failed with status $todo_status"
    echo "Body: $todo_body"
    exit 1
fi

# Test getting todo by ID
echo "Testing get todo by ID..."
gettodo_result=$(curl -s -b $session_jar -w "\n%{http_code}" -X GET http://localhost:8081/todos/$todo_id)
gettodo_status=$(echo "$gettodo_result" | tail -n 1)
gettodo_body=$(echo "$gettodo_result" | head -n -1)

if [ "$gettodo_status" = "200" ]; then
    echo "✓ Get todo by ID successful"
else
    echo "✗ Get todo by ID failed with status $gettodo_status"
    echo "Body: $gettodo_body"
    exit 1
fi

# Test updating todo partially
echo "Testing partial update of todo..."
update_result=$(curl -s -b $session_jar -w "\n%{http_code}" -X PUT http://localhost:8081/todos/$todo_id -H "Content-Type: application/json" -d '{"completed":true}')
update_status=$(echo "$update_result" | tail -n 1)
update_body=$(echo "$update_result" | head -n -1)

if [ "$update_status" = "200" ]; then
    echo "✓ Todo updated successfully"
else
    echo "✗ Todo update failed with status $update_status"
    echo "Body: $update_body"
    exit 1
fi

# Test deleting todo
echo "Testing todo deletion..."
delete_result=$(curl -s -b $session_jar -w "\n%{http_code}" -X DELETE http://localhost:8081/todos/$todo_id)
delete_status=$(echo "$delete_result" | tail -n 1)

if [ "$delete_status" = "204" ]; then
    echo "✓ Todo deleted successfully"
else
    echo "✗ Todo deletion failed with status $delete_status"
    echo "Body: $delete_result"
fi

# Test password change
echo "Testing password change..."
pwd_change_result=$(curl -s -b $session_jar -w "\n%{http_code}" -X PUT http://localhost:8081/password -H "Content-Type: application/json" -d '{"old_password":"secure123","new_password":"new_secure456"}')
pwd_change_status=$(echo "$pwd_change_result" | tail -n 1)

if [ "$pwd_change_status" = "204" ]; then
    echo "✓ Password changed successfully"
else
    echo "✗ Password change failed with status $pwd_change_status"
    echo "Body: $pwd_change_result"
    exit 1
fi

# Test logout
echo "Testing logout..."
logout_result=$(curl -s -b $session_jar -w "\n%{http_code}" -X POST http://localhost:8081/logout)
logout_status=$(echo "$logout_result" | tail -n 1)

if [ "$logout_status" = "204" ]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed with status $logout_status"
    echo "Body: $logout_result"
    exit 1
fi

# Try to access profile after logout (should fail with 401)
echo "Testing access after logout (should fail)..."
post_logout_profile=$(curl -s -b $session_jar -w "\n%{http_code}" -X GET http://localhost:8081/me)
post_logout_status=$(echo "$post_logout_profile" | tail -n 1)
post_logout_body=$(echo "$post_logout_profile" | head -n -1)

if [ "$post_logout_status" = "401" ]; then
    echo "✓ Access denied after logout (401)"
else
    echo "✗ Access should be denied after logout, got $post_logout_status"
    echo "Body: $post_logout_body"
    exit 1
fi

rm -f $session_jar
echo "🎉 All tests passed!"
sleep 1
