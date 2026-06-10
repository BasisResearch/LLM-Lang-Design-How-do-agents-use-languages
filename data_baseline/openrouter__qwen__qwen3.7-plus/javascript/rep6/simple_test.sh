#!/bin/bash
set -e
PORT=3457
BASE="http://localhost:$PORT"

echo "Starting server..."
node server.js --port $PORT &
SERVER_PID=$!
sleep 2

echo "Testing register..."
RES=$(curl -s -w 'DELIM%{http_code}' -X POST "$BASE/register" -d '{"username": "user1", "password": "password123"}')
CODE="${RES##*DELIM}"
BODY="${RES%DELIM*}"
echo "Code: $CODE, Body: $BODY"

if [ "$CODE" != "201" ]; then
  echo "FAIL: Expected 201, got $CODE"
  kill $SERVER_PID
  exit 1
fi

echo "Testing login..."
RES=$(curl -s -w 'DELIM%{http_code}' -c cookies.txt -X POST "$BASE/login" -d '{"username": "user1", "password": "password123"}')
CODE="${RES##*DELIM}"
BODY="${RES%DELIM*}"
echo "Code: $CODE, Body: $BODY"

if [ "$CODE" != "200" ]; then
  echo "FAIL: Expected 200, got $CODE"
  kill $SERVER_PID
  exit 1
fi

echo "SUCCESS"
kill $SERVER_PID
