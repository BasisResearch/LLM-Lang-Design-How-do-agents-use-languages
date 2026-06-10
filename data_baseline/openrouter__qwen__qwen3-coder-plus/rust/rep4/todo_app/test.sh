#!/bin/bash

# Test script for Todo App API

# Check if server is running on port 8000 before proceeding
echo "Starting server in background..."
cd /root/experiments/data/openrouter__qwen__qwen3-coder-plus/rust/rep4/todo_app
./run.sh --port 8080 &
SERVER_PID=$!
sleep 3  # Allow time for server to start

# Clean up function
cleanup() {
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
    exit
}

# Set up trap to clean up on script exit
trap cleanup EXIT

echo "Testing the API..."

BASE_URL="http://localhost:8080"
JAR_FILE="/tmp/cookies.txt"  # Temporary file to store cookies

echo "Test 1: Register a user"
response=$(curl -s -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}' \
    ${BASE_URL}/register)
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "201" ]; then
    echo "✓ Register test passed"
else
    echo "✗ Register test failed"
    cleanup
fi

echo ""
echo "Test 2: Try to register duplicate user"
response=$(curl -s -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d '{"username": "testuser", "password": "password123"}' \
    ${BASE_URL}/register)
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "409" ]; then
    echo "✓ Duplicate register test passed"
else
    echo "✗ Duplicate register test failed"
    cleanup
fi

echo ""
echo "Test 3: Login with correct credentials"
response=$(curl -s -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -c "${JAR_FILE}" \
    -d '{"username": "testuser", "password": "password123"}' \
    ${BASE_URL}/login)
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "200" ]; then
    echo "✓ Login test passed"
else
    echo "✗ Login test failed"
    cleanup
fi

echo ""
echo "Test 4: Access protected /me endpoint with valid session"
response=$(curl -s -w "%{http_code}" \
    -X GET \
    -H "Content-Type: application/json" \
    -b "${JAR_FILE}" \
    ${BASE_URL}/me)
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "200" ] && [[ "${body}" == *"\"username\":\"testuser\""* ]]; then
    echo "✓ /me test passed"
else
    echo "✗ /me test failed"
    cleanup
fi

echo ""
echo "Test 5: Create a todo"
response=$(curl -s -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -b "${JAR_FILE}" \
    -d '{"title": "Buy groceries", "description": "Milk, bread, eggs"}' \
    ${BASE_URL}/todos)
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "201" ] && [[ "${body}" == *"\"title\":\"Buy groceries\""* ]]; then
    TODO_ID=$(echo "${body}" | grep -o '"id":[0-9]*' | cut -d':' -f2)
    echo "Created TODO with ID: ${TODO_ID}"
    echo "✓ Create todo test passed"
else
    echo "✗ Create todo test failed"
    cleanup
fi

echo ""
echo "Test 6: Get all todos"
response=$(curl -s -w "%{http_code}" \
    -X GET \
    -H "Content-Type: application/json" \
    -b "${JAR_FILE}" \
    ${BASE_URL}/todos)
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body count: $(echo ${body} | jq length)"
if [ "${http_code}" == "200" ] && [[ "${body}" == *"$TODO_ID"* ]]; then
    echo "✓ Get todos test passed"
else
    echo "✗ Get todos test failed"
    cleanup
fi

echo ""
echo "Test 7: Get specific todo"
response=$(curl -s -w "%{http_code}" \
    -X GET \
    -H "Content-Type: application/json" \
    -b "${JAR_FILE}" \
    ${BASE_URL}/todos/${TODO_ID})
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "200" ] && [[ "${body}" == *"\"title\":\"Buy groceries\""* ]]; then
    echo "✓ Get specific todo test passed"
else
    echo "✗ Get specific todo test failed"
    cleanup
fi

echo ""
echo "Test 8: Update todo"  
response=$(curl -s -w "%{http_code}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -b "${JAR_FILE}" \
    -d '{"title": "Buy groceries UPDATED", "completed": true}' \
    ${BASE_URL}/todos/${TODO_ID})
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "200" ] && [[ "${body}" == *"\"title\":\"Buy groceries UPDATED\""* ]] && [[ "${body}" == *"\"completed\":true"* ]]; then
    echo "✓ Update todo test passed"
else
    echo "✗ Update todo test failed"
    cleanup
fi

echo ""
echo "Test 9: Try to access protected endpoints without session"
response=$(curl -s -w "%{http_code}" \
    -X GET \
    -H "Content-Type: application/json" \
    ${BASE_URL}/me)
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "401" ]; then
    echo "✓ Unauthorized access test passed"
else
    echo "✗ Unauthorized access test failed"
    cleanup
fi

echo ""
echo "Test 10: Logout"
response=$(curl -s -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -b "${JAR_FILE}" \
    ${BASE_URL}/logout)
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "200" ]; then
    echo "✓ Logout test passed"
else
    echo "✗ Logout test failed"
    cleanup
fi

echo ""
echo "Test 11: Try to access /me after logout (should fail)"
response=$(curl -s -w "%{http_code}" \
    -X GET \
    -H "Content-Type: application/json" \
    -b "${JAR_FILE}" \
    ${BASE_URL}/me)
http_code="${response: -3}"
body="${response%???}"

echo "Status: ${http_code}, Body: ${body}"
if [ "${http_code}" == "401" ]; then
    echo "✓ Post-logout unauthorized access test passed"
else
    echo "✗ Post-logout unauthorized access test failed"
    cleanup
fi

echo ""
echo "Test 12: Delete todo"
# Login again first
curl -s -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -c "${JAR_FILE}" \
    -d '{"username": "testuser", "password": "password123"}' \
    ${BASE_URL}/login 2>&1 > /dev/null

response=$(curl -s -w "%{http_code}" \
    -X DELETE \
    -H "Content-Type: application/json" \
    -b "${JAR_FILE}" \
    ${BASE_URL}/todos/${TODO_ID})
http_code="${response: -3}"

if [ "${http_code}" == "204" ]; then
    echo "✓ Delete todo test passed"
else
    echo "✗ Delete todo test failed"
    cleanup
fi

echo ""
echo "=================================="
echo "ALL TESTS PASSED SUCCESSFULLY! 🎉"
echo "=================================="