#!/bin/bash

# Test script to verify the Todo App server works correctly
# Assumes server is running on port 3000

PORT=${1:-3000}
SERVER="http://localhost:$PORT"
COOKIE_FILE="/tmp/todo_test_cookies.txt"

echo "Testing Todo Server on $SERVER"

# Clean up on exit
trap 'rm -f $COOKIE_FILE' EXIT

# Helper function to send requests with cookies
api_call() {
    local method=$1
    local endpoint=$2
    local data=$3
    local expect_error=$4

    if [ -n "$data" ]; then
        if [ "$method" = "GET" ]; then
            response=$(curl -s -c $COOKIE_FILE -b $COOKIE_FILE -X $method "$SERVER$endpoint" -H "Content-Type: application/json")
        else
            response=$(curl -s -c $COOKIE_FILE -b $COOKIE_FILE -X $method "$SERVER$endpoint" -d "$data" -H "Content-Type: application/json")
        fi
    else
        response=$(curl -s -c $COOKIE_FILE -b $COOKIE_FILE -X $method "$SERVER$endpoint" -H "Content-Type: application/json")
    fi
    
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -c $COOKIE_FILE -b $COOKIE_FILE -X $method "$SERVER$endpoint" -d "$data" -H "Content-Type: application/json")

    if [ "$expect_error" = "true" ]; then
        echo "  Status: $status_code, Response: $response"
    else
        echo "  Status: $status_code, Response: $response"
        # Check if Content-Type is application/json for non-DELETE endpoints
        if [[ "$method" != "DELETE" && "$endpoint" != *"logout"* ]] && [ "$status_code" != "204" ]; then
            content_type=$(curl -s -I -c $COOKIE_FILE -b $COOKIE_FILE -X $method "$SERVER$endpoint" -d "$data" -H "Content-Type: application/json" | grep -i "content-type" | grep -i "application/json" | wc -l)
            if [ "$content_type" -eq 0 ] && [ "$status_code" -ne 301 ] && [ "$status_code" -ne 302 ]; then
                echo "  WARNING: Missing Content-Type: application/json header"
            fi
        fi
    fi

    return $status_code
}

echo
echo "=== 1. Testing POST /register ==="
echo "- Valid registration:"
api_call POST "/register" '{"username": "testuser", "password": "password123"}'

echo
echo "- Already existing user:"
api_call POST "/register" '{"username": "testuser", "password": "password123"}' "true"

echo
echo "- Invalid username (too short):"
api_call POST "/register" '{"username": "ab", "password": "password123"}' "true"

echo
echo "- Invalid username (invalid characters):"
api_call POST "/register" '{"username": "test@user", "password": "password123"}' "true"

echo
echo "- Password too short:"
api_call POST "/register" '{"username": "testuser2", "password": "pass"}' "true"

echo
echo "=== 2. Testing POST /login ==="
echo "- Login with registered user:"
api_call POST "/login" '{"username": "testuser", "password": "password123"}'

echo
echo "- Login with wrong password:"
api_call POST "/login" '{"username": "testuser", "password": "wrongpassword"}' "true"

echo
echo "- Login with non-existent user:"
api_call POST "/login" '{"username": "nonexistent", "password": "password123"}' "true"

echo
echo "=== 3. Testing GET /me (requires authentication) ==="
echo "- Without authentication:"
api_call GET "/me" "" "true"

echo
echo "- After login (should work):"
api_call POST "/login" '{"username": "testuser", "password": "password123"}'
api_call GET "/me" ""

echo
echo "=== 4. Testing PUT /password ==="
echo "- Without authentication (change password):"
curl -b "" -c $COOKIE_FILE -X PUT "$SERVER/password" -d '{"old_password": "password123", "new_password": "newpassword123"}' -H "Content-Type: application/json" -w "\nStatus: %{http_code}\n" -s -o /dev/null
curl -s -X GET "$SERVER/me" -b $COOKIE_FILE -H "Content-Type: application/json"

