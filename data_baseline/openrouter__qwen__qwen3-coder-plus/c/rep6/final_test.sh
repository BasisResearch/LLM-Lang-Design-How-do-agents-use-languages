#!/bin/bash

echo "Starting final comprehensive test..."

# Kill any existing server on port 8080
lsof -ti:8080 | xargs kill 2>/dev/null || true

# Give time for port to become available
sleep 2

# Start server in background
./todo_server --port 8080 &
SERVER_PID=$!
echo "Started server with PID $SERVER_PID"

# Wait for server to be fully ready
sleep 3

# Test all operations sequentially
echo "Running tests..."

success=true

echo "1. Testing registration..."
response=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"finaltest","password":"securepassword123"}' -H "Content-Type: application/json" http://localhost:8080/register)
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$status" -eq 201 ]; then
    echo "✓ Registration successful"
else
    echo "✗ Registration failed: $body (Status: $status)"
    success=false
fi

echo "2. Testing login to get cookies..."
curl -s -X POST -d '{"username":"finaltest","password":"securepassword123"}' -H "Content-Type: application/json" -c test_cookies.txt http://localhost:8080/login > /dev/null

if [ $? -eq 0 ]; then
    echo "✓ Login successful, cookies saved"
else
    echo "✗ Login failed"
    success=false
fi

echo "3. Testing /me endpoint..."
response=$(curl -s -w "\n%{http_code}" -X GET -b test_cookies.txt http://localhost:8080/me)
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$status" -eq 200 ]; then
    echo "✓ Me endpoint works: $body"
else
    echo "✗ Me endpoint failed: $body (Status: $status)"
    success=false
fi

echo "4. Testing password change..."
response=$(curl -s -w "\n%{http_code}" -X PUT -d '{"old_password":"securepassword123","new_password":"newsecurepassword456"}' -H "Content-Type: application/json" -b test_cookies.txt http://localhost:8080/password)
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$status" -eq 200 ]; then
    echo "✓ Password change successful"
else
    echo "✗ Password change failed: $body (Status: $status)"
    success=false
fi

# Need to re-login with new password to update cookies
echo "5. Re-login with new password..."
curl -s -X POST -d '{"username":"finaltest","password":"newsecurepassword456"}' -H "Content-Type: application/json" -c test_cookies.txt http://localhost:8080/login > /dev/null

echo "6. Testing todo creation..."
response=$(curl -s -w "\n%{http_code}" -X POST -d '{"title":"Final Test Todo","description":"Created during final test"}' -H "Content-Type: application/json" -b test_cookies.txt http://localhost:8080/todos)
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$status" -eq 201 ]; then
    echo "✓ Todo creation successful: $(echo $body | jq -r .title)"
else
    echo "✗ Todo creation failed: $body (Status: $status)"
    success=false
fi

echo "7. Testing todo listing..."
response=$(curl -s -w "\n%{http_code}" -X GET -b test_cookies.txt http://localhost:8080/todos)
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$status" -eq 200 ]; then
    count=$(echo "$body" | jq 'length')
    echo "✓ Todo listing successful: $count todo(s) found"
else
    echo "✗ Todo listing failed: $body (Status: $status)"
    success=false
fi

echo "8. Testing updating todo..."
response=$(curl -s -w "\n%{http_code}" -X PUT -d '{"title":"Updated Final Test Todo","completed":true}' -H "Content-Type: application/json" -b test_cookies.txt http://localhost:8080/todos/1)
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$status" -eq 200 ]; then
    echo "✓ Todo update successful: $(echo $body | jq -r .title) (Completed: $(echo $body | jq -r .completed))"
else
    echo "✗ Todo update failed: $body (Status: $status)"
    success=false
fi

echo "9. Testing getting a specific todo..."
response=$(curl -s -w "\n%{http_code}" -X GET -b test_cookies.txt http://localhost:8080/todos/1)
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$status" -eq 200 ]; then
    echo "✓ Get specific todo successful: $(echo $body | jq -r .title)"
else
    echo "✗ Get specific todo failed: $body (Status: $status)"
    success=false
fi

echo "10. Testing deleting todo..."
status=$(curl -s -w "%{http_code}" -X DELETE -b test_cookies.txt http://localhost:8080/todos/1 -o /dev/null)

if [ "$status" -eq 204 ]; then
    echo "✓ Todo deletion successful"
else
    echo "✗ Todo deletion failed (Status: $status)"
    success=false
fi

echo "11. Testing logout..."
response=$(curl -s -w "\n%{http_code}" -X POST -b test_cookies.txt http://localhost:8080/logout)
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$status" -eq 200 ]; then
    echo "✓ Logout successful"
else
    echo "✗ Logout failed: $body (Status: $status)"
    success=false
fi

echo "12. Testing authentication after logout (should fail)..."
response=$(curl -s -w "\n%{http_code}" -X GET -b test_cookies.txt http://localhost:8080/me)
status=$(echo "$response" | tail -n1)
body=$(echo "$response" | head -n-1)

if [ "$status" -eq 401 ]; then
    echo "✓ Proper auth failure after logout: $(echo $body | jq -r .error)"
else
    echo "✗ Should have been unauthorized after logout: $body (Status: $status)"
    success=false
fi

echo "13. Testing validation and edge cases..."

# Try to register with weak password
response=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"baduser","password":"weak"}' -H "Content-Type: application/json" http://localhost:8080/register)
status=$(echo "$response" | tail -n1)
if [ "$status" -eq 400 ]; then
    echo "✓ Correctly rejected weak password"
else
    echo "✗ Should have rejected weak password (Status: $status)"
    success=false
fi

# Try to register with invalid username
response=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"ab","password":"password123"}' -H "Content-Type: application/json" http://localhost:8080/register)
status=$(echo "$response" | tail -n1)
if [ "$status" -eq 400 ]; then
    echo "✓ Correctly rejected invalid username"
else
    echo "✗ Should have rejected invalid username (Status: $status)"
    success=false
fi

# Try to re-register duplicate user
response=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"finaltest","password":"password123"}' -H "Content-Type: application/json" http://localhost:8080/register)
status=$(echo "$response" | tail -n1)
if [ "$status" -eq 409 ]; then
    echo "✓ Correctly rejected duplicate username"
else
    echo "✗ Should have rejected duplicate username (Status: $status)"
    success=false
fi

# Cleanup
kill $SERVER_PID 2>/dev/null
rm -f test_cookies.txt 2>/dev/null

echo ""
if [ "$success" = true ]; then
    echo "🎉 ALL TESTS PASSED! Server implementation is working correctly."
    exit 0
else
    echo "⚠️  SOME TESTS FAILED!"
    exit 1
fi