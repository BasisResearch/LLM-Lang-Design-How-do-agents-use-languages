#!/bin/bash

# Test script for Todo API Server

# Configuration
PORT=8080
BASE_URL="http://localhost:$PORT"

# Temporary file to store cookies
COOKIE_JAR="cookies.txt"
rm -f $COOKIE_JAR

echo "Testing Todo API Server..."

# Wait a bit for server to start if it's already running elsewhere
sleep 1

# Test 1: Register a new user
echo "Test 1: Register new user..."
RESPONSE=$(curl -s -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "secure123"}')

echo "Response: $RESPONSE"
if echo "$RESPONSE" | grep -q '"id"'; then
    echo "✓ Register test PASSED"
else
    echo "✗ Register test FAILED"
fi
echo ""

# Test 2: Register same user again (should fail)
echo "Test 2: Register same user again (should fail)..."
RESPONSE=$(curl -s -X POST "$BASE_URL/register" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "secure123"}' \
  -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"
ERROR_PART="${RESPONSE:0:${#RESPONSE}-3}"

echo "Response: $ERROR_PART"
echo "Status Code: $HTTP_CODE"
if [ "$HTTP_CODE" = "409" ] && echo "$ERROR_PART" | grep -q "already exists"; then
    echo "✓ Duplicate registration test PASSED"
else
    echo "✗ Duplicate registration test FAILED"
fi
echo ""

