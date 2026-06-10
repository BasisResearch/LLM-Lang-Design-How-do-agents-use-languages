#!/bin/bash
set -e

PORT=8484

# Start server in background
./server --port $PORT &
SERVER_PID=$!
sleep 1

# Helper function to clean up and exit
cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

HOST="http://localhost:$PORT"

echo "Testing POST /register (success)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
    echo "FAILED: Expected 201, got $CODE"
    echo "Body: $RES"
    exit 1
fi

echo "Testing POST /register (invalid username - too short)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAILED: Expected 400, got $CODE"
    exit 1
fi

echo "Testing POST /register (invalid username - special chars)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "user@name", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAILED: Expected 400, got $CODE"
    exit 1
fi

echo "Testing POST /register (password too short)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "user123", "password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAILED: Expected 400, got $CODE"
    exit 1
fi

echo "Testing POST /register (username already exists)"
RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "409" ]; then
    echo "FAILED: Expected 409, got $CODE"
    exit 1
fi

echo "Testing POST /login (success)"
RES_RAW=$(curl -s -i -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
# Extract HTTP code from header
CODE=$(echo "$RES_RAW" | head -n1 | awk '{print $2}')
if [ "$CODE" != "200" ]; then
    echo "FAILED: Expected 200, got $CODE"
    echo "Body: $RES_RAW"
    exit 1
fi
COOKIE=$(echo "$RES_RAW" | grep -i "^Set-Cookie:" | sed 's/^Set-Cookie:[ \t]*//i' | sed 's/;.*//')
echo "Got cookie: $COOKIE"

echo "Testing GET /me (success)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" "$HOST/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAILED: Expected 200, got $CODE"
    echo "Body: $RES"
    exit 1
fi

echo "Testing PUT /password (success)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X PUT "$HOST/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAILED: Expected 200, got $CODE"
    echo "Body: $RES"
    exit 1
fi

echo "Testing PUT /password (invalid credentials)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X PUT "$HOST/password" -H "Content-Type: application/json" -d '{"old_password": "wrongpassword", "new_password": "newpassword123"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAILED: Expected 401, got $CODE"
    exit 1
fi

echo "Testing PUT /password (password too short)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X PUT "$HOST/password" -H "Content-Type: application/json" -d '{"old_password": "newpassword123", "new_password": "short"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAILED: Expected 400, got $CODE"
    exit 1
fi

echo "Testing POST /todos (success)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X POST "$HOST/todos" -H "Content-Type: application/json" -d '{"title": "Test Todo", "description": "Test Description"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ]; then
    echo "FAILED: Expected 201, got $CODE"
    echo "Body: $RES"
    exit 1
fi
TODO_ID=$(echo "$BODY" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
echo "Created todo with ID: $TODO_ID"

echo "Testing POST /todos (missing title)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X POST "$HOST/todos" -H "Content-Type: application/json" -d '{"description": "Test"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAILED: Expected 400, got $CODE"
    exit 1
fi

echo "Testing POST /todos (empty title)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X POST "$HOST/todos" -H "Content-Type: application/json" -d '{"title": "", "description": "Test"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAILED: Expected 400, got $CODE"
    exit 1
fi

echo "Testing GET /todos (success)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" "$HOST/todos")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAILED: Expected 200, got $CODE"
    exit 1
fi

echo "Testing GET /todos/:id (success)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" "$HOST/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAILED: Expected 200, got $CODE"
    exit 1
fi

echo "Testing PUT /todos/:id (success)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X PUT "$HOST/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"completed": true}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAILED: Expected 200, got $CODE"
    exit 1
fi

echo "Testing PUT /todos/:id (empty title)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X PUT "$HOST/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"title": ""}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "400" ]; then
    echo "FAILED: Expected 400, got $CODE"
    exit 1
fi

# Create another user and todo to test cross-user protection
curl -s -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' >/dev/null
RES2_RAW=$(curl -s -i -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}')
COOKIE2=$(echo "$RES2_RAW" | grep -i "^Set-Cookie:" | sed 's/^Set-Cookie:[ \t]*//i' | sed 's/;.*//')
RES_TODO2=$(curl -s -b "$COOKIE2" -X POST "$HOST/todos" -H "Content-Type: application/json" -d '{"title": "User2 Todo", "description": "Test"}')
TODO_ID_2=$(echo "$RES_TODO2" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
echo "Created User2 todo with ID: $TODO_ID_2"

echo "Testing GET /todos/:id for another user's todo (should be 404)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" "$HOST/todos/$TODO_ID_2")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
    echo "FAILED: Expected 404, got $CODE"
    exit 1
fi

echo "Testing PUT /todos/:id for another user's todo (should be 404)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X PUT "$HOST/todos/$TODO_ID_2" -H "Content-Type: application/json" -d '{"title": "Hacked"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
    echo "FAILED: Expected 404, got $CODE"
    exit 1
fi

echo "Testing DELETE /todos/:id for another user's todo (should be 404)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X DELETE "$HOST/todos/$TODO_ID_2")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
    echo "FAILED: Expected 404, got $CODE"
    exit 1
fi

echo "Testing DELETE /todos/:id (success)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X DELETE "$HOST/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "204" ]; then
    echo "FAILED: Expected 204, got $CODE"
    exit 1
fi

echo "Testing GET /todos/:id after delete (should be 404)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" "$HOST/todos/$TODO_ID")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "404" ]; then
    echo "FAILED: Expected 404, got $CODE"
    exit 1
fi

echo "Testing POST /logout (success)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X POST "$HOST/logout")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "FAILED: Expected 200, got $CODE"
    exit 1
fi

echo "Testing GET /me after logout (should be 401)"
RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" "$HOST/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAILED: Expected 401, got $CODE"
    exit 1
fi

echo "Testing GET /me without auth (should be 401)"
RES=$(curl -s -w "\n%{http_code}" "$HOST/me")
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "401" ]; then
    echo "FAILED: Expected 401, got $CODE"
    exit 1
fi

echo "All tests passed!"