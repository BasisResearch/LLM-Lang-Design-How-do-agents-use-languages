#!/bin/bash
set -e

# Get port argument
PORT=8080
while [[ $# -gt 0 ]]; do
  case $1 in
    --port)
      PORT="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Build the Lean project first
echo "Building Lean project..."
lake build

# Check if flask is available, install if not
if ! python3 -c "import flask" &> /dev/null; then
  echo "Installing Flask..."
  pip3 install flask bcrypt
fi

# Run the API server using Python wrapper that interacts with Lean executables
echo "Starting Todo API server on 0.0.0.0:$PORT..."
python3 todo_server.py --port $PORT