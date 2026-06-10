#!/bin/bash
# run.sh - Build and run the Todo App server

# Find the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Build the project
echo "Building the project..."
lake build

# Extract port from arguments
PORT=3000
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift 2
      ;;
    --port=*)
      PORT="${1#*=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

echo "Starting server on port $PORT"
./.lake/build/bin/todo_app --port "$PORT"
