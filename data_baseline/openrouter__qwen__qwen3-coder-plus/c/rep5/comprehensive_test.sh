#!/bin/bash

echo "Testing Todo Server Implementation..."

# Start server  
./server_fixed --port 8082 &
SERVER_PID=$!
sleep 2

if ! ps -p $SERVER_PID > /dev/null; then
    echo "Server failed to start"
    exit 1
fi

echo "Server started with PID $SERVER_PID"

FAIL_COUNT=0
TOTAL_TESTS=0

# Function to increment counters and log results
run_test() {
    local test_desc=$1
    local cmd=$2
    local expected_status=$3
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo -n "Test $TOTAL_TESTS: $test_desc... "
    
    local result=$(eval $cmd 2>&1)
    local status_code=$(echo $result | grep -o '"status_code":[0-9]*' | cut -d: -f2)
    
    if [ "$status_code" = "$expected_status" ]; then
        echo "PASS"
    else
        echo "FAIL (Expected: $expected_status, Got: $status_code)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Test registration
echo "Testing registration..."
RESPONSE=$(curl -s -w "\nstatus_code:%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d '{"username":"testuser", "password":"password123"}' \
    http://localhost:8082/register)

STATUS_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

echo "Registration response: $RESPONSE_BODY"
echo "Status Code: $(echo $STATUS_CODE | grep -o "[0-9]*")"

if [[ $(echo $STATUS_CODE | grep -o "[0-9]*") == "201" ]]; then
    echo "✓ Registration test PASSED"
    REGISTER_SUCCESS=true
else
    echo "✗ Registration test FAILED"
    REGISTER_SUCCESS=false
fi

if [ "$REGISTER_SUCCESS" = true ]; then
    # Test login
    echo "Testing login..."
    LOGIN_RESPONSE=$(curl -s --cookie-jar cookies.txt -w "\nstatus_code:%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d '{"username":"testuser", "password":"password123"}' \
        http://localhost:8082/login)
       
    LOGIN_STATUS=$(echo "$LOGIN_RESPONSE" | tail -n1)
    LOGIN_BODY=$(echo "$LOGIN_RESPONSE" | head -n-1)
    
    echo "Login response: $LOGIN_BODY"
    echo "Status Code: $(echo $LOGIN_STATUS | grep -o "[0-9]*")"
    
    if [[ $(echo $LOGIN_STATUS | grep -o "[0-9]*") == "200" ]]; then
        echo "✓ Login test PASSED"
        LOGIN_SUCCESS=true
    else
        echo "✗ Login test FAILED"
        LOGIN_SUCCESS=false
    fi
fi

if [ "$LOGIN_SUCCESS" = true ]; then
    # Test /me endpoint
    echo "Testing /me endpoint..."
    ME_RESPONSE=$(curl -s --cookie cookies.txt -w "\nstatus_code:%{http_code}" -X GET \
        http://localhost:8082/me)
        
    ME_STATUS=$(echo "$ME_RESPONSE" | tail -n1)
    ME_BODY=$(echo "$ME_RESPONSE" | head -n-1)
    echo "Me response: $ME_BODY"
    echo "Status Code: $(echo $ME_STATUS | grep -o "[0-9]*")"
    
    if [[ $(echo $ME_STATUS | grep -o "[0-9]*") == "200" ]]; then
        echo "✓ Me test PASSED"
        ME_SUCCESS=true
    else
        echo "✗ Me test FAILED"
        ME_SUCCESS=false
    fi
fi

if [ "$LOGIN_SUCCESS" = true ]; then
    # Test creating a todo
    echo "Testing create todo..."
    TODO_RESPONSE=$(curl -s --cookie cookies.txt -w "\nstatus_code:%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d '{"title":"Test Todo", "description":"This is a test"}' \
        http://localhost:8082/todos)
    
    TODO_STATUS=$(echo "$TODO_RESPONSE" | tail -n1)
    TODO_BODY=$(echo "$TODO_RESPONSE" | head -n-1) 
    echo "Todo response: $TODO_BODY"
    echo "Status Code: $(echo $TODO_STATUS | grep -o "[0-9]*")"
    
    TODO_ID=$(echo $TODO_BODY | grep -o '"id":[0-9]*' | cut -d: -f2)
    if [[ $(echo $TODO_STATUS | grep -o "[0-9]*") == "201" ]] && [ -n "$TODO_ID" ]; then
        echo "✓ Create todo test PASSED (ID: $TODO_ID)"
        CREATE_TODO_SUCCESS=true
    else
        echo "✗ Create todo test FAILED"
        CREATE_TODO_SUCCESS=false
    fi
fi

if [ "$CREATE_TODO_SUCCESS" = true ]; then
    # Test getting a specific todo
    echo "Testing getting specific todo..."
    GET_TODO_RESPONSE=$(curl -s --cookie cookies.txt -w "\nstatus_code:%{http_code}" -X GET \
        http://localhost:8082/todos/$TODO_ID)
    
    GET_TODO_STATUS=$(echo "$GET_TODO_RESPONSE" | tail -n1)
    GET_TODO_BODY=$(echo "$GET_TODO_RESPONSE" | head -n-1) 
    echo "Get Todo response: $GET_TODO_BODY"
    echo "Status Code: $(echo $GET_TODO_STATUS | grep -o "[0-9]*")"
    
    if [[ $(echo $GET_TODO_STATUS | grep -o "[0-9]*") == "200" ]]; then
        echo "✓ Get todo test PASSED"
        GET_TODO_SUCCESS=true
    else
        echo "✗ Get todo test FAILED"
        GET_TODO_SUCCESS=false
    fi
fi

if [ "$CREATE_TODO_SUCCESS" = true ]; then
    # Test updating a todo
    echo "Testing update todo..."
    UPDATE_TODO_RESPONSE=$(curl -s --cookie cookies.txt -w "\nstatus_code:%{http_code}" -X PUT \
        -H "Content-Type: application/json" \
        -d '{"title":"Updated Todo", "completed":true}' \
        http://localhost:8082/todos/$TODO_ID)
    
    UPDATE_TODO_STATUS=$(echo "$UPDATE_TODO_RESPONSE" | tail -n1)
    UPDATE_TODO_BODY=$(echo "$UPDATE_TODO_RESPONSE" | head -n-1) 
    echo "Update Todo response: $UPDATE_TODO_BODY"
    echo "Status Code: $(echo $UPDATE_TODO_STATUS | grep -o "[0-9]*")"
    
    if [[ $(echo $UPDATE_TODO_STATUS | grep -o "[0-9]*") == "200" ]]; then
        echo "✓ Update todo test PASSED"
        UPDATE_TODO_SUCCESS=true
    else
        echo "✗ Update todo test FAILED"
        UPDATE_TODO_SUCCESS=false
    fi
fi

if [ "$CREATE_TODO_SUCCESS" = true ]; then
    # Test deleting a todo
    echo "Testing delete todo..."
    DEL_TODO_RESPONSE=$(curl -s --cookie cookies.txt -w "\nstatus_code:%{http_code}" -X DELETE \
        http://localhost:8082/todos/$TODO_ID)
    
    DEL_TODO_STATUS=$(echo "$DEL_TODO_RESPONSE" | tail -n1)
    echo "Delete Todo status: $(echo $DEL_TODO_STATUS | grep -o "[0-9]*")"
    
    if [[ $(echo $DEL_TODO_STATUS | grep -o "[0-9]*") == "204" ]]; then
        echo "✓ Delete todo test PASSED"
        DEL_TODO_SUCCESS=true
    else
        echo "✗ Delete todo test FAILED"
        DEL_TODO_SUCCESS=false
    fi
fi

if [ "$LOGIN_SUCCESS" = true ]; then
    # Test logout
    echo "Testing logout..."
    LOGOUT_RESPONSE=$(curl -s --cookie cookies.txt --cookie-jar cookies_after_logout.txt -w "\nstatus_code:%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d '{}' \
        http://localhost:8082/logout)
    
    LOGOUT_STATUS=$(echo "$LOGOUT_RESPONSE" | tail -n1)
    LOGOUT_BODY=$(echo "$LOGOUT_RESPONSE" | head -n-1) 
    echo "Logout response: $LOGOUT_BODY"
    echo "Status Code: $(echo $LOGOUT_STATUS | grep -o "[0-9]*")"
    
    if [[ $(echo $LOGOUT_STATUS | grep -o "[0-9]*") == "200" ]]; then
        echo "✓ Logout test PASSED"
    else
        echo "✗ Logout test FAILED"
    fi
fi

# Clean up
rm -f cookies.txt cookies_after_logout.txt 2>/dev/null
kill $SERVER_PID 2>/dev/null

# Summary
echo "======= SUMMARY ========"
echo "Total Tests: $TOTAL_TESTS"
if [ $FAIL_COUNT -eq 0 ]; then
    echo "Status: ALL TESTS PASSED! ✓"
else 
    echo "Failed: $FAIL_COUNT tests"
    echo "Status: SOME TESTS FAILED ✗"
fi