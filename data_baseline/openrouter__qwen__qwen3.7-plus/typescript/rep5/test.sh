#!/bin/bash
set -e

# Compile
npx tsc

PORT=${PORT:-3005}

echo "Starting server on port $PORT..."
node dist/src/index.js --port $PORT &
SERVER_PID=$!

# Wait for server to start
sleep 2

echo "Running tests..."
PORT=$PORT node dist/test.js

echo "Stopping server..."
kill $SERVER_PID 2>/dev/null || true

echo "All tests passed!"
