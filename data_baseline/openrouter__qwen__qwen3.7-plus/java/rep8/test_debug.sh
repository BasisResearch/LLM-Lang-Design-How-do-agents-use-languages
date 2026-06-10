#!/bin/bash
set -e

PORT=8888
BASE_URL="http://localhost:$PORT"

./run.sh --port $PORT &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt
    exit 0
}
trap cleanup EXIT

curl -s -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' > /dev/null
curl -s -c cookies.txt -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username":"testuser","password":"password123"}' > /dev/null
RES_BODY=$(curl -s -b cookies.txt -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -d '{"title":"My Todo","description":"Do this"}')
TODO_ID=$(echo "$RES_BODY" | sed -n 's/.*"id": *\([0-9]*\).*/\1/p')
echo "Created todo ID: $TODO_ID"

RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -b cookies.txt -H "Content-Type: application/json" -d '{"completed":true}')
echo "Full RES:"
echo "$RES"
echo "CODE:"
echo "$RES" | tail -n1
echo "Checking grep:"
if echo "$RES" | grep -q '"completed": *true'; then
    echo "Match found!"
else
    echo "No match!"
fi
