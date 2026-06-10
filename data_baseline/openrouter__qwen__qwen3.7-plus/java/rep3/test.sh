#!/bin/bash

PORT=8082
BASE="http://localhost:$PORT"

echo "Starting server on port $PORT..."
java Main --port $PORT &
SERVER_PID=$!
sleep 3

echo "Testing /register..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser", "password":"password123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "201" ]; then echo "FAIL /register: $CODE"; else echo "PASS /register"; fi

echo "Testing /register duplicate..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/register" -H "Content-Type: application/json" -d '{"username":"testuser", "password":"password123"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "409" ]; then echo "FAIL /register dup: $CODE"; else echo "PASS /register dup"; fi

echo "Testing /login..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/login" -H "Content-Type: application/json" -d '{"username":"testuser", "password":"password123"}' -c cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL /login: $CODE"; else echo "PASS /login"; fi

echo "Testing /me..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL /me: $CODE"; else echo "PASS /me"; fi

echo "Testing /me without auth..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me")
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "FAIL /me no auth: $CODE"; else echo "PASS /me no auth"; fi

echo "Testing POST /todos..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/todos" -b cookies.txt -H "Content-Type: application/json" -d '{"title":"Todo 1"}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "201" ]; then echo "FAIL POST /todos: $CODE"; else echo "PASS POST /todos"; fi

echo "Testing GET /todos..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL GET /todos: $CODE"; else echo "PASS GET /todos"; fi

echo "Testing GET /todos/1..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/todos/1" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL GET /todos/1: $CODE"; else echo "PASS GET /todos/1"; fi

echo "Testing PUT /todos/1..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/1" -b cookies.txt -H "Content-Type: application/json" -d '{"completed":true}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL PUT /todos/1: $CODE"; else echo "PASS PUT /todos/1"; fi

echo "Testing PUT /todos/1 empty title..."
RES=$(curl -s -w "\n%{http_code}" -X PUT "$BASE/todos/1" -b cookies.txt -H "Content-Type: application/json" -d '{"title":""}')
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "400" ]; then echo "FAIL PUT /todos/1 empty title: $CODE"; else echo "PASS PUT /todos/1 empty title"; fi

echo "Testing DELETE /todos/1..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/todos/1" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "204" ]; then echo "FAIL DELETE /todos/1: $CODE"; else echo "PASS DELETE /todos/1"; fi

echo "Testing DELETE /todos/1 again..."
RES=$(curl -s -w "\n%{http_code}" -X DELETE "$BASE/todos/1" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "404" ]; then echo "FAIL DELETE /todos/1 again: $CODE"; else echo "PASS DELETE /todos/1 again"; fi

echo "Testing POST /logout..."
RES=$(curl -s -w "\n%{http_code}" -X POST "$BASE/logout" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "200" ]; then echo "FAIL POST /logout: $CODE"; else echo "PASS POST /logout"; fi

echo "Testing /me after logout..."
RES=$(curl -s -w "\n%{http_code}" -X GET "$BASE/me" -b cookies.txt)
CODE=$(echo "$RES" | tail -n 1)
if [ "$CODE" != "401" ]; then echo "FAIL /me after logout: $CODE"; else echo "PASS /me after logout"; fi

echo "ALL TESTS COMPLETED!"
kill $SERVER_PID 2>/dev/null || true