#!/bin/bash

# Test script for the Todo API Server

echo "Testing Todo API Server..."

# Configuration
TEST_PORT=${1:-8080}
TEST_HOST="localhost"
BASE_URL="http://$TEST_HOST:$TEST_PORT"
LOG_FILE="test.log"

echo "Testing on $BASE_URL"
echo "Starting server in background..."

# Start the server in background
timeout 30s ./server --port $TEST_PORT &
SERVER_PID=$!
sleep 2  # Give server time to start

# Function to send requests
make_request() {
    local method=$1
    local endpoint=$2
    local data=$3
    local expected_status=$4
    
    if [ -n "$data" ]; then
        response=$(curl -s -o /tmp/response.txt -w "%{http_code}" -X $method -H "Content-Type: application/json" -d "$data" "$BASE_URL$endpoint")
    else
        response=$(curl -s -o /tmp/response.txt -w "%{http_code}" -X $method "$BASE_URL$endpoint")
    fi
    
    status_code=$(echo $response | grep -o '[0-9]*$')
    
    if [ "$status_code" = "$expected_status" ]; then
        echo "✓ $method $endpoint -> $status_code"
        cat /tmp/response.txt | head -c 200
        echo ""
        return 0
    else
        echo "✗ $method $endpoint -> Expected $expected_status, got $status_code"
        cat /tmp/response.txt
        echo ""
        return 1
    fi
}

total_tests=0
passed_tests=0

run_test() {
    local test_name=$1
    local method=$2
    local endpoint=$3
    local data=$4
    local expected=$5
    
    ((total_tests++))
    echo -n "Running: $test_name... "
    if make_request "$method" "$endpoint" "$data" "$expected" >/dev/null 2>&1; then
        echo "PASSED"
        ((passed_tests++))
    else
        echo "FAILED"
    fi
}

echo "Running tests..."

# Test 1: Invalid method
run_test "Invalid method (should return 400-like)" "GET" "/nonexistentendpoint" "" "404"

# Test 2: Valid registration
run_test "User registration" "POST" "/register" '{"username":"testuser","password":"password123"}' "201"

# Test 3: Duplicate registration (should fail)
run_test "Duplicate registration" "POST" "/register" '{"username":"testuser","password":"password123"}' "409"

# Test 4: Registration with invalid username
run_test "Invalid username" "POST" "/register" '{"username":"ab","password":"password123"}' "400"

# Test 5: Registration with short password
run_test "Short password" "POST" "/register" '{"username":"newuser","password":"pass"}' "400"

# Test 6: Login with valid credentials
run_test "Valid login" "POST" "/login" '{"username":"testuser","password":"password123"}' "200"

# Capture session cookie from login response for subsequent tests
echo "Extracting session cookie..."
SESSION_COOKIE=$(curl -c /tmp/cookies.txt -s -o /tmp/response.txt -w "%{http_code}" -X POST -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' "$BASE_URL/login")

# Test 7: Access /me endpoint (authentication required)
run_test "Get current user" "GET" "/me" "" "200"

# Test 8: Try access to /me without auth
run_test "Access user without auth" "GET" "/me" "" "401"

# Print results
echo ""
echo "Results: $passed_tests/$total_tests tests passed."

# Cleanup
if ps -p $SERVER_PID > /dev/null; then
    kill $SERVER_PID
    sleep 1
    if ps -p $SERVER_PID > /dev/null; then
        kill -9 $SERVER_PID
    fi
fi

if [ $passed_tests -eq $total_tests ]; then
    echo "All tests PASSED!"
    exit 0
else
    echo "Some tests FAILED!"
    exit 1
fi