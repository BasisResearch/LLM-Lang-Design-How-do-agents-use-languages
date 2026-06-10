#!/bin/bash

PORT=5052
HOST="http://localhost:$PORT"

echo "Starting server on port $PORT..."
./run.sh --port $PORT &
SERVER_PID=$!
sleep 3

cleanup() {
    echo "Stopping server..."
    kill $SERVER_PID || true
}
trap cleanup EXIT

echo "Testing /register..."
RES=$(curl -s -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
if echo "$RES" | grep -q '"id":1'; then echo "PASS: register valid"; else echo "FAIL: register valid ($RES)"; fi

RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "tu", "password": "password123"}')
if echo "$RES" | grep -q '"Invalid username"'; then echo "PASS: register invalid username"; else echo "FAIL: register invalid username ($RES)"; fi

RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser2", "password": "short"}')
if echo "$RES" | grep -q '"Password too short"'; then echo "PASS: register invalid password"; else echo "FAIL: register invalid password ($RES)"; fi

RES=$(curl -s -w "\n%{http_code}" -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
if echo "$RES" | grep -q '"Username already exists"'; then echo "PASS: register duplicate"; else echo "FAIL: register duplicate ($RES)"; fi

echo "Testing /login..."
RES=$(curl -s -i -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
COOKIE=$(echo "$RES" | grep -o 'session_id=[a-f0-9]*' | head -1)
if echo "$RES" | grep -q '"id":1'; then echo "PASS: login valid"; else echo "FAIL: login valid ($RES)"; fi

RES=$(curl -s -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "wrongpassword"}')
if echo "$RES" | grep -q '"Invalid credentials"'; then echo "PASS: login invalid"; else echo "FAIL: login invalid ($RES)"; fi

echo "Testing /logout..."
RES=$(curl -s -b "$COOKIE" -X POST "$HOST/logout")
if echo "$RES" | grep -q '{}'; then echo "PASS: logout valid"; else echo "FAIL: logout valid ($RES)"; fi

RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X GET "$HOST/me")
if echo "$RES" | grep -q '"Authentication required"'; then echo "PASS: logout invalidates session"; else echo "FAIL: logout invalidates session ($RES)"; fi

RES=$(curl -s -i -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}')
COOKIE=$(echo "$RES" | grep -o 'session_id=[a-f0-9]*' | head -1)

echo "Testing /me..."
RES=$(curl -s -b "$COOKIE" -X GET "$HOST/me")
if echo "$RES" | grep -q '"username":"testuser"'; then echo "PASS: /me valid"; else echo "FAIL: /me valid ($RES)"; fi

RES=$(curl -s -w "\n%{http_code}" -X GET "$HOST/me")
if echo "$RES" | grep -q '"Authentication required"'; then echo "PASS: /me no auth"; else echo "FAIL: /me no auth ($RES)"; fi

echo "Testing /password..."
RES=$(curl -s -b "$COOKIE" -X PUT "$HOST/password" -H "Content-Type: application/json" -d '{"old_password": "password123", "new_password": "newpassword123"}')
if echo "$RES" | grep -q '{}'; then echo "PASS: /password valid"; else echo "FAIL: /password valid ($RES)"; fi

RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X PUT "$HOST/password" -H "Content-Type: application/json" -d '{"old_password": "wrong", "new_password": "newpassword123"}')
if echo "$RES" | grep -q '"Invalid credentials"'; then echo "PASS: /password invalid old"; else echo "FAIL: /password invalid old ($RES)"; fi

RES=$(curl -s -i -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "testuser", "password": "newpassword123"}')
COOKIE=$(echo "$RES" | grep -o 'session_id=[a-f0-9]*' | head -1)

echo "Testing /todos..."
RES=$(curl -s -b "$COOKIE" -X POST "$HOST/todos" -H "Content-Type: application/json" -d '{"title": "My First Todo", "description": "This is a test"}')
if echo "$RES" | grep -q '"My First Todo"'; then echo "PASS: create todo"; else echo "FAIL: create todo ($RES)"; fi
TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

RES=$(curl -s -b "$COOKIE" -X POST "$HOST/todos" -H "Content-Type: application/json" -d '{"title": "My Second Todo"}')
if echo "$RES" | grep -q '"My Second Todo"'; then echo "PASS: create todo 2"; else echo "FAIL: create todo 2 ($RES)"; fi

RES=$(curl -s -b "$COOKIE" -X GET "$HOST/todos")
if echo "$RES" | grep -q '"My First Todo"'; then echo "PASS: list todos"; else echo "FAIL: list todos ($RES)"; fi

RES=$(curl -s -b "$COOKIE" -X GET "$HOST/todos/$TODO_ID")
if echo "$RES" | grep -q '"My First Todo"'; then echo "PASS: get todo"; else echo "FAIL: get todo ($RES)"; fi

RES=$(curl -s -b "$COOKIE" -X PUT "$HOST/todos/$TODO_ID" -H "Content-Type: application/json" -d '{"completed": true, "title": "Updated Title"}')
if echo "$RES" | grep -q '"Updated Title"' && echo "$RES" | grep -q '"completed":true'; then echo "PASS: update todo"; else echo "FAIL: update todo ($RES)"; fi

RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X DELETE "$HOST/todos/$TODO_ID")
if echo "$RES" | grep -q '204'; then echo "PASS: delete todo"; else echo "FAIL: delete todo ($RES)"; fi

RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X GET "$HOST/todos/$TODO_ID")
if echo "$RES" | grep -q '"Todo not found"'; then echo "PASS: get deleted todo 404"; else echo "FAIL: get deleted todo 404 ($RES)"; fi

RES=$(curl -s -i -X POST "$HOST/register" -H "Content-Type: application/json" -d '{"username": "otheruser", "password": "password123"}')
RES=$(curl -s -i -X POST "$HOST/login" -H "Content-Type: application/json" -d '{"username": "otheruser", "password": "password123"}')
OTHER_COOKIE=$(echo "$RES" | grep -o 'session_id=[a-f0-9]*' | head -1)

RES=$(curl -s -b "$OTHER_COOKIE" -X POST "$HOST/todos" -H "Content-Type: application/json" -d '{"title": "Other Todo"}')
OTHER_TODO_ID=$(echo "$RES" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')

RES=$(curl -s -w "\n%{http_code}" -b "$COOKIE" -X GET "$HOST/todos/$OTHER_TODO_ID")
if echo "$RES" | grep -q '"Todo not found"'; then echo "PASS: access other user todo 404"; else echo "FAIL: access other user todo 404 ($RES)"; fi

echo "All tests completed."
