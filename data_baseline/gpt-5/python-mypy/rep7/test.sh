#!/usr/bin/env bash
set -euo pipefail
PORT=8099
./run.sh --port "$PORT" &
SERVER_PID=$!
trap 'kill $SERVER_PID >/dev/null 2>&1 || true' EXIT
# wait for server to start
sleep 1
base="http://127.0.0.1:$PORT"

header_json='-H Content-Type: application/json'

# Register
resp=$(curl -s -D - $header_json -X POST "$base/register" -d '{"username":"alice_1","password":"password123"}')
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "201" ]]; then echo "Register failed"; echo "$resp"; exit 1; fi

# Login
resp=$(curl -s -D - $header_json -X POST "$base/login" -d '{"username":"alice_1","password":"password123"}')
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "200" ]]; then echo "Login failed"; echo "$resp"; exit 1; fi
cookie=$(grep -i '^Set-Cookie:' /tmp/resp.txt | sed -n 's/Set-Cookie: //p' | awk -F';' '{print $1}')

# Me
resp=$(curl -s -D - -H "Cookie: $cookie" "$base/me")
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "200" ]]; then echo "Me failed"; echo "$resp"; exit 1; fi

# Create todo
resp=$(curl -s -D - -H "Cookie: $cookie" $header_json -X POST "$base/todos" -d '{"title":"Task A","description":"First"}')
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "201" ]]; then echo "Create todo failed"; echo "$resp"; exit 1; fi

# List todos
resp=$(curl -s -D - -H "Cookie: $cookie" "$base/todos")
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "200" ]]; then echo "List todos failed"; echo "$resp"; exit 1; fi

# Get todo id 1
resp=$(curl -s -D - -H "Cookie: $cookie" "$base/todos/1")
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "200" ]]; then echo "Get todo failed"; echo "$resp"; exit 1; fi

# Update todo
resp=$(curl -s -D - -H "Cookie: $cookie" $header_json -X PUT "$base/todos/1" -d '{"completed":true}')
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "200" ]]; then echo "Update todo failed"; echo "$resp"; exit 1; fi

# Change password
resp=$(curl -s -D - -H "Cookie: $cookie" $header_json -X PUT "$base/password" -d '{"old_password":"password123","new_password":"newpassword456"}')
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "200" ]]; then echo "Password change failed"; echo "$resp"; exit 1; fi

# Logout
resp=$(curl -s -D - -H "Cookie: $cookie" -X POST "$base/logout")
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "200" ]]; then echo "Logout failed"; echo "$resp"; exit 1; fi

# After logout, access should be 401
resp=$(curl -s -D - -H "Cookie: $cookie" "$base/me")
echo "$resp" | tr -d '\r' > /tmp/resp.txt
status=$(head -n1 /tmp/resp.txt | awk '{print $2}')
if [[ "$status" != "401" ]]; then echo "Post-logout auth failed"; echo "$resp"; exit 1; fi

echo "All tests passed"
