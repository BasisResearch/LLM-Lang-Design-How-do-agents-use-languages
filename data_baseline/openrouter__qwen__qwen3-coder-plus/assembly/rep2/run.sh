#!/bin/bash

# Parse command line arguments
PORT="8080"

while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Use existing compiled server binary
BINARY_NAME="todo_server"

# Run the server binary with the specified port
echo "Starting server on port $PORT..."
$BINARY_NAME --port $PORT