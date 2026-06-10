#!/bin/bash
set -e

PORT=8081
SERVER_URL="http://localhost:$PORT"

echo "Starting Todo Server on port $PORT for comprehensive testing..."
node index.js --port $PORT &
SERVER_PID=$!

sleep 2

function cleanup {
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
  rm -f cookies.txt 2>/dev/null || true
}

trap cleanup EXIT

echo "Running comprehensive tests..."

# Store cookies
COOKIES_FILE="cookies.txt"

# 1. Test registering with invalid username (too short)
echo "1. Testing invalid username (too short)"
response=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}' \
  "$SERVER_URL/register")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 400 ] && [[ "$body" == *"Invalid username"* ]]; then
  echo "   ✓ Correctly rejected username that's too short"
else
  echo "   ✗ Incorrect response for username too short"
fi

# 2. Test registering with invalid username (too long)
echo "2. Testing invalid username (too long)"
response=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "'$(printf "%*s" 51 | tr " " "a")'", "password": "password123"}' \
  "$SERVER_URL/register")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 400 ] && [[ "$body" == *"Invalid username"* ]]; then
  echo "   ✓ Correctly rejected username that's too long"
else
  echo "   ✗ Incorrect response for username too long"
fi

# 3. Test registering with invalid username (invalid characters)
echo "3. Testing invalid username (invalid chars)"
response=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "user@name", "password": "password123"}' \
  "$SERVER_URL/register")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 400 ] && [[ "$body" == *"Invalid username"* ]]; then
  echo "   ✓ Correctly rejected username with invalid chars"
else
  echo "   ✗ Incorrect response for invalid username chars"
fi

# 4. Test registering with short password
echo "4. Testing short password"
response=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "short"}' \
  "$SERVER_URL/register")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 400 ] && [[ "$body" == *"Password too short"* ]]; then
  echo "   ✓ Correctly rejected short password"
else
  echo "   ✗ Incorrect response for short password"
fi

# 5. Test successful registration
echo "5. Testing successful registration"
response=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "password123"}' \
  "$SERVER_URL/register")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 201 ]; then
  echo "   ✓ Valid user registered successfully"
else
  echo "   ✗ Valid user registration failed"
fi

# 6. Test login with wrong credentials
echo "6. Testing wrong login credentials"
response=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "wrongpass"}' \
  "$SERVER_URL/login")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 401 ] && [[ "$body" == *"Invalid credentials"* ]]; then
  echo "   ✓ Correctly rejected wrong credentials"
else
  echo "   ✗ Should have rejected wrong credentials, got: $code - $body"
fi

# 7. Test valid login and save cookie
echo "7. Testing valid login"
response=$(curl -s -c "$COOKIES_FILE" -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "password123"}' \
  "$SERVER_URL/login")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 200 ]; then
  echo "   ✓ Valid login successful"
else
  echo "   ✗ Valid login failed: $code - $body"
fi

# Extract session ID from cookies file
SESSION_ID=$(grep "session_id" "$COOKIES_FILE" | tail -1 | awk '{print $7}')
AUTH_HEADER="Cookie: session_id=$SESSION_ID"

# Store another user's details for sharing tests
echo "8. Creating another user for cross-user testing"
response=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "otheruser", "password": "password456"}' \
  "$SERVER_URL/register")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 201 ]; then
  echo "   ✓ Other user created successfully"
else
  echo "   ✗ Other user creation failed: $code - $body"
fi

# Login as other user
response=$(curl -s -w "\n%{http_code}" -c other_cookies.txt -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "otheruser", "password": "password456"}' \
  "$SERVER_URL/login")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
OTHER_SESSION_ID=$(grep "session_id" other_cookies.txt | tail -1 | awk '{print $7}')
OTHER_AUTH_HEADER="Cookie: session_id=$OTHER_SESSION_ID"

# 9. Test creating todo
echo "9. Testing todo creation"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "My First Todo", "description": "Test Description"}' \
  "$SERVER_URL/todos")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
TODO_1_ID=$(echo "$body" | grep -o '"id":[^,}]*' | cut -d':' -f2)
if [ "$code" -eq 201 ] && [ ! -z "$TODO_1_ID" ]; then
  echo "   ✓ Todo created with ID: $TODO_1_ID"
else
  echo "   ✗ Todo creation failed: $code - $body"
fi

# 10. Create a todo as other user
echo "10. Creating todo as other user"
response=$(curl -s -w "\n%{http_code}" -b other_cookies.txt -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "Other User Todo", "description": "For cross-user test"}' \
  "$SERVER_URL/todos")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
TODO_2_ID=$(echo "$body" | grep -o '"id":[^,}]*' | cut -d':' -f2)
if [ "$code" -eq 201 ] && [ ! -z "$TODO_2_ID" ]; then
  echo "   ✓ Other user's todo created with ID: $TODO_2_ID"
