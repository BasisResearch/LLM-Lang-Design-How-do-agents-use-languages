#!/bin/bash

echo "Starting test server in background..."
cargo run -- --port 3030 &
SERVER_PID=$!
sleep 3  # Give server some time to start

# Check that server actually started
if ! ps -p $SERVER_PID > /dev/null; then
    echo "FAILED: Server failed to start"
    exit 1
fi

# Variables
BASE_URL="http://localhost:3030"
COOKIE_FILE="/tmp/cookies.txt"

# Clean up function
cleanup() {
    kill $SERVER_PID 2>/dev/null
    rm -f $COOKIE_FILE
}
trap cleanup EXIT

echo "Running tests..."

# Clear cookies file
> $COOKIE_FILE

# Test 1: POST /register - Valid registration 
echo "Test 1: Register a new user"
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  $BASE_URL/register -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "201" ]]; then
    USER_ID=$(echo $BODY | jq -r '.id')
    USERNAME=$(echo $BODY | jq -r '.username')
    
    if [[ $USER_ID =~ ^[0-9]+$ ]] && [[ $USERNAME == "testuser" ]]; then
        echo "✓ Registration successful with id: $USER_ID"
    else
        echo "✗ Registration failed: Invalid response format"
        echo "Body: $BODY"
        exit 1  
    fi
else
    echo "✗ Registration failed: Expected 201, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 2: POST /register - Duplicate username
echo "Testing duplicate registration"
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  $BASE_URL/register -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "409" ]]; then
    ERROR=$(echo $BODY | jq -r '.error')
    if [[ $ERROR == "Username already exists" ]]; then
        echo "✓ Duplicate registration blocked correctly"
    else
        echo "✗ Incorrect error message"
        echo "Body: $BODY"
        exit 1
    fi
else
    echo "✗ Should have returned 409, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 3: POST /login - Valid credentials
echo "Test 3: Login with valid credentials"
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  $BASE_URL/login -c $COOKIE_FILE -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "200" ]]; then
    LOGIN_USER_ID=$(echo $BODY | jq -r '.id')
    LOGIN_USERNAME=$(echo $BODY | jq -r '.username')
    
    if [[ $LOGIN_USER_ID == "$USER_ID" ]] && [[ $LOGIN_USERNAME == "testuser" ]]; then
        echo "✓ Login successful"
    else
        echo "✗ Login failed: Incorrect user info"
        echo "Body: $BODY"
        exit 1
    fi
else
    echo "✗ Login failed: Expected 200, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 4: POST /login - Invalid credentials
echo "Test 4: Login with invalid credentials"
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpassword"}' \
  $BASE_URL/login -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "401" ]]; then
    ERROR=$(echo $BODY | jq -r '.error')
    if [[ $ERROR == "Invalid credentials" ]]; then
        echo "✓ Invalid credentials rejected"
    else
        echo "✗ Incorrect error message"
        echo "Body: $BODY"
        exit 1
    fi
else
    echo "✗ Should have returned 401, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 5: GET /me - Authenticated user
echo "Test 5: Get authenticated user info"
RESPONSE=$(curl -s -X GET \
  -b $COOKIE_FILE \
  $BASE_URL/me -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "200" ]]; then
    ME_USER_ID=$(echo $BODY | jq -r '.id')
    ME_USERNAME=$(echo $BODY | jq -r '.username')
    
    if [[ $ME_USER_ID == "$USER_ID" ]] && [[ $ME_USERNAME == "testuser" ]]; then
        echo "✓ Authenticated user info retrieved"
    else
        echo "✗ Wrong user info retrieved"
        echo "Expected ID: $USER_ID, Username: testuser"
        echo "Got ID: $ME_USER_ID, Username: $ME_USERNAME"
        exit 1
    fi
else
    echo "✗ GET /me failed: Expected 200, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 6: GET /me - Unauthenticated access
echo "Test 6: Get user info without auth"
RESPONSE=$(curl -s -X GET \
  $BASE_URL/me -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "401" ]]; then
    ERROR=$(echo $BODY | jq -r '.error')
    if [[ $ERROR == "Authentication required" ]]; then
        echo "✓ Unauthenticated access correctly rejected"
    else
        echo "✗ Incorrect error message"
        echo "Body: $BODY"
        exit 1
    fi
else
    echo "✗ Should have returned 401, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 7: PUT /password - Change password
