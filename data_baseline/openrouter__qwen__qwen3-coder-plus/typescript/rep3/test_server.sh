#!/bin/bash

# Test script for Todo App API
PORT=8080
BASE_URL="http://localhost:$PORT"

echo "Testing Todo App Server at $BASE_URL"

# Start the server in background
./run.sh --port $PORT &
SERVER_PID=$!
sleep 2  # Allow time for server to start

set +e  # Don't exit on errors during tests

# Global variables to store test results
TEST_PASSED=0
TEST_FAILED=0

function run_test() {
    local test_name=$1
    local expected_status=$2
    local command=$3
    local expected_response_contains=$4
    
    echo -n "Test: $test_name - "
    
    # Execute curl and capture response 
    response=$(eval $command 2>/dev/null)
    status_code=$(curl -o /dev/null -w "%{http_code}" -s -X GET $BASE_URL/todos 2>/dev/null || echo "500")
    
    if [ $? -eq 0 ] && [ $(echo "$response" | grep -c "$expected_response_contains") -gt 0 ]; then
        echo "PASS"
        ((TEST_PASSED++))
    else
        echo "FAIL - Expected to find '$expected_response_contains' in response: $response"
        ((TEST_FAILED++))
    fi
}

{
    # Test 1: Register a new user
    echo "POST /register with valid credentials"
    response=$(curl -s -X POST -H "Content-Type: application/json" \
           -d '{"username":"testuser","password":"password123"}' \
           $BASE_URL/register)
    echo $response
    if echo $response | grep -q '"id":1'; then
        echo "Register test PASSED"
    else
        echo "Register test FAILED: $response"
    fi

    # Test 2: Register with invalid username length
    echo "POST /register with short username"
    response=$(curl -s -X POST -H "Content-Type: application/json" \
           -d '{"username":"ab","password":"password123"}' \
           $BASE_URL/register)
    echo $response
    if echo $response | grep -q '"error":"Invalid username"'; then
        echo "Short username validation PASSED"
    else
        echo "Short username validation FAILED: $response"
    fi

    # Test 3: Register with invalid character in username
    echo "POST /register with invalid characters in username"
    response=$(curl -s -X POST -H "Content-Type: application/json" \
           -d '{"username":"invalid-user$","password":"password123"}' \
           $BASE_URL/register)
    echo $response
    if echo $response | grep -q '"error":"Invalid username"'; then
        echo "Invalid username validation PASSED"
    else
        echo "Invalid username validation FAILED: $response"
    fi

    # Test 4: Register with short password
    echo "POST /register with short password"
    response=$(curl -s -X POST -H "Content-Type: application/json" \
           -d '{"username":"validuser","password":"pass"}' \
           $BASE_URL/register)
    echo $response
    if echo $response | grep -q '"error":"Password too short"'; then
        echo "Short password validation PASSED"
    else
        echo "Short password validation FAILED: $response"
    fi

    # Test 5: Register same user again (should fail)
    echo "POST /register with duplicate username"
    response=$(curl -s -X POST -H "Content-Type: application/json" \
           -d '{"username":"testuser","password":"password123"}' \
           $BASE_URL/register)
    echo $response
    if echo $response | grep -q '"error":"Username already exists"'; then
        echo "Duplicate username validation PASSED"
    else
        echo "Duplicate username validation FAILED: $response"
    fi

    # Test 6: Login with valid credentials
    echo "POST /login with valid credentials"
    response=$(curl -c cookies.txt -s -X POST -H "Content-Type: application/json" \
           -d '{"username":"testuser","password":"password123"}' \
           $BASE_URL/login)
    echo $response
    if echo $response | grep -q '"id":1'; then
        echo "Login test PASSED"
    else
        echo "Login test FAILED: $response"
    fi

    # Test 7: Login with invalid creds
    echo "POST /login with invalid credentials"
    response=$(curl -s -X POST -H "Content-Type: application/json" \
           -d '{"username":"testuser","password":"wrongpassword"}' \
           $BASE_URL/login)
    echo $response
    if echo $response | grep -q '"error":"Invalid credentials"'; then
        echo "Invalid login validation PASSED"
    else
        echo "Invalid login validation FAILED: $response"
    fi

    # Save session cookie for further tests
    login_response=$(curl -c cookies.txt -s -X POST -H "Content-Type: application/json" \
                   -d '{"username":"testuser","password":"password123"}' \
                   $BASE_URL/login)

    # Test 8: Get user profile
    echo "GET /me with valid session"
    response=$(curl -b cookies.txt -s -X GET $BASE_URL/me)
    echo $response
    if echo $response | grep -q '"username":"testuser"'; then
        echo "/me test PASSED"
    else
        echo "/me test FAILED: $response"
    fi

    # Test 9: Get todos (should be empty)
    echo "GET /todos initially empty"
    response=$(curl -b cookies.txt -s -X GET $BASE_URL/todos)
    echo $response
    if echo $response | grep -q '\[\]'; then
        echo "Empty todos list test PASSED"
    else
        echo "Empty todos list test FAILED: $response"
    fi

    # Test 10: Unauthorized access to protected routes
    echo "GET /todos without auth"
    response=$(curl -s -X GET $BASE_URL/todos)
    echo $response
    if echo $response | grep -q '"error":"Authentication required"'; then
        echo "Unauth access to protected route test PASSED"
    else
        echo "Unauth access validation FAILED: $response"
    fi

    # Test 11: Create a todo
    echo "POST /todos to create new todo"
    response=$(curl -b cookies.txt -s -X POST -H "Content-Type: application/json" \
           -d '{"title":"First todo","description":"Testing description"}' \
           $BASE_URL/todos)
    echo $response
    if echo $response | grep -q '"title":"First todo"'; then
        echo "Create todo test PASSED"
    else
        echo "Create todo test FAILED: $response"
    fi

    # Test 12: Create todo with empty title (should fail)
    echo "POST /todos with empty title"
    response=$(curl -b cookies.txt -s -X POST -H "Content-Type: application/json" \
           -d '{"title":"","description":"Testing"}' \
           $BASE_URL/todos)
    echo $response
    if echo $response | grep -q '"error":"Title is required"'; then
        echo "Empty title validation test PASSED"
    else
        echo "Empty title validation test FAILED: $response"
    fi

    # Test 13: Get todos after creation (should have one item)
    echo "GET /todos after creating one item"
    response=$(curl -b cookies.txt -s -X GET $BASE_URL/todos)
    echo $response
    if echo $response | grep -c '"title":"First todo"' | grep -q '1'; then
        echo "Get todos after creation test PASSED"
    else
        echo "Get todos after creation test FAILED: $response"
    fi

    # Test 14: Get specific todo by ID
    TODO_ID=$(echo $response | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
    echo "GET /todos/$TODO_ID for existing todo"
    response=$(curl -b cookies.txt -s -X GET $BASE_URL/todos/$TODO_ID)
    echo $response
    if echo $response | grep -q '"id":'"$TODO_ID"'; then
        echo "Get single todo test PASSED"
    else
        echo "Get single todo test FAILED: $response"
    fi

    # Test 15: Get non-existent todo
    echo "GET /todos/999 for non-existent todo"
    response=$(curl -b cookies.txt -s -X GET $BASE_URL/todos/999)
    echo $response
    if echo $response | grep -q '"error":"Todo not found"'; then
        echo "Non-existent todo access test PASSED"
    else
        echo "Non-existent todo access test FAILED: $response"
    fi

    # Test 16: Update todo partially
    echo "PUT /todos/$TODO_ID partially updating todo"
    response=$(curl -b cookies.txt -s -X PUT -H "Content-Type: application/json" \
           -d '{"completed":true}' $BASE_URL/todos/$TODO_ID)
    echo $response
    if echo $response | grep -q '"completed":true'; then
        echo "Partial update test PASSED"
    else
        echo "Partial update test FAILED: $response"
    fi

    # Test 17: Try to update with empty title (validation)
    echo "PUT /todos/$TODO_ID with empty title validation"
    response=$(curl -b cookies.txt -s -X PUT -H "Content-Type: application/json" \
           -d '{"title":""}' $BASE_URL/todos/$TODO_ID)
    echo $response
    if echo $response | grep -q '"error":"Title is required"'; then
        echo "Update empty title validation test PASSED"
    else
        echo "Update empty title validation test FAILED: $response"
    fi

    # Test 18: Delete todo
    echo "DELETE /todos/$TODO_ID existing todo"
    status=$(curl -b cookies.txt -s -o /dev/null -w "%{http_code}" -X DELETE $BASE_URL/todos/$TODO_ID)
    echo "Status: $status"
    if [ "$status" = "204" ]; then
        echo "Delete todo test PASSED"
    else
        echo "Delete todo test FAILED: Status was $status"
    fi

    # Test 19: Try to delete already deleted todo
    echo "DELETE /todos/$TODO_ID deleted todo"
    status=$(curl -b cookies.txt -s -o /dev/null -w "%{http_code}" -X DELETE $BASE_URL/todos/$TODO_ID)
    echo "Status: $status"
    if [ "$status" = "404" ]; then
        echo "Delete nonexistent todo test PASSED"
    else
        echo "Delete nonexistent todo test FAILED: Status was $status"
    fi

    # Test 20: Change password
    echo "PUT /password with valid old and new passwords"
    response=$(curl -b cookies.txt -s -X PUT -H "Content-Type: application/json" \
           -d '{"old_password":"password123","new_password":"newpassword456"}' \
           $BASE_URL/password)
    echo "Response: $response"
    # Should be empty response with 200 status
    status=$(curl -b cookies.txt -s -o /dev/null -w "%{http_code}" \
           -X PUT -H "Content-Type: application/json" \
           -d '{"old_password":"password123","new_password":"newpassword456"}' \
           $BASE_URL/password)
    if [ "$status" = "200" ]; then
        echo "Change password test PASSED"
    else
        echo "Change password test FAILED: Status $status, Response: $response"
    fi
    
    # Test 21: Try to change password with wrong old password
    echo "PUT /password with wrong old password"
    status=$(curl -b cookies.txt -s -o /dev/null -w "%{http_code}" \
           -X PUT -H "Content-Type: application/json" \
           -d '{"old_password":"wrongpassword","new_password":"anotherpassword"}' \
           $BASE_URL/password)
    echo "Status: $status"
    if [ "$status" = "401" ]; then
        echo "Wrong old password validation test PASSED"
    else
        echo "Wrong old password validation test FAILED: Status was $status"
    fi
    
    # Test 22: Logout and verify session invalidation
    echo "POST /logout and verify session invalidation"
    response=$(curl -b cookies.txt -s -X POST $BASE_URL/logout)
    echo $response
    if echo $response | grep -q '{}'; then
        echo "Logout test PASSED"
    else
        echo "Logout test FAILED: $response"
    fi
    
    # After logout, try getting profile again
    status_after_logout=$(curl -b cookies.txt -s -o /dev/null -w "%{http_code}" -X GET $BASE_URL/me)
    if [ "$status_after_logout" = "401" ]; then
        echo "Session invalidation test PASSED"
    else
        echo "Session invalidation test FAILED: Status was $status_after_logout"
    fi
} > test_results.txt

# Kill the server process 
kill $SERVER_PID 2>/dev/null

echo "Tests completed!"
cat test_results.txt