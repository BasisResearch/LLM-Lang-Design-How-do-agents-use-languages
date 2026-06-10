#!/bin/bash
set -e

PORT=8081
echo "Starting server on port $PORT..."
cargo run --release -- --port $PORT &
SERVER_PID=$!
sleep 2

BASE_URL="http://localhost:$PORT"

get_code() {
    echo "$1" | tail -n1
}

echo "1. Testing register with invalid username (too short)..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/register -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
[ "$(get_code "$RES")" == "400" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "2. Testing register with short password..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/register -H "Content-Type: application/json" -d '{"username": "validuser", "password": "short"}')
[ "$(get_code "$RES")" == "400" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "3. Testing register success..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/register -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
[ "$(get_code "$RES")" == "201" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "4. Testing register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/register -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
[ "$(get_code "$RES")" == "409" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "5. Testing login with invalid credentials..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/login -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrong"}')
[ "$(get_code "$RES")" == "401" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "6. Testing login success..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/login -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "7. Testing me..."
RES=$(curl -s -w "\n%{http_code}" $BASE_URL/me -b cookies.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "8. Testing change password..."
RES=$(curl -s -w "\n%{http_code}" -X PUT $BASE_URL/password -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}' -b cookies.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "9. Testing create todo..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/todos -H "Content-Type: application/json" -d '{"title": "Buy milk", "description": "Get 2% milk"}' -b cookies.txt)
[ "$(get_code "$RES")" == "201" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

echo "10. Testing create todo with missing title..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/todos -H "Content-Type: application/json" -d '{"description": "No title"}' -b cookies.txt)
[ "$(get_code "$RES")" == "400" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "11. Testing get todos..."
RES=$(curl -s -w "\n%{http_code}" $BASE_URL/todos -b cookies.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "12. Testing get todo by ID..."
RES=$(curl -s -w "\n%{http_code}" $BASE_URL/todos/$TODO_ID -b cookies.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "13. Testing update todo with empty title..."
RES=$(curl -s -w "\n%{http_code}" -X PUT $BASE_URL/todos/$TODO_ID -H "Content-Type: application/json" -d '{"title": ""}' -b cookies.txt)
[ "$(get_code "$RES")" == "400" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "14. Testing update todo..."
RES=$(curl -s -w "\n%{http_code}" -X PUT $BASE_URL/todos/$TODO_ID -H "Content-Type: application/json" -d '{"completed": true}' -b cookies.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "15. Testing delete todo..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE $BASE_URL/todos/$TODO_ID -b cookies.txt)
[ "$(get_code "$RES")" == "204" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "16. Testing delete non-existent todo..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE $BASE_URL/todos/999 -b cookies.txt)
[ "$(get_code "$RES")" == "404" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "17. Testing logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST $BASE_URL/logout -b cookies.txt)
[ "$(get_code "$RES")" == "200" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "18. Testing auth after logout..."
RES=$(curl -s -w "\n%{http_code}" $BASE_URL/me -b cookies.txt)
[ "$(get_code "$RES")" == "401" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

echo "19. Testing missing auth..."
RES=$(curl -s -w "\n%{http_code}" $BASE_URL/me)
[ "$(get_code "$RES")" == "401" ] || { echo "FAILED: $RES"; kill $SERVER_PID; exit 1; }

kill $SERVER_PID
rm -f cookies.txt
echo "All tests passed!"
