#!/bin/bash

echo "Testing edge cases..."

./target/release/todo-app --port 8080 &
SERVER_PID=$!
sleep 3

COOKIE_JAR="edge_cookies.txt"

# Test 1: Invalid username formats
echo "Test 1: Validating username rules..."
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}' \
  "http://localhost:8080/register")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "400" ] && [[ $body == *'Invalid username'* ]]; then
  echo "✅ Short username validation passed"
else
  echo "❌ Short username validation failed: status=$status_code"
fi

response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "user@invalid", "password": "password123"}' \
  "http://localhost:8080/register")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "400" ] && [[ $body == *'Invalid username'* ]]; then
  echo "✅ Invalid character in username validation passed"
else
  echo "❌ Invalid character in username validation failed: status=$status_code"
fi


# Test 2: Password length validation
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "validuser", "password": "short"}' \
  "http://localhost:8080/register")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "400" ] && [[ $body == *'Password too short'* ]]; then
  echo "✅ Short password validation passed"
else
  echo "❌ Short password validation failed: status=$status_code"
fi


# Test 3: Attempt to get a todo by wrong user - We'll need two users to fully test cross-access
echo "Test 3: Registering user for cross-user access test..."

# Register first user and add a todo
response=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "firstuser", "password": "password123"}' \
  "http://localhost:8080/register")
  
# Login as first user
response=$(curl -c $COOKIE_JAR -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "firstuser", "password": "password123"}' \
  "http://localhost:8080/login")

# First user adds a todo
response=$(curl -b $COOKIE_JAR -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "First user todo", "description": "Important task"}' \
  "http://localhost:8080/todos")

FIRST_USER_TODO_ID=$(echo "$response" | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
echo "First user created todo with ID: $FIRST_USER_TODO_ID"

# Register and login as second user
response=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "seconduser", "password": "password123"}' \
  "http://localhost:8080/register")

# Create new cookie file for second user
SECOND_COOKIE_JAR="second_cookies.txt"
response=$(curl -c $SECOND_COOKIE_JAR -s -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "seconduser", "password": "password123"}' \
  "http://localhost:8080/login")

# Test that second user can't access first user's todo
response=$(curl -b $SECOND_COOKIE_JAR -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/todos/$FIRST_USER_TODO_ID")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "404" ] && [[ $body == *'Todo not found'* ]]; then
  echo "✅ Cross-user access protection passed"
else
  echo "❌ Cross-user access protection failed: status=$status_code, body=$body"
fi


# Test 4: Attempting to update todo with empty title
first_cookie_session_id=$(grep session_id $COOKIE_JAR | awk '{print $7}')
curl -b "session_id=$first_cookie_session_id" -s -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title": ""}' \
  "http://localhost:8080/todos/$FIRST_USER_TODO_ID"

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "400" ] && [[ $body == *'Title is required'* ]]; then
  echo "✅ Empty title update validation passed"
else
  echo "❌ Empty title update validation failed: status=$status_code, body=$body"
fi


# Test 5: Register duplicate usernames
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "firstuser", "password": "password456"}' \
  "http://localhost:8080/register")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "409" ] && [[ $body == *'Username already exists'* ]]; then
  echo "✅ Duplicate username check passed"
else
  echo "❌ Duplicate username check failed: status=$status_code, body=$body"
fi


# Test 6: Login with invalid credentials
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "nonexistentuser", "password": "password123"}' \
  "http://localhost:8080/login")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "401" ] && [[ $body == *'Invalid credentials'* ]]; then
  echo "✅ Invalid credentials check passed"
else
  echo "❌ Invalid credentials check failed: status=$status_code, body=$body"
fi


# Test 7: Wrong old password during update
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}' \
  "http://localhost:8080/password")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "401" ] && [[ $body == *'Invalid credentials'* ]]; then
  echo "✅ Wrong old password check passed"
else
  echo "❌ Wrong old password check failed: status=$status_code, body=$body"
fi


# Test 8: Update password to too short password
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "bad"}' \
  "http://localhost:8080/password")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "400" ] && [[ $body == *'Password too short'* ]]; then
  echo "✅ Short new password validation passed"
else
  echo "❌ Short new password validation failed: status=$status_code, body=$body"
fi


# Cleanup
rm -f $COOKIE_JAR $SECOND_COOKIE_JAR
kill $SERVER_PID

echo "All edge case tests completed!"