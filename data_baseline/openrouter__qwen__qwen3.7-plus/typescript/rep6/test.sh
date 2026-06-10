#!/bin/bash
set -e

echo "Installing dependencies..."
npm install --silent

echo "Starting server on port 3456..."
npx tsx src/index.ts --port 3456 &
SERVER_PID=$!

# Wait for server to be ready
for i in {1..20}; do
  if curl -s -o /dev/null -w "%{http_code}" http://localhost:3456/me | grep -q "401"; then
    echo "Server is ready."
    break
  fi
  sleep 0.5
done

echo "Running tests..."
TEST_PORT=3456 npx tsx test.ts

echo "Stopping server..."
kill $SERVER_PID || true
echo "Done."
