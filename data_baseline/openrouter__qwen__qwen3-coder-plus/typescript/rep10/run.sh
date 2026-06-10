#!/bin/bash

# Parse command line arguments
PORT=3000  # Default port

while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option $1"
      exit 1
      ;;
  esac
done

echo "Starting server on port $PORT..."

# Build the TypeScript files
echo "Building TypeScript files..."
npx tsc

if [ $? -ne 0 ]; then
  echo "Build failed!"
  exit 1
fi

echo "Starting server..."

# Start the server with the specified port
node dist/server.js --port $PORT