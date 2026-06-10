#!/bin/bash

# Test script for Todo API server
SERVER_URL="http://localhost:8080"
TEST_PORT=8088

# Start the server in the background
echo "Starting server on port $TEST_PORT..." 
./run.sh --port $TEST_PORT &
SERVER_PID=$!
sleep 3  # Give the server time to start

# Cleanup function
cleanup() {
    echo "Stopping server..."
    kill $SERVER_PID 2>/dev/null
}

# Set trap to ensure cleanup happens
trap cleanup EXIT

# Test functions
test_register() {
    echo "Testing POST /register..."
  
    # Valid registration
    response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -d '{"username":"testuser","password":"secret123"}' \
        "$SERVER_URL:$TEST_PORT/register")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 201 ]; then
        echo "✓ Registration successful (Status: $status_code)"
        test_user_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
        echo "  New user ID: $test_user_id"
    else
        echo "✗ Registration failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # Try to register duplicate username
    response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -d '{"username":"testuser","password":"secret123"}' \
        "$SERVER_URL:$TEST_PORT/register")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 409 ]; then
        echo "✓ Duplicate username handled correctly (Status: $status_code)"
    else
        echo "✗ Duplicate username not handled correctly (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
}

test_login() {
    echo "Testing POST /login..."
    
    # Successful login
    response=$(curl -s -c cookies.txt -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -d '{"username":"testuser","password":"secret123"}' \
        "$SERVER_URL:$TEST_PORT/login")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 200 ]; then
        echo "✓ Login successful (Status: $status_code)"
        logged_in_user_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
        echo "  Logged in as user ID: $logged_in_user_id"
    else
        echo "✗ Login failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # Failed login
    response=$(curl -s -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -d '{"username":"testuser","password":"wrongpass"}' \
        "$SERVER_URL:$TEST_PORT/login")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 401 ]; then
        echo "✓ Failed login handled correctly (Status: $status_code)"
    else
        echo "✗ Failed login not handled correctly (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
}

test_me() {
    echo "Testing GET /me..."
    
    # Access /me with valid session
    response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X GET \
        "$SERVER_URL:$TEST_PORT/me")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 200 ]; then
        echo "✓ GET /me successful (Status: $status_code)"
        retrieved_userid=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
        if [ "$retrieved_userid" = "$logged_in_user_id" ]; then
            echo "  Correct user ID returned"
        else
            echo "  Incorrect user ID returned"
            cleanup
            exit 1
        fi
    else
        echo "✗ GET /me failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # Access /me without valid session
    response=$(curl -s -w "\n%{http_code}" -X GET \
        "$SERVER_URL:$TEST_PORT/me")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 401 ]; then
        echo "✓ Access without session handled correctly (Status: $status_code)"
    else
        echo "✗ Access without session not handled correctly (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
}

test_password_change() {
    echo "Testing PUT /password..."
    
    # Change password with valid credentials
    response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" \
        -d '{"old_password":"secret123","new_password":"newpassword123"}' \
        "$SERVER_URL:$TEST_PORT/password")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 200 ]; then
        echo "✓ Password change successful (Status: $status_code)"
    else
        echo "✗ Password change failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # Try to change password with wrong old password
    response=$(curl -s -b cookies.txt -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" \
        -d '{"old_password":"wrongpassword","new_password":"anotherpassword"}' \
        "$SERVER_URL:$TEST_PORT/password")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 401 ]; then
        echo "✓ Invalid old password handled correctly (Status: $status_code)"
    else
        echo "✗ Invalid old password not handled correctly (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # Login with new password to confirm change worked
    response=$(curl -s -c cookies_new.txt -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -d '{"username":"testuser","password":"newpassword123"}' \
        "$SERVER_URL:$TEST_PORT/login")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 200 ]; then
        echo "✓ New password works correctly (Status: $status_code)"
    else
        echo "✗ New password doesn't work (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
}