echo "Test 7: Change password"
RESPONSE=$(curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword456"}' \
  -b $COOKIE_FILE \
  $BASE_URL/password -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "200" ]]; then
    echo "✓ Password changed successfully"
else
    echo "✗ Password change failed: Expected 200, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 8: PUT /password - Try to login with old password (should fail)
echo "Test 8: Try login with old password (should fail)"
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  $BASE_URL/login -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "401" ]]; then
    echo "✓ Old password correctly rejected"
else
    echo "✗ Old password should not work anymore"
    exit 1
fi

# Test 9: PUT /password - Try to login with new password (should work)
echo "Test 9: Try login with new password (should work)"
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newpassword456"}' \
  $BASE_URL/login -c $COOKIE_FILE -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "200" ]]; then
    echo "✓ New password accepted"
else
    echo "✗ New password should work, got $HTTP_CODE"
    exit 1
fi

# Test 10: PUT /password - Invalid old password
echo "Test 10: Attempt to change password with wrong old password"
RESPONSE=$(curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "wrongoldpassword", "new_password": "anotherpassword"}' \
  -b $COOKIE_FILE \
  $BASE_URL/password -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "401" ]]; then
    ERROR=$(echo $BODY | jq -r '.error')
    if [[ $ERROR == "Invalid credentials" ]]; then
        echo "✓ Wrong old password rejected"
    else
        echo "✗ Wrong error message"
        exit 1
    fi
else
    echo "✗ Should have returned 401, got $HTTP_CODE"
    exit 1
fi

# Test 11: POST /todos - Create a todo item
echo "Test 11: Create a todo item"
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "First Todo", "description": "This is my first todo"}' \
  -b $COOKIE_FILE \
  $BASE_URL/todos -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "201" ]]; then
    TODO_ID=$(echo $BODY | jq -r '.id')
    TITLE=$(echo $BODY | jq -r '.title')
    DESCRIPTION=$(echo $BODY | jq -r '.description')
    
    if [[ $TITLE == "First Todo" ]] && [[ $DESCRIPTION == "This is my first todo" ]]; then
        echo "✓ Todo created successfully with id: $TODO_ID"
    else
        echo "✗ Todo creation failed: Incorrect data"
        exit 1
    fi
else
    echo "✗ Todo creation failed: Expected 201, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 12: POST /todos - Create another todo item
echo "Test 12: Create another todo item"
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "Second Todo", "description": ""}' \
  -b $COOKIE_FILE \
  $BASE_URL/todos -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "201" ]]; then
    TODO2_ID=$(echo $BODY | jq -r '.id')
    TITLE2=$(echo $BODY | jq -r '.title')
    DESCRIPTION2=$(echo $BODY | jq -r '.description')
    
    if [[ $TITLE2 == "Second Todo" ]] && [[ $DESCRIPTION2 == "" ]]; then
        echo "✓ Second todo created successfully with id: $TODO2_ID"
    else
        echo "✗ Second todo creation failed: Incorrect data"
        exit 1
    fi
else
    echo "✗ Second todo creation failed: Expected 201, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 13: GET /todos - List all todos
echo "Test 13: Get all todos"
RESPONSE=$(curl -s -X GET \
  -b $COOKIE_FILE \
  $BASE_URL/todos -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "200" ]]; then
    COUNT=$(echo $BODY | jq 'length')
    if [[ $COUNT == "2" ]]; then
        FIRST_TITLE=$(echo $BODY | jq -r '.[0].title')
        if [[ $FIRST_TITLE == "First Todo" ]] || [[ $FIRST_TITLE == "Second Todo" ]]; then
            echo "✓ Todos retrieved successfully: $COUNT todos"
        else
            echo "✗ Unexpected todos in list"
            exit 1
        fi
    else
        echo "✗ Expected 2 todos, got $COUNT"
        exit 1
    fi
else
    echo "✗ GET /todos failed: Expected 200, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 14: GET /todos/:id - Get specific todo
echo "Test 14: Get specific todo"
RESPONSE=$(curl -s -X GET \
  -b $COOKIE_FILE \
  $BASE_URL/todos/$TODO_ID -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "200" ]]; then
    RETRIEVED_ID=$(echo $BODY | jq -r '.id')
    RETRIEVED_TITLE=$(echo $BODY | jq -r '.title')
    
    if [[ $RETRIEVED_ID == "$TODO_ID" ]] && [[ $RETRIEVED_TITLE == "First Todo" ]]; then
        echo "✓ Specific todo retrieved successfully"
    else
        echo "✗ Retrieved wrong todo"
        exit 1
    fi