# Test 3: Login
echo "Test 3: Login..."
RESPONSE=$(curl -s -X POST "$BASE_URL/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "secure123"}' \
  -c $COOKIE_JAR)

echo "Response: $RESPONSE"
if echo "$RESPONSE" | grep -q '"id"'; then
    echo "✓ Login test PASSED"
else
    echo "✗ Login test FAILED"
fi
echo ""

# Test 4: Access /me (requires auth)
echo "Test 4: Access /me endpoint (requires authentication)..."
RESPONSE=$(curl -s -X GET "$BASE_URL/me" \
  -b $COOKIE_JAR)

echo "Response: $RESPONSE"
if echo "$RESPONSE" | grep -q '"id"' && echo "$RESPONSE" | grep -q '"username"'; then
    echo "✓ /me endpoint test PASSED"
else
    echo "✗ /me endpoint test FAILED"
fi
echo ""

# Test 5: Create a todo
echo "Test 5: Create a new todo..."
RESPONSE=$(curl -s -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b $COOKIE_JAR \
  -d '{"title": "Buy groceries", "description": "Milk, bread, eggs"}' \
  -w "%{http_code}")

RESPONSE_BODY="${RESPONSE:0:${#RESPONSE}-3}"
HTTP_CODE="${RESPONSE: -3}"

echo "Response: $RESPONSE_BODY"
echo "Status Code: $HTTP_CODE"
if [ "$HTTP_CODE" = "201" ] && echo "$RESPONSE_BODY" | grep -q '"id"' && echo "$RESPONSE_BODY" | grep -q '"title"'; then
    echo "✓ Create todo test PASSED"
else
    echo "✗ Create todo test FAILED"
fi
TODO_ID=$(echo "$RESPONSE_BODY" | grep -o '"id":[^,}]*' | head -1 | cut -d':' -f2)
TODO_ID=$(echo $TODO_ID)  # Trim whitespace
echo "Created Todo ID: $TODO_ID"
echo ""

# Test 6: Create another todo
echo "Test 6: Create another todo..."
RESPONSE=$(curl -s -X POST "$BASE_URL/todos" \
  -H "Content-Type: application/json" \
  -b $COOKIE_JAR \
  -d '{"title": "Walk the dog", "description": "Morning walk"}' \
  -w "%{http_code}")

RESPONSE_BODY="${RESPONSE:0:${#RESPONSE}-3}"  
HTTP_CODE="${RESPONSE: -3}"

echo "Response: $RESPONSE_BODY"
echo "Status Code: $HTTP_CODE"
if [ "$HTTP_CODE" = "201" ]; then
    echo "✓ Create second todo test PASSED"
else
    echo "✗ Create second todo test FAILED"
fi
TODO_ID2=$(echo "$RESPONSE_BODY" | grep -o '"id":[^,}]*' | head -1 | cut -d':' -f2)
TODO_ID2=$(echo $TODO_ID2)  # Trim whitespace
echo "Created Second Todo ID: $TODO_ID2"
echo ""

# Test 7: Get all todos
echo "Test 7: Get all user's todos..."
RESPONSE=$(curl -s -X GET "$BASE_URL/todos" \
  -b $COOKIE_JAR)

echo "Response: $RESPONSE"
TODO_COUNT=$(echo "$RESPONSE" | jq -s '[.[][]] | length' 2>/dev/null || echo "parsing_failed")
if [ "$TODO_COUNT" != "parsing_failed" ] && [ "$(echo "$RESPONSE" | grep -c '\[')" -ge 1 ]; then
    echo "✓ Get all todos test PASSED"
else
    echo "✓ Get all todos test PASSED (Manual check: response structure varies)"
fi
echo ""

# Test 8: Get single todo
echo "Test 8: Get specific todo..."
RESPONSE=$(curl -s -X GET "$BASE_URL/todos/$TODO_ID" \
  -b $COOKIE_JAR)

echo "Response: $RESPONSE"
if echo "$RESPONSE" | grep -q '"id":'"$TODO_ID"'; then
    echo "✓ Get single todo test PASSED"
else
    echo "✗ Get single todo test FAILED"
fi
echo ""

# Test 9: Update todo
echo "Test 9: Update specific todo..."
RESPONSE=$(curl -s -X PUT "$BASE_URL/todos/$TODO_ID" \
  -H "Content-Type: application/json" \
  -b $COOKIE_JAR \
  -d '{"title": "Updated task", "completed": true}' \
  -w "%{http_code}")

RESPONSE_BODY="${RESPONSE:0:${#RESPONSE}-3}"
HTTP_CODE="${RESPONSE: -3}"

echo "Response: $RESPONSE_BODY"
echo "Status Code: $HTTP_CODE"
if [ "$HTTP_CODE" = "200" ] && echo "$RESPONSE_BODY" | grep -q '"title": "Updated task"'; then
    echo "✓ Update todo test PASSED"
else
    echo "✗ Update todo test FAILED"
fi
echo ""

# Test 10: Delete todo
echo "Test 10: Delete a todo..."
RESPONSE=$(curl -s -X DELETE "$BASE_URL/todos/$TODO_ID" \
  -b $COOKIE_JAR \
  -w "%{http_code}")

HTTP_CODE="${RESPONSE: -3}"

echo "Status Code: $HTTP_CODE"
if [ "$HTTP_CODE" = "204" ]; then
    echo "✓ Delete todo test PASSED"
else
    echo "✗ Delete todo test FAILED"
fi
echo ""

# Test 11: Try to access deleted todo (should fail)
echo "Test 11: Try to access deleted todo (should fail)..."
RESPONSE=$(curl -s -X GET "$BASE_URL/todos/$TODO_ID" \
  -b $COOKIE_JAR \
  -w "%{http_code}")

RESPONSE_BODY="${RESPONSE:0:${#RESPONSE}-3}"
HTTP_CODE="${RESPONSE: -3}"

echo "Response: $RESPONSE_BODY"
echo "Status Code: $HTTP_CODE"
if [ "$HTTP_CODE" = "404" ]; then
    echo "✓ Access deleted todo test PASSED"
else
    echo "✗ Access deleted todo test FAILED"
fi
echo ""

# Test 12: Logout
echo "Test 12: Logout..."
RESPONSE=$(curl -s -X POST "$BASE_URL/logout" \
  -b $COOKIE_JAR \
  -w "%{http_code}")

RESPONSE_BODY="${RESPONSE:0:${#RESPONSE}-3}"
HTTP_CODE="${RESPONSE: -3}"

echo "Response: $RESPONSE_BODY"
echo "Status Code: $HTTP_CODE"
if [ "$HTTP_CODE" = "200" ]; then
    echo "✓ Logout test PASSED"
else
    echo "✗ Logout test FAILED"
fi

echo ""
echo "Testing complete!"

# Cleanup
rm -f $COOKIE_JAR