test_todos_crud() {
    echo "Testing CRUD operations on /todos..."
    
    # CREATE: Add a todo
    response=$(curl -s -b cookies_new.txt -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -d '{"title":"First todo","description":"My first task"}' \
        "$SERVER_URL:$TEST_PORT/todos")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 201 ]; then
        echo "✓ Todo creation successful (Status: $status_code)"
        todo_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
        created_at=$(echo "$body" | grep -o '"created_at":"[^"]*"' | cut -d'"' -f4)
        echo "  New todo ID: $todo_id"
        echo "  Created at: $created_at"
    else
        echo "✗ Todo creation failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # CREATE: Add another todo
    response=$(curl -s -b cookies_new.txt -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -d '{"title":"Second todo","description":"Another task"}' \
        "$SERVER_URL:$TEST_PORT/todos")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 201 ]; then
        echo "✓ Second todo creation successful (Status: $status_code)"
        second_todo_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
        echo "  Second todo ID: $second_todo_id"
    else
        echo "✗ Second todo creation failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # READ (ALL): Get all todos
    response=$(curl -s -b cookies_new.txt -w "\n%{http_code}" -X GET \
        "$SERVER_URL:$TEST_PORT/todos")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 200 ]; then
        echo "✓ Get all todos successful (Status: $status_code)"
        todo_count=$(echo "$body" | jq 'length')
        if [ "$todo_count" -ge 2 ]; then
            echo "  Correct number of todos returned ($todo_count)"
        else
            echo "  Wrong number of todos returned ($todo_count)"
            cleanup
            exit 1
        fi
    else
        echo "✗ Get all todos failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # READ (ONE): Get specific todo
    response=$(curl -s -b cookies_new.txt -w "\n%{http_code}" -X GET \
        "$SERVER_URL:$TEST_PORT/todos/$todo_id")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 200 ]; then
        echo "✓ Get specific todo successful (Status: $status_code)"
        returned_id=$(echo "$body" | grep -o '"id":[0-9]*' | cut -d: -f2)
        if [ "$returned_id" = "$todo_id" ]; then
            echo "  Correct todo returned"
        else
            echo "  Wrong todo returned"
            cleanup
            exit 1
        fi
    else
        echo "✗ Get specific todo failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # UPDATE: Update the todo
    response=$(curl -s -b cookies_new.txt -w "\n%{http_code}" -X PUT -H "Content-Type: application/json" \
        -d '{"title":"Updated todo","completed":true}' \
        "$SERVER_URL:$TEST_PORT/todos/$todo_id")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 200 ]; then
        echo "✓ Todo update successful (Status: $status_code)"
        updated_completed=$(echo "$body" | grep -o '"completed":true' | cut -d':' -f2)
        if [ "$updated_completed" = "true" ]; then
            echo "  Todo was marked as completed"
        else
            echo "  Todo was not updated correctly"
            cleanup
            exit 1
        fi
        updated_title=$(echo "$body" | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
        if [ "$updated_title" = "Updated todo" ]; then
            echo "  Title was updated"
        else
            echo "  Title was not updated"
            echo "  Expected: Updated todo"
            echo "  Got: $updated_title"
            cleanup
            exit 1
        fi
        new_updated_at=$(echo "$body" | grep -o '"updated_at":"[^"]*"' | cut -d'"' -f4)
        updated_created_at=$(echo "$body" | grep -o '"created_at":"[^"]*"' | cut -d'"' -f4)
        if [ "$new_updated_at" != "$updated_created_at" ]; then
           echo "  Updated_at field changed (shows partial updates work)"
        else
           echo "  Warning: updated_at may not have changed"
        fi
    else
        echo "✗ Todo update failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # DELETE: Delete a todo
    response=$(curl -s -b cookies_new.txt -w "\n%{http_code}" -X DELETE \
        "$SERVER_URL:$TEST_PORT/todos/$todo_id")
    status_code=$(echo "$response" | tail -n1)
    
    if [ "$status_code" -eq 204 ]; then
        echo "✓ Todo deletion successful (Status: $status_code)"
    else
        echo "✗ Todo deletion failed (Status: $status_code)"
        echo "  Response: $response"
        cleanup
        exit 1
    fi
    
    # Verify deleted todo cannot be accessed
    response=$(curl -s -b cookies_new.txt -w "\n%{http_code}" -X GET \
        "$SERVER_URL:$TEST_PORT/todos/$todo_id")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 404 ]; then
        echo "✓ Deleted todo properly inaccessible (Status: $status_code)"
    else
        echo "✗ Deleted todo still accessible (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
}

test_logout() {
    echo "Testing POST /logout..."
    
    # Perform logout
    response=$(curl -s -b cookies_new.txt -w "\n%{http_code}" -X POST \
        "$SERVER_URL:$TEST_PORT/logout")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 200 ]; then
        echo "✓ Logout successful (Status: $status_code)"
    else
        echo "✗ Logout failed (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
    
    # Verify access to protected resources fails after logout
    response=$(curl -s -b cookies_new.txt -w "\n%{http_code}" -X GET \
        "$SERVER_URL:$TEST_PORT/me")
    status_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')
    
    if [ "$status_code" -eq 401 ]; then
        echo "✓ Authenticated resource access after logout blocked correctly (Status: $status_code)"
    else
        echo "✗ Authenticated resource access after logout not blocked correctly (Status: $status_code)"
        echo "  Response: $body"
        cleanup
        exit 1
    fi
}

# Run tests
echo "========================="
echo "Running API Tests"
echo "========================="

test_register
test_login 
test_me
test_password_change
test_todos_crud
test_logout

echo "========================="
echo "All tests passed! ✓"
echo "========================="

# Kill the server process just in case (trap handles it but let's be safe)
kill $SERVER_PID 2>/dev/null