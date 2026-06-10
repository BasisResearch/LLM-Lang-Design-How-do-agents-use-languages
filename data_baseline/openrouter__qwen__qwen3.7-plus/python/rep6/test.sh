#!/bin/bash
set -e

# Ensure flask is installed
pip install flask > /dev/null 2>&1 || true

PORT=8080
HOST="http://localhost:$PORT"

echo "Starting server..."
python3 server.py --port $PORT &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt cookies1.txt cookies2.txt
}
trap cleanup EXIT

run_curl() {
    curl -s -S -w "\n%{http_code}" "$@"
}

assert_json() {
    local code=$1
    local expected_code=$2
    local json_str=$3
    local python_check=$4
    
    if [ "$code" != "$expected_code" ]; then
        echo "FAIL: Expected status $expected_code, got $code. Body: $json_str"
        exit 1
    fi
    if [ -n "$python_check" ]; then
        echo "$json_str" | python3 -c "import sys, json; d=json.load(sys.stdin); $python_check" || {
            echo "FAIL: JSON validation failed. Body: $json_str"
            exit 1
        }
    fi
    echo "PASS"
}

echo "Test 1: Register new user"
RESP=$(run_curl -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "201" "$BODY" "assert d['id'] == 1 and d['username'] == 'testuser'"

echo "Test 2: Register duplicate user"
RESP=$(run_curl -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "409" "$BODY" "assert d['error'] == 'Username already exists'"

echo "Test 3: Login"
RESP=$(run_curl -X POST "$HOST/login" -H "Content-Type: application/json" -c cookies.txt -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "200" "$BODY" "assert d['id'] == 1 and d['username'] == 'testuser'"

echo "Test 4: Get /me"
RESP=$(run_curl -X GET "$HOST/me" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "200" "$BODY" "assert d['username'] == 'testuser'"

echo "Test 5: Get /me without auth"
RESP=$(run_curl -X GET "$HOST/me")
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "401" "$BODY" "assert d['error'] == 'Authentication required'"

echo "Test 6: Change password"
RESP=$(run_curl -X PUT "$HOST/password" -b cookies.txt -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "200" "$BODY" ""

echo "Test 7: Create todo"
RESP=$(run_curl -X POST "$HOST/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title": "First Todo", "description": "My first todo"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "201" "$BODY" "assert d['title'] == 'First Todo' and d['completed'] == False and 'created_at' in d and 'updated_at' in d"

echo "Test 8: Get todos"
RESP=$(run_curl -X GET "$HOST/todos" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "200" "$BODY" "assert len(d) == 1 and d[0]['title'] == 'First Todo'"

echo "Test 9: Get specific todo"
TODO_ID=$(echo "$BODY" | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['id'])")
RESP=$(run_curl -X GET "$HOST/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "200" "$BODY" "assert d['title'] == 'First Todo'"

echo "Test 10: Update todo"
RESP=$(run_curl -X PUT "$HOST/todos/$TODO_ID" -b cookies.txt -H "Content-Type: application/json" -d '{"completed": true}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "200" "$BODY" "assert d['completed'] == True and d['title'] == 'First Todo'"

echo "Test 11: Delete todo"
RESP=$(run_curl -X DELETE "$HOST/todos/$TODO_ID" -b cookies.txt -w "%{http_code}")
CODE=$(echo "$RESP" | tail -n1)
if [ "$CODE" != "204" ]; then
    echo "FAIL: Expected 204, got $CODE"
    exit 1
fi
echo "PASS"

echo "Test 12: Get deleted todo"
RESP=$(run_curl -X GET "$HOST/todos/$TODO_ID" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "404" "$BODY" "assert d['error'] == 'Todo not found'"

echo "Test 13: Logout"
RESP=$(run_curl -X POST "$HOST/logout" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "200" "$BODY" ""

echo "Test 14: Get /me after logout"
RESP=$(run_curl -X GET "$HOST/me" -b cookies.txt)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "401" "$BODY" "assert d['error'] == 'Authentication required'"

echo "Test 15: Todo enumeration check (other user)"
run_curl -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' > /dev/null
run_curl -X POST "$HOST/login" -H "Content-Type: application/json" -c cookies2.txt -d '{"username": "user2", "password": "password123"}' > /dev/null
RESP=$(run_curl -X POST "$HOST/todos" -b cookies2.txt -H "Content-Type: application/json" -d '{"title": "User2 Todo"}')
TODO2_ID=$(echo "$RESP" | sed '$d' | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
run_curl -X POST "$HOST/login" -H "Content-Type: application/json" -c cookies1.txt -d '{"username": "testuser", "password": "newpassword123"}' > /dev/null
RESP=$(run_curl -X GET "$HOST/todos/$TODO2_ID" -b cookies1.txt)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "404" "$BODY" "assert d['error'] == 'Todo not found'"

echo "Test 16: Invalid username format"
RESP=$(run_curl -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "invalid-user!", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "400" "$BODY" "assert d['error'] == 'Invalid username'"

echo "Test 17: Password too short"
RESP=$(run_curl -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "validuser2", "password": "short"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "400" "$BODY" "assert d['error'] == 'Password too short'"

echo "Test 18: Invalid credentials on login"
RESP=$(run_curl -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "401" "$BODY" "assert d['error'] == 'Invalid credentials'"

echo "Test 19: Empty title on create todo"
RESP=$(run_curl -X POST "$HOST/todos" -b cookies1.txt -H "Content-Type: application/json" -d '{"title": ""}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "400" "$BODY" "assert d['error'] == 'Title is required'"

echo "Test 20: Old password mismatch"
RESP=$(run_curl -X PUT "$HOST/password" -b cookies1.txt -H "Content-Type: application/json" -d '{"old_password": "wrong", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
assert_json "$CODE" "401" "$BODY" "assert d['error'] == 'Invalid credentials'"

echo "All tests passed!"
