#!/bin/bash
set -e

PORT=9998

# Start server in background
./run.sh --port $PORT &
SERVER_PID=$!
sleep 2

cleanup() {
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
}
trap cleanup EXIT

BASE="http://localhost:$PORT"

echo "Testing /register..."
res=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"testuser","password":"password123"}' "$BASE/register")
body=$(echo "$res" | head -n 1)
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 201 ]; then
    echo "FAIL: /register - expected 201, got $code"
    echo "$body"
    exit 1
fi
echo "PASS: /register"

echo "Testing /register invalid username (too short)..."
res=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"ab","password":"password123"}' "$BASE/register")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 400 ]; then
    echo "FAIL: /register invalid username (too short) - expected 400, got $code"
    exit 1
fi
echo "PASS: /register invalid username (too short)"

echo "Testing /register invalid username (special chars)..."
res=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"test!user","password":"password123"}' "$BASE/register")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 400 ]; then
    echo "FAIL: /register invalid username (special chars) - expected 400, got $code"
    exit 1
fi
echo "PASS: /register invalid username (special chars)"

echo "Testing /register password too short..."
res=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"otheruser","password":"short"}' "$BASE/register")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 400 ]; then
    echo "FAIL: /register password too short - expected 400, got $code"
    exit 1
fi
echo "PASS: /register password too short"

echo "Testing /register duplicate..."
res=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"testuser","password":"password123"}' "$BASE/register")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 409 ]; then
    echo "FAIL: /register duplicate - expected 409, got $code"
    exit 1
fi
echo "PASS: /register duplicate"

echo "Testing /login..."
res=$(curl -s -w "\n%{http_code}" -c cookies.txt -X POST -d '{"username":"testuser","password":"password123"}' "$BASE/login")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 200 ]; then
    echo "FAIL: /login - expected 200, got $code"
    exit 1
fi
echo "PASS: /login"

echo "Testing /login invalid credentials..."
res=$(curl -s -w "\n%{http_code}" -X POST -d '{"username":"testuser","password":"wrongpass"}' "$BASE/login")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 401 ]; then
    echo "FAIL: /login invalid credentials - expected 401, got $code"
    exit 1
fi
echo "PASS: /login invalid credentials"

echo "Testing /me..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/me")
code=$(echo "$res" | tail -n 1)
body=$(echo "$res" | head -n 1)
if [ "$code" -ne 200 ]; then
    echo "FAIL: /me - expected 200, got $code"
    echo "$body"
    exit 1
fi
echo "PASS: /me"

echo "Testing /me without auth..."
res=$(curl -s -w "\n%{http_code}" "$BASE/me")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 401 ]; then
    echo "FAIL: /me without auth - expected 401, got $code"
    exit 1
fi
echo "PASS: /me without auth"

echo "Testing /password..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -d '{"old_password":"password123","new_password":"newpass123"}' "$BASE/password")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 200 ]; then
    echo "FAIL: /password - expected 200, got $code"
    exit 1
fi
echo "PASS: /password"

echo "Testing /password wrong old password..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -d '{"old_password":"wrongold","new_password":"newpass123"}' "$BASE/password")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 401 ]; then
    echo "FAIL: /password wrong old password - expected 401, got $code"
    exit 1
fi
echo "PASS: /password wrong old password"

echo "Testing /password new password too short..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -d '{"old_password":"newpass123","new_password":"short"}' "$BASE/password")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 400 ]; then
    echo "FAIL: /password new password too short - expected 400, got $code"
    exit 1
fi
echo "PASS: /password new password too short"

echo "Testing /todos..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/todos")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 200 ]; then
    echo "FAIL: /todos - expected 200, got $code"
    exit 1
fi
echo "PASS: /todos"

echo "Testing POST /todos..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST -d '{"title":"Test Todo","description":"A test"}' "$BASE/todos")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 201 ]; then
    echo "FAIL: POST /todos - expected 201, got $code"
    exit 1
fi
echo "PASS: POST /todos"

echo "Testing POST /todos missing title..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST -d '{"description":"A test"}' "$BASE/todos")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 400 ]; then
    echo "FAIL: POST /todos missing title - expected 400, got $code"
    exit 1
fi
echo "PASS: POST /todos missing title"

echo "Testing POST /todos empty title..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST -d '{"title":"","description":"A test"}' "$BASE/todos")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 400 ]; then
    echo "FAIL: POST /todos empty title - expected 400, got $code"
    exit 1
fi
echo "PASS: POST /todos empty title"

echo "Testing GET /todos/1..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/todos/1")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 200 ]; then
    echo "FAIL: GET /todos/1 - expected 200, got $code"
    exit 1
fi
echo "PASS: GET /todos/1"

echo "Testing GET /todos/999 (not found)..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/todos/999")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 404 ]; then
    echo "FAIL: GET /todos/999 - expected 404, got $code"
    exit 1
fi
echo "PASS: GET /todos/999"

echo "Create another user for isolation testing..."
curl -s -X POST -d '{"username":"otheruser","password":"password123"}' "$BASE/register" > /dev/null
curl -s -c other_cookies.txt -X POST -d '{"username":"otheruser","password":"password123"}' "$BASE/login" > /dev/null

echo "Testing GET /todos/1 as other user (should be 404)..."
res=$(curl -s -w "\n%{http_code}" -b other_cookies.txt "$BASE/todos/1")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 404 ]; then
    echo "FAIL: GET /todos/1 as other user - expected 404, got $code"
    exit 1
fi
echo "PASS: GET /todos/1 as other user"

echo "Testing PUT /todos/1 as other user (should be 404)..."
res=$(curl -s -w "\n%{http_code}" -b other_cookies.txt -X PUT -d '{"completed":true}' "$BASE/todos/1")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 404 ]; then
    echo "FAIL: PUT /todos/1 as other user - expected 404, got $code"
    exit 1
fi
echo "PASS: PUT /todos/1 as other user"

echo "Testing PUT /todos/1 partial update..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -d '{"completed":true}' "$BASE/todos/1")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 200 ]; then
    echo "FAIL: PUT /todos/1 partial update - expected 200, got $code"
    exit 1
fi
echo "PASS: PUT /todos/1 partial update"

echo "Testing PUT /todos/1 empty title..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X PUT -d '{"title":""}' "$BASE/todos/1")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 400 ]; then
    echo "FAIL: PUT /todos/1 empty title - expected 400, got $code"
    exit 1
fi
echo "PASS: PUT /todos/1 empty title"

echo "Testing DELETE /todos/1..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE/todos/1")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 204 ]; then
    echo "FAIL: DELETE /todos/1 - expected 204, got $code"
    exit 1
fi
echo "PASS: DELETE /todos/1"

echo "Testing DELETE /todos/1 again (should be 404)..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X DELETE "$BASE/todos/1")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 404 ]; then
    echo "FAIL: DELETE /todos/1 again - expected 404, got $code"
    exit 1
fi
echo "PASS: DELETE /todos/1 again"

echo "Testing /logout..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt -X POST "$BASE/logout")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 200 ]; then
    echo "FAIL: /logout - expected 200, got $code"
    exit 1
fi
echo "PASS: /logout"

echo "Testing /me after logout (should be 401)..."
res=$(curl -s -w "\n%{http_code}" -b cookies.txt "$BASE/me")
code=$(echo "$res" | tail -n 1)
if [ "$code" -ne 401 ]; then
    echo "FAIL: /me after logout - expected 401, got $code"
    exit 1
fi
echo "PASS: /me after logout"

echo "All tests passed!"
