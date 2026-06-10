#!/bin/bash

# Start server
./server --port 8997 &
SERVER_PID=$!
sleep 1

echo "Testing Register..."
curl -v -X POST -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' http://localhost:8997/register

echo -e "\n\nTesting Login..."
curl -v -c cookies.txt -X POST -H "Content-Type: application/json" -d '{"username": "testuser", "password": "password123"}' http://localhost:8997/login

echo -e "\n\nTesting Me..."
curl -v -b cookies.txt http://localhost:8997/me

echo -e "\n\nTesting Create Todo..."
curl -v -b cookies.txt -X POST -H "Content-Type: application/json" -d '{"title": "My Todo", "description": "Some description"}' http://localhost:8997/todos

echo -e "\n\nTesting Get Todos..."
curl -v -b cookies.txt http://localhost:8997/todos

echo -e "\n\nTesting Get Todo 1..."
curl -v -b cookies.txt http://localhost:8997/todos/1

kill $SERVER_PID
rm -f cookies.txt