echo
echo "- With authentication but wrong old password:"
api_call PUT "/password" '{"old_password": "wrongoldpassword", "new_password": "newpassword123"}' "true"

echo
echo "- Change password successfully:"
api_call PUT "/password" '{"old_password": "password123", "new_password": "newpassword123"}'

echo
echo "=== 5. Testing logout and re-login ==="
api_call POST "/logout" ""
echo "- After logout, calling /me (should fail):"
api_call GET "/me" "" "true"

echo
echo "- Login with new password:"
api_call POST "/login" '{"username": "testuser", "password": "newpassword123"}'
api_call GET "/me" ""

echo
echo "=== 6. Testing /todos endpoints ==="
echo "- First user operations (create and list todos):"
api_call POST "/todos" '{"title": "First Todo", "description": "My first task"}'
api_call POST "/todos" '{"title": "Second Todo", "description": "My second task"}'
api_call GET "/todos"

echo
echo "- Testing GET /todos/:id:"
api_call GET "/todos/1"
api_call GET "/todos/999" "true"  # Non-existent todo

echo
echo "- Testing PUT /todos/:id (update todo):"
api_call PUT "/todos/1" '{"title": "Updated First Todo", "completed": true}'
api_call GET "/todos/1"

echo
echo "- Test partial updates (only update description):"
api_call PUT "/todos/1" '{"description": "Updated description only"}'
api_call GET "/todos/1"

echo
echo "- Test validation (empty title):"
api_call PUT "/todos/1" '{"title": ""}' "true"

echo
echo "- Testing DELETE /todos/:id:"
api_call DELETE "/todos/1"
echo "  Status: 204 (No content expected)"

echo
echo "- Verify deletion:"
api_call GET "/todos/1" "" "true"

# Register a second user to test user isolation
echo
echo "=== 7. User isolation tests ==="
api_call POST "/register" '{"username": "testuser2", "password": "password123"}'
api_call POST "/login" '{"username": "testuser2", "password": "password123"}'
api_call POST "/todos" '{"title": "Test Todo for User 2", "description": "Should not be visible to user 1"}'
api_call GET "/me"

# Switch back to user1 and make sure they can't see user2's todo
echo
echo "- Logging back in as user1 (ID 1), check they cannot access user2's todo (ID 2 created by user2):"
api_call POST "/login" '{"username": "testuser", "password": "newpassword123"}'

# Since we deleted todo with ID 1, user1 has only todo with ID 2 (originally), 
# but now user 2 also created a todo with a higher ID. 
# We can still test that user1 can't access user2's original todo.

echo "- Get user1's todos (should only show user1's todos, not user2's):"
api_call GET "/todos"
echo "- Try to access what was originally user2's todo (now has different ID if accessed):"
api_call GET "/todos/2" "" "true"  # Won't work if user2's ID 2 is different

# Let's create a second todo for user1 to make comparison clearer
api_call POST "/todos" '{"title": "User 1 Todo 2", "description": "Owned by user 1"}'

echo "- Now verify user1 can access their own todos:"
api_call GET "/todos/2"  "" # Should exist as user1's todo

echo
echo "=== 8. Testing DELETE with user isolation ==="
api_call POST "/login" '{"username": "testuser2", "password": "password123"}'
user2_todos_response=$(curl -s -c $COOKIE_FILE -b $COOKIE_FILE -X GET "$SERVER/todos" -H "Content-Type: application/json")
user2_todo_id=$(echo "$user2_todos_response" | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)

if [ -n "$user2_todo_id" ]; then
    api_call POST "/login" '{"username": "testuser", "password": "newpassword123"}'
    echo "- User1 trying to delete user2's todo with ID $user2_todo_id (should fail):"
    api_call DELETE "/todos/$user2_todo_id" "" "true"
    
    echo "- Verify user2's todo still exists (login as user2):"
    api_call POST "/login" '{"username": "testuser2", "password": "password123"}'
    curl -s -c $COOKIE_FILE -b $COOKIE_FILE -X GET "$SERVER/todos" -H "Content-Type: application/json"
fi

echo
echo "=== All tests completed ==="