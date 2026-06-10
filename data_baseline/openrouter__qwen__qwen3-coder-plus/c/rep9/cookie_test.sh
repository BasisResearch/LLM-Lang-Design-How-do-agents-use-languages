#!/bin/bash

# Manual session cookie test
echo "Starting server..."

timeout 15s ./server --port 8080 &
SERVER_PID=$!
sleep 1

echo "Step 1: Register a user"
curl -X POST http://localhost:8080/register \
  -H "Content-Type: application/json" \
  -d '{"username": "ctest", "password": "password123"}'

echo -e "\nStep 2: Login to get session cookie"
# Capture the exact session ID from login response header
SESSION_COOKIE=$(curl -s -D - -o /dev/null http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username": "ctest", "password": "password123"}' | grep -i set-cookie | cut -d'=' -f2- | cut -d';' -f1)

echo "Extracted session cookie: $SESSION_COOKIE"

if [ -n "$SESSION_COOKIE" ]; then
  echo -e "\nStep 3: Access protected /me endpoint with cookie"
  curl -H "Cookie: session_id=$SESSION_COOKIE" http://localhost:8080/me
  echo

  echo -e "\nStep 4: Create a todo with cookie"
  curl -X POST http://localhost:8080/todos \
    -H "Content-Type: application/json" \
    -H "Cookie: session_id=$SESSION_COOKIE" \
    -d '{"title": "Test Todo", "description": "A test todo"}'
  echo
else
  echo "No session cookie obtained!"
fi

# Stop server
kill $SERVER_PID 2>/dev/null || true
rm -f /dev/null