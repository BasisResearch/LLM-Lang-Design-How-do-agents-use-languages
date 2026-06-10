#!/bin/bash
set -e

PORT=8082
echo "Starting server on port $PORT..."
cargo run --release -- --port $PORT &
SERVER_PID=$!
sleep 2

BASE_URL="http://localhost:$PORT"

get_code() {
    echo "$1" | tail -n1
}

echo "1. Testing register user1..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/register -H "Content-Type: application/json" -d '{"username": "user1", "password": "password123"}')
[ "$(get_code "$RES")" == "201" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "2. Testing login user1..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/login -H "Content-Type: application/json" -d '{"username": "user1", "password": "password123"}' -c cookies1.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "3. Testing register user2..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/register -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}')
[ "$(get_code "$RES")" == "201" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "4. Testing login user2..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/login -H "Content-Type: application/json" -d '{"username": "user2", "password": "password123"}' -c cookies2.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "5. Testing create todo for user1..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/todos -H "Content-Type: application/json" -d '{"title": "User1 Todo"}' -b cookies1.txt)
[ "$(get_code "$RES")" == "201" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

echo "6. Testing user2 accessing user1's todo (should be 404)..."
RES=$(curl -s -w "\n%{http_code}" $BASE_URL/todos/$TODO_ID -b cookies2.txt)
[ "$(get_code "$RES")" == "404" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "7. Testing user2 updating user1's todo (should be 404)..."
RES=$(curl -s -w "\n%{http_code}" -X PUT $BASE_URL/todos/$TODO_ID -H "Content-Type: application/json" -d '{"completed": true}' -b cookies2.txt)
[ "$(get_code "$RES")" == "404" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "8. Testing user2 deleting user1's todo (should be 404)..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE $BASE_URL/todos/$TODO_ID -b cookies2.txt)
[ "$(get_code "$RES")" == "404" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "9. Testing user1 can still access their todo..."
RES=$(curl -s -w "\n%{http_code}" $BASE_URL/todos/$TODO_ID -b cookies1.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

kill $SERVER_PID
rm -f cookies1.txt cookies2.txt
echo "All cross-user isolation tests passed!"
