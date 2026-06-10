#!/bin/bash
set -e

PORT=9999
echo "Starting server on port $PORT..."
python3 server.py --port $PORT &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

trap "kill $SERVER_PID 2>/dev/null || true" EXIT

sleep 2

echo "Testing valid registration..."
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/register -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "password123"}')
STATUS=$(echo "$RESP" | tail -n1)
if [ "$STATUS" == "201" ]; then echo "✅ PASS"; else echo "❌ FAIL: $STATUS"; exit 1; fi

echo "Testing login..."
RESP=$(curl -s -i -X POST http://localhost:$PORT/login -H "Content-Type: application/json" -d '{"username": "testuser1", "password": "password123"}')
STATUS=$(echo "$RESP" | grep -i "^HTTP/" | awk '{print $2}')
COOKIE=$(echo "$RESP" | grep -i "^Set-Cookie:" | tr -d '\r' | sed 's/Set-Cookie: //i' | cut -d';' -f1)
if [ "$STATUS" == "200" ]; then echo "✅ PASS: Cookie: $COOKIE"; else echo "❌ FAIL: $STATUS"; exit 1; fi

echo "Testing /me..."
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/me -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
if [ "$STATUS" == "200" ]; then echo "✅ PASS"; else echo "❌ FAIL: $STATUS"; exit 1; fi

echo "Testing create todo..."
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/todos -H "Cookie: $COOKIE" -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Test"}')
STATUS=$(echo "$RESP" | tail -n1)
if [ "$STATUS" == "201" ]; then echo "✅ PASS"; else echo "❌ FAIL: $STATUS"; exit 1; fi
TODO_ID=$(echo "$RESP" | sed '$d' | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
echo "TODO_ID: $TODO_ID"

echo "Testing get todos..."
RESP=$(curl -s -w "\n%{http_code}" http://localhost:$PORT/todos -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
if [ "$STATUS" == "200" ]; then echo "✅ PASS"; else echo "❌ FAIL: $STATUS"; exit 1; fi

echo "Testing delete todo..."
RESP=$(curl -s -w "\n%{http_code}" -X DELETE http://localhost:$PORT/todos/$TODO_ID -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
if [ "$STATUS" == "204" ]; then echo "✅ PASS"; else echo "❌ FAIL: $STATUS"; exit 1; fi

echo "Testing logout..."
RESP=$(curl -s -w "\n%{http_code}" -X POST http://localhost:$PORT/logout -H "Cookie: $COOKIE")
STATUS=$(echo "$RESP" | tail -n1)
if [ "$STATUS" == "200" ]; then echo "✅ PASS"; else echo "❌ FAIL: $STATUS"; exit 1; fi

echo ""
echo "🎉 All basic tests passed! 🎉"
