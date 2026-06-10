#!/bin/bash
# Comprehensive test script for Todo API Server

set -e  # Exit on any error

echo "Starting Todo API Server tests..."

# Start the server in background
./todo_server --port 9999 &
SERVER_PID=$!
sleep 1  # Give server time to start

# Configuration
SERVER_URL="http://localhost:9999"
COOKIES_FILE=$(mktemp)

echo "Running tests..."

# Test 1: Registration with valid details
echo "Test 1: Register user..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "securepassword"}' \
  "${SERVER_URL}/register")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Test 2: Attempt duplicate registration 
echo "Test 2: Try to register same user again..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "anotherpass"}' \
  "${SERVER_URL}/register")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Test 3: Login with registered user
echo "Test 3: Login with registered user..." 
RESPONSE=$(curl -s -c "$COOKIES_FILE" -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "securepassword"}' \
  "${SERVER_URL}/login")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Test 4: Access /me with valid session
echo "Test 4: Access /me endpoint with valid session..."
RESPONSE=$(curl -s -b "$COOKIES_FILE" -w "\n%{http_code}" \
  "${SERVER_URL}/me")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Test 5: Access /me without session (should fail)
echo "Test 5: Access /me without session (should fail)..."
RESPONSE=$(curl -s -w "\n%{http_code}" \
  "${SERVER_URL}/me")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Test 6: Create a todo item
echo "Test 6: Create a todo..."
RESPONSE=$(curl -s -b "$COOKIES_FILE" -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "First Todo", "description": "My first task"}' \
  "${SERVER_URL}/todos")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Test 7: Get todos list
echo "Test 7: Get todos list..."
RESPONSE=$(curl -s -b "$COOKIES_FILE" -w "\n%{http_code}" \
  "${SERVER_URL}/todos")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Test 8: Create todo with missing title (should fail)
echo "Test 8: Create todo without title (should fail)..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"description": "No title here"}' \
  "${SERVER_URL}/todos")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Test 9: Logout
echo "Test 9: Logout..."
RESPONSE=$(curl -s -b "$COOKIES_FILE" -w "\n%{http_code}" -X POST \
  "${SERVER_URL}/logout")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Test 10: Try accessing protected resource after logout 
echo "Test 10: Access /me after logout (should fail)..."
RESPONSE=$(curl -s -b "$COOKIES_FILE" -w "\n%{http_code}" \
  "${SERVER_URL}/me")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n-1)

echo "Status: $HTTP_CODE, Response: $BODY"

# Cleanup
rm -f "$COOKIES_FILE"
kill $SERVER_PID 2>/dev/null || true

echo "Tests completed successfully!"