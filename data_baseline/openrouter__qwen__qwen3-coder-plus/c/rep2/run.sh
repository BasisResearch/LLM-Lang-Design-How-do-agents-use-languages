#!/bin/bash

# Install required dependencies
sudo apt-get update
sudo apt-get install -y uuid-dev build-essential

# Parse arguments
PORT=8080
for i in "$@"; do
  case $i in
    --port)
      PORT="$2"
      shift
      shift
      ;;
    *)
      # Unknown option
      shift
      ;;
  esac
done

# Compile the server
gcc -o server server.c -luuid -lpthread

if [ $? -ne 0 ]; then
  echo "Compilation failed"
  exit 1
fi

echo "Starting server on port $PORT"

# Run the server
exec ./server --port $PORT