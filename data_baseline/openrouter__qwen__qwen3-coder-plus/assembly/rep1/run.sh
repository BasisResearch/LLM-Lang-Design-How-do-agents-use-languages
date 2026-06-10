#!/bin/bash

# Default port is 8080
PORT=8080

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 --port PORT"
      exit 1
      ;;
  esac
done

echo "Starting Todo App server on port $PORT..."

# Run the compiled server
exec ./todo_server --port "$PORT"