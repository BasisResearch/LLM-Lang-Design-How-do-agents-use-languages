#!/bin/bash
set -e

PORT=8888
BASE_URL="http://localhost:$PORT"

# Start server in background
./run.sh --port $PORT &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    rm -f cookies.txt /tmp/res.txt
}
trap cleanup EXIT

echo "Testing POST /register"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
[ "$CODE" -eq 201 ] && echo "✅ PASS: register valid" || { echo "❌ FAIL: register valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "ab", "password": "password123"}')
[ "$CODE" -eq 400 ] && echo "✅ PASS: register short username" || { echo "❌ FAIL: register short username (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X POST "$BASE_URL/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
[ "$CODE" -eq 409 ] && echo "✅ PASS: register duplicate" || { echo "❌ FAIL: register duplicate (got $CODE)"; cat /tmp/res.txt; exit 1; }

echo "Testing POST /login"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' -c cookies.txt)
[ "$CODE" -eq 200 ] && echo "✅ PASS: login valid" || { echo "❌ FAIL: login valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X POST "$BASE_URL/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpass"}')
[ "$CODE" -eq 401 ] && echo "✅ PASS: login invalid" || { echo "❌ FAIL: login invalid (got $CODE)"; cat /tmp/res.txt; exit 1; }

echo "Testing GET /me"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
[ "$CODE" -eq 200 ] && echo "✅ PASS: me valid" || { echo "❌ FAIL: me valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X GET "$BASE_URL/me")
[ "$CODE" -eq 401 ] && echo "✅ PASS: me unauthenticated" || { echo "❌ FAIL: me unauthenticated (got $CODE)"; cat /tmp/res.txt; exit 1; }

echo "Testing PUT /password"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "password123", "new_password": "newpassword123"}')
[ "$CODE" -eq 200 ] && echo "✅ PASS: password change valid" || { echo "❌ FAIL: password change valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X PUT "$BASE_URL/password" -H "Content-Type: application/json" -b cookies.txt -d '{"old_password": "wrong", "new_password": "newpassword123"}')
[ "$CODE" -eq 401 ] && echo "✅ PASS: password change invalid old" || { echo "❌ FAIL: password change invalid old (got $CODE)"; cat /tmp/res.txt; exit 1; }

echo "Testing POST /todos"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": "First Todo", "description": "Do this"}')
[ "$CODE" -eq 201 ] && echo "✅ PASS: post todo valid" || { echo "❌ FAIL: post todo valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X POST "$BASE_URL/todos" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
[ "$CODE" -eq 400 ] && echo "✅ PASS: post todo empty title" || { echo "❌ FAIL: post todo empty title (got $CODE)"; cat /tmp/res.txt; exit 1; }

echo "Testing GET /todos"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X GET "$BASE_URL/todos" -b cookies.txt)
[ "$CODE" -eq 200 ] && echo "✅ PASS: get todos valid" || { echo "❌ FAIL: get todos valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

TODO_ID=$(cat /tmp/res.txt | grep -o '"id":[0-9]*' | head -1 | cut -d':' -f2)
echo "Found TODO_ID: $TODO_ID"

echo "Testing GET /todos/:id"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X GET "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
[ "$CODE" -eq 200 ] && echo "✅ PASS: get todo valid" || { echo "❌ FAIL: get todo valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X GET "$BASE_URL/todos/9999" -b cookies.txt)
[ "$CODE" -eq 404 ] && echo "✅ PASS: get todo not found" || { echo "❌ FAIL: get todo not found (got $CODE)"; cat /tmp/res.txt; exit 1; }

echo "Testing PUT /todos/:id"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"completed": true}')
[ "$CODE" -eq 200 ] && echo "✅ PASS: put todo valid" || { echo "❌ FAIL: put todo valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X PUT "$BASE_URL/todos/$TODO_ID" -H "Content-Type: application/json" -b cookies.txt -d '{"title": ""}')
[ "$CODE" -eq 400 ] && echo "✅ PASS: put todo empty title" || { echo "❌ FAIL: put todo empty title (got $CODE)"; cat /tmp/res.txt; exit 1; }

echo "Testing DELETE /todos/:id"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
[ "$CODE" -eq 204 ] && echo "✅ PASS: delete todo valid" || { echo "❌ FAIL: delete todo valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X DELETE "$BASE_URL/todos/$TODO_ID" -b cookies.txt)
[ "$CODE" -eq 404 ] && echo "✅ PASS: delete todo not found" || { echo "❌ FAIL: delete todo not found (got $CODE)"; cat /tmp/res.txt; exit 1; }

echo "Testing POST /logout"
CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X POST "$BASE_URL/logout" -b cookies.txt)
[ "$CODE" -eq 200 ] && echo "✅ PASS: logout valid" || { echo "❌ FAIL: logout valid (got $CODE)"; cat /tmp/res.txt; exit 1; }

CODE=$(curl -s -o /tmp/res.txt -w "%{http_code}" -X GET "$BASE_URL/me" -b cookies.txt)
[ "$CODE" -eq 401 ] && echo "✅ PASS: me after logout" || { echo "❌ FAIL: me after logout (got $CODE)"; cat /tmp/res.txt; exit 1; }

echo "All tests passed!"
