#!/bin/bash

# A simple script to test the server API endpoints using curl

# Configuration
PORT=${TEST_PORT:-8765}
BASE_URL="http://localhost:$PORT"

echo "Testing server endpoints..."
echo "Base URL: $BASE_URL"

# Step 1: Test Register endpoint
echo -e "\n=== Testing POST /register ==="
RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "securepassword"}' \
    "$BASE_URL/register" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "201" ]; then
    USER_ID=$(echo "$JSON_DATA" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "✓ Registration successful, user ID: $USER_ID"
else
    echo "✗ Registration failed, status: $HTTP_CODE, response: $JSON_DATA"
    exit 1
fi

# Test validation: short password
RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "baduser", "password": "123"}' \
    "$BASE_URL/register" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "400" ] && [[ "$JSON_DATA" == *"Password too short"* ]]; then
    echo "✓ Password validation works"
else
    echo "✗ Password validation failed: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Test validation: duplicate username
RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "differentpassword"}' \
    "$BASE_URL/register" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "409" ] && [[ "$JSON_DATA" == *"Username already exists"* ]]; then
    echo "✓ Username uniqueness validation works"
else
    echo "✗ Username uniqueness validation failed: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Step 2: Test Login
echo -e "\n=== Testing POST /login ==="
RESPONSE=$(curl -s -c cookies.txt -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "securepassword"}' \
    "$BASE_URL/login" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ]; then
    LOGIN_USER_ID=$(echo "$JSON_DATA" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    if [ "$LOGIN_USER_ID" = "$USER_ID" ]; then
        echo "✓ Login successful"
    else
        echo "✗ Login returned wrong user ID"
        exit 1
    fi
else
    echo "✗ Login failed, status: $HTTP_CODE, response: $JSON_DATA"
    exit 1
fi

# Step 3: Test protected endpoint without auth
echo -e "\n=== Testing Auth Protection ==="
RESPONSE=$(curl -s -X GET \
    "$BASE_URL/me" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "401" ] && [[ "$JSON_DATA" == *"Authentication required"* ]]; then
    echo "✓ Auth protection works"
else
    echo "✗ Auth protection failed: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Step 4: Test protected endpoint with auth
echo -e "\n=== Testing GET /me ==="
RESPONSE=$(curl -s -b cookies.txt -X GET \
    "$BASE_URL/me" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ] && [[ "$JSON_DATA" == *"$USER_ID"* ]]; then
    echo "✓ GET /me works: $JSON_DATA"
else
    echo "✗ GET /me failed, status: $HTTP_CODE, response: $JSON_DATA"
    exit 1
fi

# Step 5: Test Todos
echo -e "\n=== Testing Todos ==="

# Get empty todo list
RESPONSE=$(curl -s -b cookies.txt -X GET \
    "$BASE_URL/todos" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ] && [ "$JSON_DATA" = "[]" ]; then
    echo "✓ Empty todos list works"
else
    echo "✗ Empty todos list failed: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Create todo
RESPONSE=$(curl -s -b cookies.txt -X POST \
    -H "Content-Type: application/json" \
    -d '{"title": "First Todo", "description": "My first task"}' \
    "$BASE_URL/todos" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "201" ] && [[ "$JSON_DATA" == *"First Todo"* ]]; then
    TODO_ID=$(echo "$JSON_DATA" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    CREATED_AT=$(echo "$JSON_DATA" | grep -o '"created_at":"[^"]*"' | cut -d'"' -f4)
    echo "✓ Created todo ID: $TODO_ID, created: $CREATED_AT"
else
    echo "✗ Create todo failed, status: $HTTP_CODE, response: $JSON_DATA"
    exit 1
fi

# Test missing title
RESPONSE=$(curl -s -b cookies.txt -X POST \
    -H "Content-Type: application/json" \
    -d '{"description": "No title"}' \
    "$BASE_URL/todos" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "400" ] && [[ "$JSON_DATA" == *"Title is required"* ]]; then
    echo "✓ Title validation works in POST"
else
    echo "✗ Title validation in POST failed: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Get single todo
RESPONSE=$(curl -s -b cookies.txt -X GET \
    "$BASE_URL/todos/$TODO_ID" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ] && [[ "$JSON_DATA" == *"$TODO_ID"* ]]; then
    echo "✓ GET single todo works"
else
    echo "✗ GET single todo failed, status: $HTTP_CODE, response: $JSON_DATA"
    exit 1
fi

# Test 404 for non-existent todo
RESPONSE=$(curl -s -b cookies.txt -X GET \
    "$BASE_URL/todos/99999" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "404" ]; then
    echo "✓ Non-existent todo returns 404"
else
    echo "✗ Non-existent todo failed: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Update todo
RESPONSE=$(curl -s -b cookies.txt -X PUT \
    -H "Content-Type: application/json" \
    -d '{"title": "Updated Todo", "completed": true}' \
    "$BASE_URL/todos/$TODO_ID" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "200" ] && [[ "$JSON_DATA" == *"Updated Todo"* ]] && [[ "$JSON_DATA" == *"true"* ]]; then
    echo "✓ PUT todo works"
else
    echo "✗ PUT todo failed, status: $HTTP_CODE, response: $JSON_DATA"
    exit 1
fi

# Test title required validation during update
RESPONSE=$(curl -s -b cookies.txt -X PUT \
    -H "Content-Type: application/json" \
    -d '{"title": "", "completed": false}' \
    "$BASE_URL/todos/$TODO_ID" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "400" ] && [[ "$JSON_DATA" == *"Title is required"* ]]; then
    echo "✓ Title validation works in PUT"
else
    echo "✗ Title validation in PUT failed: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Delete todo
RESPONSE=$(curl -s -b cookies.txt -X DELETE \
    "$BASE_URL/todos/$TODO_ID" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)

if [ "$HTTP_CODE" = "204" ]; then
    echo "✓ DELETE todo works"
else
    echo "✗ DELETE todo failed, status: $HTTP_CODE"
    exit 1
fi

# Verify deletion
RESPONSE=$(curl -s -b cookies.txt -X GET \
    "$BASE_URL/todos/$TODO_ID" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "404" ]; then
    echo "✓ Todo permanently deleted"
else
    echo "✗ Todo still exists after deletion: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Step 6: Test password change
echo -e "\n=== Testing Password Change ==="

# Valid password change
RESPONSE=$(curl -s -b cookies.txt -X PUT \
    -H "Content-Type: application/json" \
    -d '{"old_password": "securepassword", "new_password": "newsecurepassword"}' \
    "$BASE_URL/password" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Password change works"
else
    echo "✗ Password change failed, status: $HTTP_CODE, response: $JSON_DATA"
    exit 1
fi

# Test new password can't log in with old one
RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "securepassword"}' \
    "$BASE_URL/login" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "401" ]; then
    echo "✓ Old password is no longer valid"
else
    echo "✗ Old password still works: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Log in with new password
RESPONSE=$(curl -s -c new_cookies.txt -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "newsecurepassword"}' \
    "$BASE_URL/login" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ New password works for login"
else
    echo "✗ New password failed for login: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Step 7: Test logout
echo -e "\n=== Testing Logout ==="

RESPONSE=$(curl -s -b new_cookies.txt -X POST \
    "$BASE_URL/logout" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Logout works"
else
    echo "✗ Logout failed, status: $HTTP_CODE, response: $JSON_DATA"
    exit 1
fi

# Test that session is invalidated after logout
RESPONSE=$(curl -s -b new_cookies.txt -X GET \
    "$BASE_URL/me" \
    -w "\n%{http_code}")

HTTP_CODE=$(echo "$RESPONSE" | tail -n 1)
JSON_DATA=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "401" ]; then
    echo "✓ Session invalidated after logout"
else
    echo "✗ Session still valid after logout: $JSON_DATA (code: $HTTP_CODE)"
    exit 1
fi

# Clean up cookies file
rm -f cookies.txt new_cookies.txt

echo -e "\n🎉 All tests passed!"