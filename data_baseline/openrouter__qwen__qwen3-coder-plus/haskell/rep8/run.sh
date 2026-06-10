#!/bin/bash

# Parse command line arguments
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

if [ -z "$PORT" ]; then
  echo "Usage: $0 --port PORT"
  exit 1
fi

# Build the project using cabal
echo "Building the project..."
cabal build

if [ $? -ne 0 ]; then
  echo "Build failed!"
  exit 1
fi

# Run the executable
echo "Starting server on port $PORT..."
exec cabal run todo-app -- --port $PORT