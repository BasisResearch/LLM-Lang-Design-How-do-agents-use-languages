#!/bin/bash

# Parse command line arguments
PORT=3000

while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Install dependencies if node_modules doesn't exist
if [ ! -d "node_modules" ]; then
  echo "Installing dependencies..."
  npm install
fi

# Run the server with tsx
npx tsx server.ts --port "$PORT"