#!/bin/bash

# Parse command line arguments
port=3000
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      port="$2"
      shift # past argument
      shift # past value
      ;;
    *)
      shift # past unknown option
      ;;
  esac
done

# Install dependencies if node_modules doesn't exist
if [ ! -d "node_modules" ]; then
  echo "Installing dependencies..."
  npm install
fi

# Compile TypeScript to JavaScript
echo "Compiling TypeScript..."
npx tsc

# Start the server with the specified port
echo "Starting server on port $port..."
node dist/index.js --port "$port"