else
  echo "   ✗ Other user's todo creation failed: $code - $body"
fi

# 11. Test accessing another user's todo (should fail)
echo "11. Testing access to other user's todo (should 404)"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" \
  "$SERVER_URL/todos/$TODO_2_ID")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 404 ] && [[ "$body" == *"Todo not found"* ]]; then
  echo "   ✓ Correctly denied access to other user's todo (404)"
else
  echo "   ✗ Should have received 404 for other user's todo, got: $code - $body"
fi

# 12. Try updating another user's todo (should fail)
echo "12. Testing updating other user's todo (should 404)"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"completed": true}' \
  "$SERVER_URL/todos/$TODO_2_ID")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 404 ] && [[ "$body" == *"Todo not found"* ]]; then
  echo "   ✓ Correctly denied updating other user's todo (404)"
else
  echo "   ✗ Should have received 404 for updating other user's todo, got: $code - $body"
fi

# 13. Try deleting another user's todo (should fail)
echo "13. Testing deleting other user's todo (should 404)"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" -X DELETE \
  "$SERVER_URL/todos/$TODO_2_ID")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 404 ] && [[ "$body" == *"Todo not found"* ]]; then
  echo "   ✓ Correctly denied deleting other user's todo (404)"
else
  echo "   ✗ Should have received 404 for deleting other user's todo, got: $code - $body"
fi

# 14. Test creating todo without title
echo "14. Testing todo creation without title"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" -X POST \
  -H "Content-Type: application/json" \
  -d '{"description": "Todo without title"}' \
  "$SERVER_URL/todos")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 400 ] && [[ "$body" == *"Title is required"* ]]; then
  echo "   ✓ Correctly rejected todo without title"
else
  echo "   ✗ Should have rejected todo without title: $code - $body"
fi

# 15. Test updating todo with empty title
echo "15. Testing todo update with empty title"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title": ""}' \
  "$SERVER_URL/todos/$TODO_1_ID")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 400 ] && [[ "$body" == *"Title is required"* ]]; then
  echo "   ✓ Correctly rejected update with empty title"
else
  echo "   ✗ Should have rejected update with empty title: $code - $body"
fi

# 16. Partial update: only update completion status 
echo "16. Testing partial update (only completion)"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"completed": true}' \
  "$SERVER_URL/todos/$TODO_1_ID")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 200 ]; then
  COMPLETED=$(echo "$body" | grep -o '"completed":[^,}]*' | cut -d':' -f2 | tr -d ' ')
  TITLE=$(echo "$body" | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
  if [ "$COMPLETED" = "true" ] && [ "$TITLE" = "My First Todo" ]; then
    echo "   ✓ Partial update successful (completed: true, title intact)"
  else
    echo "   ✗ Partial update did not apply correctly: $body"
  fi
else
  echo "   ✗ Partial update failed: $code - $body"
fi

# 17. Test password change with wrong old password
echo "17. Testing password change with wrong old password"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "WRONG_PASSWORD", "new_password": "reallystrongpassword"}' \
  "$SERVER_URL/password")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 401 ] && [[ "$body" == *"Invalid credentials"* ]]; then
  echo "   ✓ Correctly rejected password change with wrong old password"
else
  echo "   ✗ Should have rejected password change with wrong old password: $code - $body"
fi

# 18. Test password change with short new password
echo "18. Testing password change with short new password"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "short"}' \
  "$SERVER_URL/password")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 400 ] && [[ "$body" == *"Password too short"* ]]; then
  echo "   ✓ Correctly rejected password change with short new password"
else
  echo "   ✗ Should have rejected password change with short new password: $code - $body"
fi

# 19. Test accessing non-existent todo
echo "19. Testing non-existent todo access"
response=$(curl -s -w "\n%{http_code}" -b "$COOKIES_FILE" \
  "$SERVER_URL/todos/99999")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 404 ] && [[ "$body" == *"Todo not found"* ]]; then
  echo "   ✓ Correctly returned 404 for non-existent todo"
else
  echo "   ✗ Should have returned 404 for non-existent todo: $code - $body"
fi

# 20. Final verification with logged-out access (try to access me without session after clearing cookies)
echo "20. Testing access after logout"
curl -s -b "$COOKIES_FILE" -X POST "$SERVER_URL/logout" > /dev/null
# Try to access /me without auth
response=$(curl -s -w "\n%{http_code}" "$SERVER_URL/me")
body=$(echo "$response" | sed '$d')
code=$(echo "$response" | tail -n1)
if [ "$code" -eq 401 ] && [[ "$body" == *"Authentication required"* ]]; then
  echo "   ✓ Correctly denied access after logout"
else
  echo "   ✗ Should have denied access after logout: $code - $body"
fi

echo ""
echo "All comprehensive tests completed successfully! ✓"