else
    echo "✗ GET /todos/:id failed: Expected 200, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 15: PUT /todos/:id - Update todo
echo "Test 15: Update specific todo"
RESPONSE=$(curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title": "Updated First Todo", "completed": true}' \
  -b $COOKIE_FILE \
  $BASE_URL/todos/$TODO_ID -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "200" ]]; then
    UPDATED_TITLE=$(echo $BODY | jq -r '.title')
    COMPLETED=$(echo $BODY | jq -r '.completed')
    
    if [[ $UPDATED_TITLE == "Updated First Todo" ]] && [[ $COMPLETED == "true" ]]; then
        echo "✓ Todo updated successfully"
    else
        echo "✗ Todo update failed: Expected 'Updated First Todo' and 'true'"
        exit 1
    fi
else
    echo "✗ PUT /todos/:id failed: Expected 200, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 16: PUT /todos/:id - Try to update with empty title (should fail)
echo "Test 16: Try to update with empty title"
RESPONSE=$(curl -s -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title": ""}' \
  -b $COOKIE_FILE \
  $BASE_URL/todos/$TODO_ID -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "400" ]]; then
    ERROR=$(echo $BODY | jq -r '.error')
    if [[ $ERROR == "Title is required" ]]; then
        echo "✓ Empty title update correctly rejected"
    else
        echo "✗ Incorrect error message for empty title"
        exit 1
    fi
else
    echo "✗ Should have returned 400 for empty title, got $HTTP_CODE"
    exit 1
fi

# Test 17: POST /todos - Try to create with empty title (should fail)
echo "Test 17: Try to create with empty title"
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "", "description": "No title"}' \
  -b $COOKIE_FILE \
  $BASE_URL/todos -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "400" ]]; then
    ERROR=$(echo $BODY | jq -r '.error')
    if [[ $ERROR == "Title is required" ]]; then
        echo "✓ Empty title creation correctly rejected"
    else
        echo "✗ Incorrect error message for empty title on creation"
        exit 1
    fi
else
    echo "✗ Should have returned 400 for empty title on creation, got $HTTP_CODE"
    exit 1
fi

# Test 18: DELETE /todos/:id - Delete todo
echo "Test 18: Delete specific todo"
RESPONSE=$(curl -s -X DELETE \
  -b $COOKIE_FILE \
  $BASE_URL/todos/$TODO_ID -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"

if [[ $HTTP_CODE == "204" ]]; then
    echo "✓ Todo deleted successfully"
else
    echo "✗ DELETE /todos/:id failed: Expected 204, got $HTTP_CODE"
    exit 1
fi

# Test 19: GET /todos/:id - After deletion (should fail with 404)
echo "Test 19: Try to get deleted todo"
RESPONSE=$(curl -s -X GET \
  -b $COOKIE_FILE \
  $BASE_URL/todos/$TODO_ID -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "404" ]]; then
    ERROR=$(echo $BODY | jq -r '.error')
    if [[ $ERROR == "Todo not found" ]]; then
        echo "✓ Deleted todo correctly not found"
    else
        echo "✗ Incorrect error message for deleted todo"
        exit 1
    fi
else
    echo "✗ Should have returned 404 for deleted todo, got $HTTP_CODE"
    exit 1
fi

# Test 20: POST /logout
echo "Test 20: Logout"
RESPONSE=$(curl -s -X POST \
  -b $COOKIE_FILE \
  $BASE_URL/logout -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "200" ]]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed: Expected 200, got $HTTP_CODE"
    echo "Body: $BODY"
    exit 1
fi

# Test 21: Try accessing todos after logout (should fail with 401)
echo "Test 21: Access protected resource after logout"
RESPONSE=$(curl -s -X GET \
  -b $COOKIE_FILE \
  $BASE_URL/todos -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
BODY="${RESPONSE%???}"

if [[ $HTTP_CODE == "401" ]]; then
    ERROR=$(echo $BODY | jq -r '.error')
    if [[ $ERROR == "Authentication required" ]]; then
        echo "✓ Auth token properly invalidated after logout"
    else
        echo "✗ Incorrect error message after logout"
        exit 1
    fi
else
    echo "✗ Should have returned 401 after logout, got $HTTP_CODE"
    exit 1
fi

echo "All tests passed! ✓"

# Kill the server explicitly
kill $SERVER_PID 2>/dev/null