#!/bin/bash

# Kill any existing server on port 8080
pkill -f "java.*Server.*--port 8080" 2>/dev/null || true
sleep 1

echo "Starting server..."
java -cp .:gson.jar Server --port 8080 > server.log 2>&1 &
SERVER_PID=$!
sleep 2

# Helper function to check response
check_response() {
    local expected_code=$1
    local expected_pattern=$2
    local response=$3
    local code=$4

    if [ "$code" -eq "$expected_code" ]; then
        if [ -n "$expected_pattern" ]; then
            if echo "$response" | grep -q "$expected_pattern"; then
                echo "PASS: Status $expected_code, Body matches pattern"
            else
                echo "FAIL: Status $expected_code, but body doesn't match pattern"
                echo "Expected pattern: $expected_pattern"
                echo "Got: $response"
                exit 1
            fi
        else
            echo "PASS: Status $expected_code (no body check)"
        fi
    else
        echo "FAIL: Expected status $expected_code, got $code"
        echo "Got: $response"
        exit 1
    fi
}

rm -f cookies.txt

echo ""
echo "=== Testing /register ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 201 '"username":"testuser"' "$BODY" "$CODE"

echo ""
echo "=== Testing /register (duplicate) ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 409 '"Username already exists"' "$BODY" "$CODE"

echo ""
echo "=== Testing /register (short password) ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser2", "password": "short"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"Password too short"' "$BODY" "$CODE"

echo ""
echo "=== Testing /register (invalid username) ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"Invalid username"' "$BODY" "$CODE"

echo ""
echo "=== Testing /login ==="
RESP=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"username":"testuser"' "$BODY" "$CODE"

echo ""
echo "=== Testing /login (wrong password) ==="
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "wrongpassword"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 '"Invalid credentials"' "$BODY" "$CODE"

echo ""
echo "=== Testing /me ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:8080/me)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"username":"testuser"' "$BODY" "$CODE"

echo ""
echo "=== Testing /me (no cookie) ==="
RESP=$(curl -s -w "\n%{http_code}" http://localhost:8080/me)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 '"Authentication required"' "$BODY" "$CODE"

echo ""
echo "=== Testing /password ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '\{\}' "$BODY" "$CODE"

echo ""
echo "=== Testing /password (wrong old password) ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "wrongoldpassword", "new_password": "newpassword123"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 '"Invalid credentials"' "$BODY" "$CODE"

echo ""
echo "=== Testing /password (short new password) ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8080/password \
  -H "Content-Type: application/json" \
  -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"Password too short"' "$BODY" "$CODE"

echo ""
echo "=== Testing /todos (empty) ==="
# Login again with new password
curl -s -c cookies.txt -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "testuser", "password": "newpassword123"}' > /dev/null

RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:8080/todos)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '\[\]' "$BODY" "$CODE"

echo ""
echo "=== Testing POST /todos ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Test Todo", "description": "This is a test"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 201 '"title":"Test Todo"' "$BODY" "$CODE"

echo ""
echo "=== Testing POST /todos (missing title) ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"description": "No title"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"Title is required"' "$BODY" "$CODE"

echo ""
echo "=== Testing GET /todos ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:8080/todos)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"title":"Test Todo"' "$BODY" "$CODE"

echo ""
echo "=== Testing GET /todos/:id ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:8080/todos/1)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"title":"Test Todo"' "$BODY" "$CODE"

echo ""
echo "=== Testing GET /todos/:id (not found) ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:8080/todos/999)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 404 '"Todo not found"' "$BODY" "$CODE"

echo ""
echo "=== Testing PUT /todos/:id ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8080/todos/1 \
  -H "Content-Type: application/json" \
  -d '{"completed": true, "title": "Updated Title"}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '"completed":true' "$BODY" "$CODE"

echo ""
echo "=== Testing PUT /todos/:id (empty title) ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT http://localhost:8080/todos/1 \
  -H "Content-Type: application/json" \
  -d '{"title": ""}')
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 400 '"Title is required"' "$BODY" "$CODE"

echo ""
echo "=== Testing DELETE /todos/:id ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE http://localhost:8080/todos/1)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 204 "" "$BODY" "$CODE"

echo ""
echo "=== Testing DELETE /todos/:id (already deleted) ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE http://localhost:8080/todos/1)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 404 '"Todo not found"' "$BODY" "$CODE"

echo ""
echo "=== Testing /logout ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST http://localhost:8080/logout)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 200 '\{\}' "$BODY" "$CODE"

echo ""
echo "=== Testing /me after logout ==="
RESP=$(curl -s -w "\n%{http_code}" -b cookies.txt http://localhost:8080/me)
CODE=$(echo "$RESP" | tail -n1)
BODY=$(echo "$RESP" | sed '$d')
check_response 401 '"Authentication required"' "$BODY" "$CODE"

echo ""
echo "=== All tests passed! ==="

# Cleanup
kill $SERVER_PID 2>/dev/null || true