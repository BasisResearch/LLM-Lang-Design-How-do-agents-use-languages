#!/bin/bash
set -e

PORT=8888
BASE_URL="http://localhost:$PORT"

echo "Starting server in background..."
./run.sh --port $PORT &> server.log &
SERVER_PID=$!

# Wait for server to be ready
echo "Waiting for server to start..."
for i in {1..30}; do
    if curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/me" | grep -q "401"; then
        echo "Server is ready!"
        break
    fi
    sleep 1
done

cleanup() {
    echo "Stopping server..."
    kill $SERVER_PID 2>/dev/null || true
    cat server.log || true
}
trap cleanup EXIT

echo "=== Testing Registration ==="
# Valid registration
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
CODE=$(echo "$RES" | tail -n1)
BODY=$(echo "$RES" | sed '$d')
if [ "$CODE" != "201" ]; then
    echo "Failed: Expected 201, got $CODE. Body: $BODY"
    exit 1
fi
echo "Registration successful: $BODY"

# Invalid username (too short)
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
if [ "$(echo "$RES" | tail -n1)" != "400" ]; then
    echo "Failed: Expected 400 for short username"
    exit 1
fi

# Invalid username (bad chars)
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "test-user", "password": "password123"}')
if [ "$(echo "$RES" | tail -n1)" != "400" ]; then
    echo "Failed: Expected 400 for bad username chars"
    exit 1
fi

# Duplicate username
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
if [ "$(echo "$RES" | tail -n1)" != "409" ]; then
    echo "Failed: Expected 409 for duplicate username"
    exit 1
fi

# Password too short
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
if [ "$(echo "$RES" | tail -n1)" != "400" ]; then
    echo "Failed: Expected 400 for short password"
    exit 1
fi

echo "=== Testing Login ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "Failed: Expected 200 for login, got $CODE"
    exit 1
fi
echo "Login successful"

# Invalid credentials
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
if [ "$(echo "$RES" | tail -n1)" != "401" ]; then
    echo "Failed: Expected 401 for invalid credentials"
    exit 1
fi

echo "=== Testing Auth Required ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me")
if [ "$(echo "$RES" | tail -n1)" != "401" ]; then
    echo "Failed: Expected 401 for unauthenticated /me"
    exit 1
fi

echo "=== Testing /me ==="
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "200" ]; then
    echo "Failed: Expected 200 for /me, got $CODE"
    exit 1
fi
echo "/me successful: $(echo "$RES" | sed '$d')"

echo "=== Testing Password Change ==="
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
if [ "$(echo "$RES" | tail -n1)" != "200" ]; then
    echo "Failed: Expected 200 for password change"
    exit 1
fi

# Verify new password works
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}' -c cookies.txt)
if [ "$(echo "$RES" | tail -n1)" != "200" ]; then
    echo "Failed: Expected 200 for login with new password"
    exit 1
fi

echo "=== Testing Todos ==="
# Create todo
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "My Todo", "description": "A test todo"}')
CODE=$(echo "$RES" | tail -n1)
if [ "$CODE" != "201" ]; then
    echo "Failed: Expected 201 for create todo, got $CODE. Body: $(echo "$RES" | sed '$d')"
    exit 1
fi
TODO_BODY=$(echo "$RES" | sed '$d')
TODO_ID=$(echo "$TODO_BODY" | grep -o '"id":[0-9]*' | cut -d: -f2)
echo "Created todo: $TODO_BODY"

# Missing title
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"description": "No title"}')
if [ "$(echo "$RES" | tail -n1)" != "400" ]; then
    echo "Failed: Expected 400 for missing title"
    exit 1
fi

# Empty title
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
if [ "$(echo "$RES" | tail -n1)" != "400" ]; then
    echo "Failed: Expected 400 for empty title"
    exit 1
fi

# Get todos
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
if [ "$(echo "$RES" | tail -n1)" != "200" ]; then
    echo "Failed: Expected 200 for get todos, got $(echo "$RES" | tail -n1)"
    exit 1
fi
echo "Get todos successful: $(echo "$RES" | sed '$d')"

# Get specific todo
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
if [ "$(echo "$RES" | tail -n1)" != "200" ]; then
    echo "Failed: Expected 200 for get specific todo, got $(echo "$RES" | tail -n1)"
    exit 1
fi
echo "Get specific todo successful: $(echo "$RES" | sed '$d')"

# Get specific todo (not found)
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/9999" -b cookies.txt)
if [ "$(echo "$RES" | tail -n1)" != "404" ]; then
    echo "Failed: Expected 404 for non-existent todo"
    exit 1
fi

# Update todo
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true, "title": "Updated Title"}')
if [ "$(echo "$RES" | tail -n1)" != "200" ]; then
    echo "Failed: Expected 200 for update todo, got $(echo "$RES" | tail -n1)"
    exit 1
fi
echo "Update todo successful: $(echo "$RES" | sed '$d')"

# Update todo with empty title
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
if [ "$(echo "$RES" | tail -n1)" != "400" ]; then
    echo "Failed: Expected 400 for empty title update"
    exit 1
fi

# Delete todo
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
if [ "$(echo "$RES" | tail -n1)" != "204" ]; then
    echo "Failed: Expected 204 for delete todo, got $(echo "$RES" | tail -n1)"
    exit 1
fi
echo "Delete todo successful"

# Verify deleted
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
if [ "$(echo "$RES" | tail -n1)" != "404" ]; then
    echo "Failed: Expected 404 for deleted todo, got $(echo "$RES" | tail -n1)"
    exit 1
fi

echo "=== Testing Logout ==="
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
if [ "$(echo "$RES" | tail -n1)" != "200" ]; then
    echo "Failed: Expected 200 for logout, got $(echo "$RES" | tail -n1)"
    exit 1
fi

# Verify logout
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
if [ "$(echo "$RES" | tail -n1)" != "401" ]; then
    echo "Failed: Expected 401 for /me after logout, got $(echo "$RES" | tail -n1)"
    exit 1
fi

echo "=== All tests passed! ==="