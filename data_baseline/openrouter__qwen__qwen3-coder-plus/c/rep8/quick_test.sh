#!/bin/bash
# Quick server functionality test
./server --port 8082 &
SERVER_PID=$!
sleep 2

result=$(curl -s -w "%{http_code}" -o /dev/null -X POST http://localhost:8082/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test123","password":"password123"}')

kill $SERVER_PID

echo "Status code was: $result"
if [ "$result" -eq 201 ]; then
    echo "✓ Quick test passed!"
else 
    echo "✗ Quick test failed"
fi