#!/bin/bash

echo "Starting server..."
./target/release/todo-app --port 8080 &
SERVER_PID=$!
sleep 3  # Give the server time to start

# Initialize cookie jar
COOKIE_JAR="test_cookies.txt"

echo "Running functional tests..."

# 1. Test registering a user
echo "1. Testing registration..."
response=$(curl -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  "http://localhost:8080/register")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "201" ] && [[ $body == *'"id":1'* && $body == *'"username":"testuser"'* ]]; then
  echo "✅ Registration test passed"
else
  echo "❌ Registration test failed: status=$status_code, body=$body"
fi

# 2. Test logging in
echo "2. Testing login..."
response=$(curl -c $COOKIE_JAR -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}' \
  "http://localhost:8080/login")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "200" ] && [[ $body == *'"username":"testuser"'* ]]; then
  echo "✅ Login test passed"
  # Verify cookie existence
  if [ -f $COOKIE_JAR ] && grep -q "session_id" $COOKIE_JAR; then
    echo "✅ Session cookie verified"
  else
    echo "❌ Session cookie not found"
  fi
else
  echo "❌ Login test failed: status=$status_code, body=$body"
fi

# 3. Test getting user info
echo "3. Testing getting user info..."
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/me")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "200" ] && [[ $body == *'"username":"testuser"'* ]]; then
  echo "✅ Get user info test passed"
else
  echo "❌ Get user info test failed: status=$status_code, body=$body"
fi

# 4. Test access without auth cookie
echo "4. Testing unauthorized access..."
response=$(curl -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/me")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "401" ] && [[ $body == *'"error"'* ]]; then
  echo "✅ Unauthorized access test passed"
else
  echo "❌ Unauthorized access test failed: status=$status_code, body=$body"
fi

# 5. Add a todo item
echo "5. Testing adding a new todo..."
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"title": "Learn Rust", "description": "Complete the todo app project"}' \
  "http://localhost:8080/todos")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "201" ] && [[ $body == *'"title":"Learn Rust"'* ]]; then
  TODO_ID=$(echo $body | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
  echo "✅ Adding todo test passed, todo ID: $TODO_ID"
else
  echo "❌ Adding todo test failed: status=$status_code, body=$body"
fi

# 6. Get all todos
echo "6. Testing getting all todos..."
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/todos")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "200" ] && [[ $body == *'"title":"Learn Rust"'* ]]; then
  echo "✅ Get all todos test passed"
else
  echo "❌ Get all todos test failed: status=$status_code, body=$body"
fi

# 7. Get specific todo
echo "7. Testing getting specific todo..."
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X GET \
  "http://localhost:8080/todos/$TODO_ID")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "200" ] && [[ $body == *'"title":"Learn Rust"'* ]]; then
  echo "✅ Get specific todo test passed"
else
  echo "❌ Get specific todo test failed: status=$status_code, body=$body"
fi

# 8. Update todo
echo "8. Testing updating a todo..."
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"title": "Master Rust", "completed": true}' \
  "http://localhost:8080/todos/$TODO_ID")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "200" ] && [[ $body == *'"title":"Master Rust"'* && $body == *'"completed":true'* ]]; then
  echo "✅ Update todo test passed"
else
  echo "❌ Update todo test failed: status=$status_code, body=$body"
fi

# 9. Delete todo
echo "9. Testing deleting a todo..."
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X DELETE \
  "http://localhost:8080/todos/$TODO_ID")

status_code="${response: -3}"

if [ "$status_code" = "204" ]; then
  echo "✅ Delete todo test passed"
else
  echo "❌ Delete todo test failed: status=$status_code"
fi

# 10. Change password
echo "10. Testing changing password..."
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newSecurePass456"}' \
  "http://localhost:8080/password")

status_code="${response: -3}"
body="${response%???}"

if [ "$status_code" = "200" ]; then
  echo "✅ Change password test passed"
else
  echo "❌ Change password test failed: status=$status_code, body=$body"
fi

# 11. Logout
echo "11. Testing logout..."
response=$(curl -b $COOKIE_JAR -s -w "%{http_code}" \
  -X POST \
  "http://localhost:8080/logout")

status_code="${response: -3}"

if [ "$status_code" = "200" ]; then
  echo "✅ Logout test passed"
else
  echo "❌ Logout test failed: status=$status_code"
fi

# Cleanup
rm -f $COOKIE_JAR

# Kill the server
kill $SERVER_PID

echo "All tests completed for server!"